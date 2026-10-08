"""Phase G — chatroom WebSocket server + REST helpers.

Mounts under FastAPI as ``/ws/chatroom`` (WebSocket) and ``/chatroom/*``
(REST). Owns the connected sockets, the per-client rate limiters, the
broadcast fanout, and the periodic presence heartbeat.

Design notes:
- We keep this as a small in-process manager rather than something
  pub/sub. We're a single-host node — no need for Redis.
- Rate limits are enforced per ``client_id`` (UUID the client provides).
  This is trivially circumvented by a bad actor regenerating uuids, but
  for an emergency chatroom on a single AP that's an acceptable trade.
- Clients that violate rate limits get an "error" frame, not a disconnect.
  Disconnecting on first offence makes the chatroom worse during the
  exact moments (panic + spam) we need it most.
"""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Literal
from uuid import UUID, uuid4

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    WebSocket,
    WebSocketDisconnect,
    status,
)
from pydantic import BaseModel, ValidationError

from strata_host.chatroom.models import (
    ChatMessage,
    JoinFrame,
    LocationFrame,
    SosFrame,
    TextFrame,
)
from strata_host.chatroom.store import ChatroomStore
from strata_host.logging_setup import get_logger

if TYPE_CHECKING:
    pass


router = APIRouter(tags=["chatroom"])

# Rate-limit windows (seconds since the last accepted action of that type).
MSG_COOLDOWN_S = 1.0
SOS_COOLDOWN_S = 30.0
PRESENCE_INTERVAL_S = 30.0


class _ConnectedClient:
    __slots__ = (
        "ws",
        "client_id",
        "display_name",
        "last_msg_at",
        "last_sos_at",
        "last_location",
    )

    def __init__(self, ws: WebSocket, client_id: UUID, display_name: str) -> None:
        self.ws = ws
        self.client_id = client_id
        self.display_name = display_name
        self.last_msg_at: float = 0.0
        self.last_sos_at: float = 0.0
        self.last_location: tuple[float, float] | None = None


