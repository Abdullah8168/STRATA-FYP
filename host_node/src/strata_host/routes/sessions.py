from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response, status

from strata_host.chain import ChainService
from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.errors import MissingQuery, SessionNotFound
from strata_host.models import (
    PaymentNotifyRequest,
    SessionResponse,
    StartSessionRequest,
    StopSessionRequest,
)
from strata_host.session_start import authenticate_and_create_session
from strata_host.store import SessionStore

router = APIRouter(tags=["sessions"])


def _get_store() -> SessionStore:
    raise RuntimeError("Dependency override not configured.")


def _get_enforcer() -> EnforcerService:
    raise RuntimeError("Dependency override not configured.")


def _get_chain() -> ChainService:
    raise RuntimeError("Dependency override not configured.")


def _get_settings() -> Settings:
    raise RuntimeError("Dependency override not configured.")


@router.post("/session/start", response_model=SessionResponse)
async def start_session(
    request: Request,
    payload: StartSessionRequest,
    store: SessionStore = Depends(_get_store),
    enforcer: EnforcerService = Depends(_get_enforcer),
    chain: ChainService = Depends(_get_chain),
    settings: Settings = Depends(_get_settings),
) -> SessionResponse:
    """Create a guest session after MAC resolution + EIP-191 verification.

    On a Raspberry Pi the MAC is taken from the ARP neighbour table for the
    request's source IP (``GUEST_IFACE``). The ``guest_signature`` must be a
    valid personal_sign of the canonical STRATA-SESSION-START message that
    includes that MAC.
    """
    record = await authenticate_and_create_session(
        request=request,
        payload=payload,
        store=store,
        settings=settings,
    )

    # Only admit when chain is disabled (Phase A / Iteration 2 behaviour).
    # When chain is enabled the session sits in "pending_payment" until the
    # on-chain SessionOpened event flips it to "active".
    if record.status == "active":
        await enforcer.admit(record.mac_address, origin="portal")

    await chain.on_session_opened(str(record.session_id), record.guest_wallet_address)
    return record.to_response()


@router.post("/session/stop", response_model=SessionResponse)
async def stop_session(
    payload: StopSessionRequest,
    store: SessionStore = Depends(_get_store),
    enforcer: EnforcerService = Depends(_get_enforcer),
    settings: Settings = Depends(_get_settings),
) -> SessionResponse:
    record = await store.stop_session(payload.session_id, payload.reason)
    await store.apply_settlement_fields(record.session_id, settings)
    refreshed = await store.get_by_session_id(record.session_id)
    if refreshed is None:
        raise SessionNotFound("Session not found.")
    await enforcer.disconnect(refreshed.mac_address, origin="portal")
    return refreshed.to_response()


@router.get("/session/status", response_model=SessionResponse)
async def session_status(
    session_id: UUID | None = Query(default=None),
    mac_address: str | None = Query(default=None),
    store: SessionStore = Depends(_get_store),
) -> SessionResponse:
    if bool(session_id) == bool(mac_address):
        raise MissingQuery("Provide exactly one query parameter: session_id or mac_address.")

    record = None
    if session_id is not None:
        record = await store.get_by_session_id(session_id)
    elif mac_address is not None:
        record = await store.get_by_mac_address(mac_address.lower())

    if record is None:
        raise SessionNotFound("Session not found.")
    return record.to_response()


@router.post("/session/{session_id}/payment", status_code=status.HTTP_202_ACCEPTED)
async def record_session_payment(
    session_id: UUID,
    payload: PaymentNotifyRequest,
    response: Response,
    store: SessionStore = Depends(_get_store),
) -> dict:
    """Record a tx hash hint for observability.

    This endpoint NEVER admits the MAC — only the on-chain SessionOpened
    event does that. We accept 202 to make this contract crisp: "we
    received your hint; come back via /session/status to learn whether the
    chain confirmed the payment."
    """
    record = await store.record_payment_hint(session_id, payload.tx_hash)
    response.status_code = status.HTTP_202_ACCEPTED
    return {
        "session_id": str(record.session_id),
        "status": record.status,
        "tx_hash": record.tx_hash,
    }
