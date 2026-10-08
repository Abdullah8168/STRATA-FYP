from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from strata_host.config import Settings
from strata_host.models import HostInfoResponse
from strata_host.store import SessionRecord, SessionStore

router = APIRouter(prefix="/host", tags=["host"])


def _get_store() -> SessionStore:
    raise RuntimeError("Dependency override not configured.")


def _get_settings() -> Settings:
    raise RuntimeError("Dependency override not configured.")


def _escrow_lock_wei(record: SessionRecord) -> int | None:
    """Funds locked in SessionEscrow at open (full deposit), if known."""
    if record.escrow_amount_wei is not None:
        return int(record.escrow_amount_wei)
    return None


def _earned_amount_wei(record: SessionRecord, settings: Settings) -> str:
    """Host payment estimate matching SessionEscrow.closeSession math.

    payment = amount * min(bytesConsumed, quota) / quota

    Uses settlement_* fields when the host has signed a stop receipt;
    otherwise live ``bytes_used`` / ``quota_bytes``. Off-chain (no escrow
    lock) falls back to ``price_per_gb_wei * bytes / 1e9``.
    """
    escrow = _escrow_lock_wei(record)
    if escrow is not None:
        quota = record.settlement_quota_bytes or record.quota_bytes
        if quota <= 0:
            return "0"
        consumed = (
            record.settlement_bytes_consumed
            if record.settlement_bytes_consumed is not None
            else record.bytes_used
        )
        capped = consumed if consumed < quota else quota
        return str((escrow * capped) // quota)

    try:
        ppb = int(record.price_per_gb_wei)
    except (ValueError, TypeError):
        ppb = 0
    if ppb <= 0:
        return "0"
    return str((ppb * record.bytes_used) // (10**9))


def _strt_amount_wei(record: SessionRecord, settings: Settings) -> str:
    """Backward-compatible field: escrow lock when chained, else earned approx."""
    escrow = _escrow_lock_wei(record)
    if settings.CHAIN_ENABLED and escrow is not None:
        return str(escrow)
    return _earned_amount_wei(record, settings)


@router.get("/info", response_model=HostInfoResponse)
async def host_info(
    request: Request,
    settings: Settings = Depends(_get_settings),
) -> HostInfoResponse:
    """Metadata for Flutter LAN discovery cards (Iteration 2)."""
    wallet = (settings.HOST_WALLET_ADDRESS or "").strip()
    version = getattr(request.app, "version", None) or "0.1.0"
    return HostInfoResponse(
        name=settings.HOST_DISPLAY_NAME,
        display_name=settings.HOST_DISPLAY_NAME,
        ssid=settings.HOST_SSID,
        wallet_address=wallet,
        host_wallet_address=wallet,
        price_per_gb_wei=settings.DEFAULT_PRICE_PER_GB_WEI,
        price_per_gb=settings.DEFAULT_PRICE_PER_GB,
        guest_iface=settings.GUEST_IFACE,
        wan_iface=settings.WAN_IFACE,
        portal_port=settings.PORTAL_PORT,
        demo_mode=settings.DEMO_MODE,
        chain_enabled=settings.CHAIN_ENABLED,
        version=str(version),
        ap_gateway="192.168.50.1",
    )


@router.get("/sessions")
async def list_host_sessions(
    store: SessionStore = Depends(_get_store),
    settings: Settings = Depends(_get_settings),
) -> dict:
    rows = await store.list_recent_sessions(200)
    sessions = [
        {
            "session_id": str(r.session_id),
            "guest_wallet_address": r.guest_wallet_address,
            "mac_address": r.mac_address,
            "bytes_used": r.bytes_used,
            "quota_bytes": r.quota_bytes,
            "status": r.status,
            "started_at": r.started_at.isoformat(),
            "stopped_at": r.stopped_at.isoformat() if r.stopped_at else None,
            "escrow_amount_wei": (
                str(r.escrow_amount_wei) if r.escrow_amount_wei is not None else None
            ),
            "earned_amount_wei": _earned_amount_wei(r, settings),
            # Legacy alias: lock when chained, else earned approx.
            "strt_amount_wei": _strt_amount_wei(r, settings),
            "stop_reason": r.stop_reason,
            "price_per_gb_wei": r.price_per_gb_wei,
            "tx_hash": r.tx_hash,
            "chain_session_id": r.chain_session_id,
            # Iteration 3 — periodic checkpoints + host-driven settlement.
            "checkpoint_bytes": r.checkpoint_bytes,
            "checkpoint_count": r.checkpoint_count,
            "checkpoint_at": r.checkpoint_at.isoformat() if r.checkpoint_at else None,
            "settlement_status": r.settlement_status,
            "settlement_tx_hash": r.settlement_tx_hash,
            "settlement_attempts": r.settlement_attempts,
            "settlement_error": r.settlement_error,
            "host_payment_wei": (
                str(r.host_payment_wei) if r.host_payment_wei is not None else None
            ),
        }
        for r in rows
    ]
    return {"sessions": sessions}