class ChatroomManager:
    def __init__(self, store: ChatroomStore) -> None:
        self._store = store
        self._clients: dict[UUID, _ConnectedClient] = {}
        self._lock = asyncio.Lock()
        self._presence_task: asyncio.Task | None = None
        self._logger = get_logger("chatroom")

    async def start(self) -> None:
        if self._presence_task is None or self._presence_task.done():
            self._presence_task = asyncio.create_task(
                self._presence_loop(), name="chatroom-presence"
            )

    async def stop(self) -> None:
        if self._presence_task is not None:
            self._presence_task.cancel()
            try:
                await self._presence_task
            except asyncio.CancelledError:
                pass
            self._presence_task = None
        async with self._lock:
            for c in list(self._clients.values()):
                try:
                    await c.ws.close()
                except Exception:  # noqa: BLE001
                    pass
            self._clients.clear()
        await self._store.close()

    # --- WS lifecycle ----------------------------------------------------
    async def handle_socket(self, ws: WebSocket) -> None:
        await ws.accept()
        client: _ConnectedClient | None = None
        try:
            join_raw = await ws.receive_text()
            join = self._parse_join(join_raw)
            if join is None:
                await ws.send_json(
                    {"type": "error", "code": "BAD_JOIN", "message": "first frame must be a join"}
                )
                await ws.close()
                return
            client = _ConnectedClient(ws, join.client_id, join.display_name)
            async with self._lock:
                # If this client_id was already connected, replace the old one.
                old = self._clients.pop(join.client_id, None)
                self._clients[join.client_id] = client
            if old is not None:
                try:
                    await old.ws.close()
                except Exception:  # noqa: BLE001
                    pass

            await self._send_history(ws)
            await self._broadcast_system(
                f"{join.display_name} joined", origin=join.client_id
            )

            while True:
                raw = await ws.receive_text()
                await self._handle_frame(client, raw)
        except WebSocketDisconnect:
            pass
        except Exception as exc:  # noqa: BLE001
            self._logger.warning(
                "chatroom.socket_error", error=type(exc).__name__
            )
        finally:
            if client is not None:
                async with self._lock:
                    if self._clients.get(client.client_id) is client:
                        self._clients.pop(client.client_id, None)
                await self._broadcast_system(
                    f"{client.display_name} left", origin=client.client_id
                )

    def _parse_join(self, raw: str) -> JoinFrame | None:
        try:
            data = json.loads(raw)
            return JoinFrame.model_validate(data)
        except (ValidationError, json.JSONDecodeError, TypeError):
            return None

    async def _send_history(self, ws: WebSocket) -> None:
        history = await self._store.history()
        # Last 100 — captive portal SOS could push the count well above
        # the per-session viewing window.
        recent = history[-100:]
        await ws.send_json(
            {
                "type": "history",
                "messages": [
                    json.loads(m.model_dump_json(by_alias=True)) for m in recent
                ],
            }
        )

    # --- inbound frame routing ------------------------------------------
    async def _handle_frame(self, client: _ConnectedClient, raw: str) -> None:
        try:
            data = json.loads(raw)
            ftype = data.get("type")
        except (json.JSONDecodeError, AttributeError):
            await self._send_error(client.ws, "BAD_JSON", "could not parse frame")
            return

        loop = asyncio.get_running_loop()
        now = loop.time()

        if ftype == "msg":
            try:
                frame = TextFrame.model_validate(data)
            except ValidationError as e:
                await self._send_error(client.ws, "BAD_FRAME", str(e))
                return
            if now - client.last_msg_at < MSG_COOLDOWN_S:
                await self._send_error(client.ws, "RATE_LIMITED", "1 msg/sec max")
                return
            client.last_msg_at = now
            await self._broadcast_message(
                "msg",
                from_name=client.display_name,
                client_id=client.client_id,
                text=frame.text,
            )
        elif ftype == "sos":
            try:
                frame = SosFrame.model_validate(data)
            except ValidationError as e:
                await self._send_error(client.ws, "BAD_FRAME", str(e))
                return
            if now - client.last_sos_at < SOS_COOLDOWN_S:
                await self._send_error(client.ws, "RATE_LIMITED", "1 SOS/30s max")
                return
            client.last_sos_at = now
            lat = frame.lat or (
                client.last_location[0] if client.last_location else None
            )
            lon = frame.lon or (
                client.last_location[1] if client.last_location else None
            )
            await self._broadcast_message(
                "sos",
                from_name=client.display_name,
                client_id=client.client_id,
                text=frame.text or "🚨 SOS",
                lat=lat,
                lon=lon,
            )
        elif ftype == "location":
            try:
                frame = LocationFrame.model_validate(data)
            except ValidationError as e:
                await self._send_error(client.ws, "BAD_FRAME", str(e))
                return
            client.last_location = (frame.lat, frame.lon)
            await self._broadcast_message(
                "location",
                from_name=client.display_name,
                client_id=client.client_id,
                text="shared location",
                lat=frame.lat,
                lon=frame.lon,
            )
        elif ftype == "ping":
            await client.ws.send_json({"type": "pong"})
        else:
            await self._send_error(
                client.ws, "UNKNOWN_TYPE", f"unrecognised frame type: {ftype}"
            )

    async def _send_error(self, ws: WebSocket, code: str, message: str) -> None:
        try:
            await ws.send_json({"type": "error", "code": code, "message": message})
        except Exception:  # noqa: BLE001
            pass

    # --- broadcast -------------------------------------------------------
    async def _broadcast_system(self, text: str, *, origin: UUID | None) -> None:
        await self._broadcast_message(
            "system", from_name="system", client_id=origin, text=text
        )

    async def _broadcast_message(
        self,
        mtype: Literal["msg", "sos", "system", "location"],
        *,
        from_name: str,
        client_id: UUID | None,
        text: str | None = None,
        lat: float | None = None,
        lon: float | None = None,
    ) -> ChatMessage:
        msg = ChatMessage(
            type=mtype,
            id=uuid4(),
            **{"from": from_name},
            client_id=client_id,
            text=text,
            ts=datetime.now(UTC),
            lat=lat,
            lon=lon,
        )
        await self._store.append(msg)
        payload = json.loads(msg.model_dump_json(by_alias=True))
        async with self._lock:
            recipients = list(self._clients.values())
        for c in recipients:
            try:
                await c.ws.send_json(payload)
            except Exception:  # noqa: BLE001
                # The disconnect handler will clean up.
                pass
        return msg

    # --- presence loop ---------------------------------------------------
    async def _presence_loop(self) -> None:
        while True:
            await asyncio.sleep(PRESENCE_INTERVAL_S)
            async with self._lock:
                users = [
                    {
                        "client_id": str(c.client_id),
                        "display_name": c.display_name,
                    }
                    for c in self._clients.values()
                ]
                recipients = list(self._clients.values())
            payload = {
                "type": "presence",
                "users": users,
                "ts": datetime.now(UTC).isoformat(),
            }
            for c in recipients:
                try:
                    await c.ws.send_json(payload)
                except Exception:  # noqa: BLE001
                    pass

    # --- REST helpers ----------------------------------------------------
    async def trigger_sos(
        self, *, text: str, lat: float | None, lon: float | None, source: str
    ) -> ChatMessage:
        return await self._broadcast_message(
            "sos",
            from_name=source,
            client_id=None,
            text=text or "🚨 SOS",
            lat=lat,
            lon=lon,
        )


# --- FastAPI route wiring -----------------------------------------------
def _get_manager() -> ChatroomManager:
    raise RuntimeError("Dependency override not configured.")


def _get_store() -> ChatroomStore:
    raise RuntimeError("Dependency override not configured.")


@router.websocket("/ws/chatroom")
async def ws_chatroom(websocket: WebSocket) -> None:
    # WebSocket routes don't support FastAPI's Depends override layer the
    # same way HTTP routes do — the closest stable handle to "the running
    # app's state" is websocket.app.state, which we set up in main.lifespan.
    manager: ChatroomManager = websocket.app.state.chatroom
    await manager.handle_socket(websocket)


class SosBody(BaseModel):
    text: str = ""
    lat: float | None = None
    lon: float | None = None
    display_name: str = "anonymous-portal"


@router.post(
    "/chatroom/sos",
    status_code=status.HTTP_201_CREATED,
)
async def trigger_sos_endpoint(
    body: SosBody,
    manager: ChatroomManager = Depends(_get_manager),
) -> dict:
    """Trigger an SOS without an active WS — used by the captive portal
    HTML so even unauthenticated guests can SOS."""
    msg = await manager.trigger_sos(
        text=body.text,
        lat=body.lat,
        lon=body.lon,
        source=body.display_name,
    )
    return {
        "id": str(msg.id),
        "type": msg.type,
        "ts": msg.ts.isoformat(),
    }


@router.get("/chatroom/messages")
async def chatroom_history(
    since: datetime | None = Query(default=None),
    store: ChatroomStore = Depends(_get_store),
) -> list[dict]:
    history = await store.history(since=since)
    return [json.loads(m.model_dump_json(by_alias=True)) for m in history]
