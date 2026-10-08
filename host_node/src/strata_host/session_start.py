"""Shared session-start pipeline: MAC resolve → signature verify → store."""

from __future__ import annotations

import sys
from typing import TYPE_CHECKING

from fastapi import Request

from strata_host.errors import (
    HostFull,
    HostWalletMismatch,
    InvalidSignature,
    MacMismatch,
    MacUnresolved,
)
from strata_host.logging_setup import get_logger
from strata_host.models import StartSessionRequest
from strata_host.neighbour import (
    client_ip_from_request,
    is_valid_mac,
    lookup_mac_for_ip,
    normalize_mac,
)
from strata_host.session_crypto import verify_session_start_signature

if TYPE_CHECKING:
    from strata_host.config import Settings
    from strata_host.store import SessionRecord, SessionStore

_logger = get_logger("session_start")


def resolve_guest_mac(
    request: Request,
    settings: "Settings",
    client_supplied_mac: str,
) -> str:
    """Resolve the guest MAC for a session-start request.

    Production (Linux Pi, ``ALLOW_CLIENT_MAC=false``):
      client IP → ARP/neigh on ``GUEST_IFACE``. Client-supplied MAC is
      ignored unless it matches the resolved value.

    Lab / tests (``ALLOW_CLIENT_MAC=true`` or non-Linux):
      accept a well-formed client-supplied MAC when ARP cannot resolve.
    """
    supplied = normalize_mac(client_supplied_mac) if client_supplied_mac else ""
    if supplied and not is_valid_mac(supplied):
        supplied = ""

    client_ip = client_ip_from_request(request)
    resolved: str | None = None
    if client_ip:
        resolved = lookup_mac_for_ip(client_ip, settings.GUEST_IFACE)

    if resolved:
        if supplied and supplied != resolved:
            raise MacMismatch(
                "Client-supplied MAC does not match the ARP neighbour table.",
                details={"resolved": resolved, "supplied": supplied},
            )
        _logger.info(
            "session.mac_resolved",
            client_ip=client_ip,
            mac=resolved,
            source="arp",
        )
        return resolved

    allow_client = settings.ALLOW_CLIENT_MAC or not sys.platform.startswith("linux")
    if allow_client and supplied:
        _logger.warning(
            "session.mac_client_accepted",
            client_ip=client_ip,
            mac=supplied,
            allow_client_mac=settings.ALLOW_CLIENT_MAC,
            platform=sys.platform,
        )
        return supplied

    raise MacUnresolved(
        "Could not resolve guest MAC from the neighbour table. "
        "Connect via the STRATA AP and retry, or enable ALLOW_CLIENT_MAC "
        "only for lab/tests.",
        details={"client_ip": client_ip, "guest_iface": settings.GUEST_IFACE},
    )


async def authenticate_and_create_session(
    *,
    request: Request,
    payload: StartSessionRequest,
    store: "SessionStore",
    settings: "Settings",
) -> "SessionRecord":
    configured_host = (settings.HOST_WALLET_ADDRESS or "").strip()
    if configured_host and payload.host_wallet_address.lower() != configured_host.lower():
        raise HostWalletMismatch(
            "host_wallet_address does not match this node's HOST_WALLET_ADDRESS.",
            details={
                "expected": configured_host.lower(),
                "got": payload.host_wallet_address.lower(),
            },
        )

    mac = resolve_guest_mac(request, settings, payload.mac_address)
    try:
        verify_session_start_signature(
            guest_wallet=payload.guest_wallet_address,
            host_wallet=payload.host_wallet_address,
            mac_address=mac,
            quota_bytes=payload.quota_bytes,
            nonce=str(payload.nonce),
            signature_hex=payload.guest_signature,
        )
    except ValueError as exc:
        raise InvalidSignature(str(exc)) from exc

    # Iteration 3 — host-set guest limit (None = unlimited, the default).
    if settings.MAX_GUESTS is not None:
        others = [r for r in await store.list_active_sessions() if r.mac_address != mac]
        if len(others) >= settings.MAX_GUESTS:
            raise HostFull(
                "This host is full right now. Try again later.",
                details={"max_guests": settings.MAX_GUESTS},
            )

    authoritative = payload.model_copy(update={"mac_address": mac})
    return await store.create_session(
        payload=authoritative,
        ttl_seconds=settings.SESSION_DEFAULT_TTL_SECONDS,
    )
