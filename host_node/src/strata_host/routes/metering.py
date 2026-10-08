from datetime import UTC, datetime

from fastapi import APIRouter, Depends, Path

from strata_host.errors import MacNotFound
from strata_host.models import MAC_REGEX, MeteringResponse
from strata_host.store import SessionStore

router = APIRouter(tags=["metering"])


def _get_store() -> SessionStore:
    raise RuntimeError("Dependency override not configured.")


@router.get("/metering/{mac}", response_model=MeteringResponse)
async def get_metering(
    mac: str = Path(pattern=MAC_REGEX),
    store: SessionStore = Depends(_get_store),
) -> MeteringResponse:
    normalized = mac.lower()
    record = await store.get_by_mac_address(normalized)
    if record is None:
        raise MacNotFound("MAC address has no known session history.")

    return MeteringResponse(
        mac_address=record.mac_address,
        session_id=record.session_id,
        bytes_in=record.bytes_in,
        bytes_out=record.bytes_out,
        bytes_total=record.bytes_used,
        quota_bytes=record.quota_bytes,
        status="active" if record.status == "active" else "stopped",
        last_updated=datetime.now(UTC),
    )

