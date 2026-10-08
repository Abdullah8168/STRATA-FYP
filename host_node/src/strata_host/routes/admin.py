"""Phase G — admin endpoints, gated by ``ADMIN_TOKEN``.

When ``ADMIN_TOKEN`` is unset, every endpoint here returns 503. We don't
fail-open on a missing token because the operations these expose
(reconciling chain events, dumping firewall state) are the kind of thing
you really don't want a curious guest poking at.
"""

from __future__ import annotations

import asyncio
from typing import Any, Protocol

from fastapi import APIRouter, Depends, Header, HTTPException, status
from pydantic import BaseModel, ConfigDict

from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.host_config import (
    HostConfigError,
    HostConfigStore,
    Hotspot,
    apply_listing,
    listing_view,
    validate_listing,
    validate_wifi,
)
from strata_host.store import SessionStore

router = APIRouter(prefix="/admin", tags=["admin"])


class _ChainListenerLike(Protocol):
    async def reconcile(self, lookback_blocks: int = 1024) -> int: ...


def _get_settings() -> Settings:
    raise RuntimeError("Dependency override not configured.")


def _get_chain() -> Any:
    raise RuntimeError("Dependency override not configured.")


def _get_enforcer() -> EnforcerService:
    raise RuntimeError("Dependency override not configured.")


def _get_store() -> SessionStore:
    raise RuntimeError("Dependency override not configured.")


def _get_hotspot() -> Hotspot:
    raise RuntimeError("Dependency override not configured.")


def _get_host_config_store() -> HostConfigStore:
    raise RuntimeError("Dependency override not configured.")


def _check_admin(
    settings: Settings,
    authorization: str | None,
) -> None:
    if not settings.ADMIN_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": "ADMIN_DISABLED", "message": "ADMIN_TOKEN is not set"},
        )
    expected = f"Bearer {settings.ADMIN_TOKEN}"
    if authorization != expected:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "UNAUTHORIZED", "message": "bad bearer token"},
        )


@router.post("/reconcile")
async def admin_reconcile(
    lookback_blocks: int = 1024,
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(_get_settings),
    chain: Any = Depends(_get_chain),
) -> dict:
    """Force a chain reconciliation pass.

    Useful after a Pi reboot if the listener didn't catch every event
    while it was offline. Returns the count of late-authorized sessions.
    """
    _check_admin(settings, authorization)
    if not hasattr(chain, "reconcile"):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": "CHAIN_DISABLED",
                "message": "ChainListener is not active (CHAIN_ENABLED=false?)",
            },
        )
    count = await chain.reconcile(lookback_blocks=lookback_blocks)
    return {"reconciled": count, "lookback_blocks": lookback_blocks}


@router.get("/firewall/state")
async def admin_firewall_state(
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(_get_settings),
    enforcer: EnforcerService = Depends(_get_enforcer),
) -> dict:
    """Dump the in-memory mirror of the strata_authed set.

    The kernel set is the ground truth, but the mirror is what the
    enforcer just admitted/disconnected. Drift between them is itself a
    bug worth knowing about (the test suite asserts they line up).
    """
    _check_admin(settings, authorization)
    return {
        "authed_macs": enforcer.current_macs(),
        "count": len(enforcer.current_macs()),
    }


# --- Iteration 3: host controls for the app -----------------------------------


class HostUpdate(BaseModel):
    """Only the fields sent are changed. ``max_guests: null`` = no limit."""

    model_config = ConfigDict(extra="forbid")

    display_name: str | None = None
    price_per_gb_wei: str | None = None
    price_per_gb: float | None = None
    max_guests: int | None = None
    wifi_name: str | None = None
    wifi_password: str | None = None


class SharingUpdate(BaseModel):
    enabled: bool


def _bad_value(exc: HostConfigError) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={"code": "BAD_VALUE", "message": str(exc)},
    )


async def _host_view(settings: Settings, store: SessionStore, hotspot: Hotspot) -> dict:
    return {
        **listing_view(settings),
        "wifi_name": settings.HOST_SSID,
        "sharing_enabled": await asyncio.to_thread(hotspot.is_enabled),
        "host_wallet_address": settings.HOST_WALLET_ADDRESS,
        "chain_enabled": settings.CHAIN_ENABLED,
        "active_guests": len(await store.list_active_sessions()),
    }


@router.get("/host")
async def admin_get_host(
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(_get_settings),
    store: SessionStore = Depends(_get_store),
    hotspot: Hotspot = Depends(_get_hotspot),
) -> dict:
    """The host's own settings. A 200 here also proves the app is paired
    with this Pi (right address + right ADMIN_TOKEN)."""
    _check_admin(settings, authorization)
    return await _host_view(settings, store, hotspot)


@router.put("/host")
async def admin_update_host(
    body: HostUpdate,
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(_get_settings),
    store: SessionStore = Depends(_get_store),
    hotspot: Hotspot = Depends(_get_hotspot),
    config_store: HostConfigStore = Depends(_get_host_config_store),
) -> dict:
    """Change listing settings and/or the Wi-Fi name/password.

    Changing the Wi-Fi restarts the hotspot: connected guests drop and must
    rejoin (with the new password, if it changed).
    """
    _check_admin(settings, authorization)
    changes = body.model_dump(exclude_unset=True)
    wifi_name = changes.pop("wifi_name", None)
    wifi_password = changes.pop("wifi_password", None)
    try:
        listing = validate_listing(changes)
        validate_wifi(wifi_name, wifi_password)
    except HostConfigError as exc:
        raise _bad_value(exc) from None

    wifi_changed = wifi_name is not None or wifi_password is not None
    if wifi_changed:
        try:
            await asyncio.to_thread(hotspot.set_wifi, wifi_name, wifi_password)
        except (OSError, RuntimeError) as exc:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail={"code": "HOTSPOT_FAILED", "message": str(exc)[:200]},
            ) from None
        if wifi_name is not None:
            listing["HOST_SSID"] = wifi_name

    if listing:
        await asyncio.to_thread(config_store.save, listing)
        apply_listing(settings, listing)
    return {**await _host_view(settings, store, hotspot), "wifi_restarted": wifi_changed}


@router.post("/sharing")
async def admin_set_sharing(
    body: SharingUpdate,
    authorization: str | None = Header(default=None),
    settings: Settings = Depends(_get_settings),
    hotspot: Hotspot = Depends(_get_hotspot),
) -> dict:
    """Turn the STRATA Wi-Fi on/off. Not kept across a reboot (a reboot
    always turns sharing back on), so a host can't lock themselves out."""
    _check_admin(settings, authorization)
    try:
        await asyncio.to_thread(hotspot.set_enabled, body.enabled)
    except RuntimeError as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"code": "HOTSPOT_FAILED", "message": str(exc)[:200]},
        ) from None
    return {"sharing_enabled": await asyncio.to_thread(hotspot.is_enabled)}
