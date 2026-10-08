"""Phase G — chatroom server tests.

The WebSocket route is exercised via FastAPI's TestClient. We verify:
- join → history is delivered.
- text messages broadcast to all connected clients.
- rate limits return an `error` frame instead of disconnecting.
- the REST /chatroom/sos endpoint reaches connected sockets.
- /chatroom/messages?since=... returns the persisted log slice.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from strata_host.config import Settings
from strata_host.main import create_app


@pytest.fixture
def app_client():
    settings = Settings(
        DEMO_MODE=True,
        CHAIN_ENABLED=False,
        MDNS_ENABLED=False,  # zeroconf is noisy in tests
        ADMIN_TOKEN="test-token",
    )
    app = create_app(settings)
    with TestClient(app) as client:
        yield client


def _join_frame(name: str, client_id: str | None = None) -> dict:
    return {
        "type": "join",
        "display_name": name,
        "client_id": client_id or str(uuid4()),
    }


def test_join_returns_history_frame_first(app_client):
    with app_client.websocket_connect("/ws/chatroom") as ws:
        ws.send_json(_join_frame("alice"))
        first = ws.receive_json()
        assert first["type"] == "history"
        assert isinstance(first["messages"], list)


def test_two_clients_see_each_others_messages(app_client):
    cid_a = str(uuid4())
    cid_b = str(uuid4())
    with app_client.websocket_connect("/ws/chatroom") as a, \
         app_client.websocket_connect("/ws/chatroom") as b:
        a.send_json(_join_frame("alice", cid_a))
        a.receive_json()  # history
        b.send_json(_join_frame("bob", cid_b))
        b.receive_json()  # history

        # alice sees a "system" frame for bob joining (the broadcast).
        # We just drain frames until we see a regular msg — the order of
        # system frames vs alice's send isn't worth pinning down here.
        a.send_json({"type": "msg", "text": "hello bob"})
        seen_msg_on_b = False
        for _ in range(6):
            frame = b.receive_json()
            if frame["type"] == "msg" and frame["text"] == "hello bob":
                assert frame["from"] == "alice"
                seen_msg_on_b = True
                break
        assert seen_msg_on_b, "bob never received alice's text frame"


def test_msg_rate_limit_returns_error_frame(app_client):
    with app_client.websocket_connect("/ws/chatroom") as ws:
        ws.send_json(_join_frame("rate-tester"))
        ws.receive_json()  # history
        ws.send_json({"type": "msg", "text": "first"})
        # Drain echo + system frames; the second msg within 1s must trip.
        ws.send_json({"type": "msg", "text": "second-too-fast"})
        saw_error = False
        for _ in range(10):
            frame = ws.receive_json()
            if frame.get("type") == "error" and frame.get("code") == "RATE_LIMITED":
                saw_error = True
                break
        assert saw_error, "fast-second message should have been rate-limited"


def test_sos_endpoint_broadcasts_to_connected_sockets(app_client):
    with app_client.websocket_connect("/ws/chatroom") as ws:
        ws.send_json(_join_frame("listener"))
        ws.receive_json()  # history

        resp = app_client.post(
            "/chatroom/sos",
            json={"text": "fire alarm", "lat": 33.6, "lon": 73.0,
                  "display_name": "anonymous-portal"},
        )
        assert resp.status_code == 201

        saw_sos = False
        for _ in range(8):
            frame = ws.receive_json()
            if frame.get("type") == "sos" and frame.get("text") == "fire alarm":
                saw_sos = True
                assert frame["from"] == "anonymous-portal"
                assert frame["lat"] == 33.6
                break
        assert saw_sos


def test_history_endpoint_returns_messages_after_sos(app_client):
    before = datetime.now(UTC).isoformat()
    resp = app_client.post(
        "/chatroom/sos", json={"text": "test-msg", "display_name": "tests"}
    )
    assert resp.status_code == 201
    history = app_client.get(
        "/chatroom/messages",
        params={"since": before},
    ).json()
    assert any(m["text"] == "test-msg" for m in history)


def test_bidirectional_messages_and_sos(app_client):
    """Client A ↔ Client B message exchange + SOS delivery (software LAN demo)."""
    with app_client.websocket_connect("/ws/chatroom") as a, \
         app_client.websocket_connect("/ws/chatroom") as b:
        a.send_json(_join_frame("alice"))
        a.receive_json()
        b.send_json(_join_frame("bob"))
        b.receive_json()

        a.send_json({"type": "msg", "text": "ping-from-a"})
        assert _wait_for(b, "msg", "ping-from-a")

        b.send_json({"type": "msg", "text": "pong-from-b"})
        assert _wait_for(a, "msg", "pong-from-b")

        resp = app_client.post(
            "/chatroom/sos",
            json={"text": "need-help", "display_name": "relay"},
        )
        assert resp.status_code == 201
        assert _wait_for(a, "sos", "need-help")
        assert _wait_for(b, "sos", "need-help")


def test_reconnect_receives_history(app_client):
    """Disconnect and rejoin — history frame includes prior messages."""
    with app_client.websocket_connect("/ws/chatroom") as ws:
        ws.send_json(_join_frame("first"))
        ws.receive_json()
        ws.send_json({"type": "msg", "text": "remember-me"})
        # drain echo
        for _ in range(4):
            frame = ws.receive_json()
            if frame.get("type") == "msg" and frame.get("text") == "remember-me":
                break

    with app_client.websocket_connect("/ws/chatroom") as ws2:
        ws2.send_json(_join_frame("second"))
        hist = ws2.receive_json()
        assert hist["type"] == "history"
        texts = [m.get("text") for m in hist.get("messages", [])]
        assert "remember-me" in texts


def _wait_for(ws, frame_type: str, text: str, attempts: int = 10) -> bool:
    for _ in range(attempts):
        frame = ws.receive_json()
        if frame.get("type") == frame_type and frame.get("text") == text:
            return True
    return False
