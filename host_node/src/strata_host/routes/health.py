import asyncio
import platform
from datetime import UTC, datetime

from fastapi import APIRouter, Request

from strata_host.models import HealthResponse, VersionResponse, WireGuardHealth

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
async def get_health(request: Request) -> HealthResponse:
    now = datetime.now(UTC)
    started_at: datetime = request.app.state.started_at
    uptime = max(0, int((now - started_at).total_seconds()))
    settings = request.app.state.settings

    wireguard = None
    if settings.WG_ENABLED:
        # status() shells out to ip / wg; keep it off the event loop.
        status = await asyncio.to_thread(request.app.state.wg_routing.status)
        wireguard = WireGuardHealth(**status.to_dict())

    return HealthResponse(
        status="ok",
        service="strata-host-node",
        version=request.app.version,
        uptime_seconds=uptime,
        demo_mode=settings.DEMO_MODE,
        wireguard=wireguard,
    )


@router.get("/version", response_model=VersionResponse)
async def get_version(request: Request) -> VersionResponse:
    return VersionResponse(
        service="strata-host-node",
        version=request.app.version,
        python=platform.python_version(),
    )

