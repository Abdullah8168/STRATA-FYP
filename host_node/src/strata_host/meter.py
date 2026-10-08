import asyncio
import random
import sys
from datetime import UTC, datetime

from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.logging_setup import get_logger
from strata_host.store import SessionStore
from strata_host.traffic import TrafficReader


class MeterService:
    """Interval-based usage accounting (default tick: ``METER_TICK_SECONDS``).

    On Linux with a :class:`TrafficReader`, absolute nf_conntrack byte counters
    per guest MAC are snapshotted and differenced against a per-session
    baseline. This is **not** packet-real-time; it updates every meter tick.

    When ``DEMO_MODE=true`` and there is no traffic reader (laptop demos),
    synthetic random increments are applied. With a real reader random bytes
    are never used, whatever DEMO_MODE says — idle sessions simply report
    zero growth until conntrack shows traffic.
    """

    def __init__(
        self,
        store: SessionStore,
        enforcer: EnforcerService,
        settings: Settings,
        traffic_reader: TrafficReader | None = None,
    ) -> None:
        self._store = store
        self._enforcer = enforcer
        self._settings = settings
        self._traffic_reader = traffic_reader
        self._logger = get_logger("meter")
        self._task: asyncio.Task | None = None
        self._logged_mode = False

    async def start_loop(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._run_loop(), name="meter-loop")

    async def stop_loop(self) -> None:
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        finally:
            self._task = None

    async def _run_loop(self) -> None:
        while True:
            await asyncio.sleep(self._settings.METER_TICK_SECONDS)

            if not self._logged_mode:
                self._logged_mode = True
                real = (
                    self._traffic_reader is not None
                    and sys.platform.startswith("linux")
                )
                self._logger.info(
                    "meter.mode",
                    demo_mode=self._settings.DEMO_MODE,
                    linux_traffic_reader=real,
                    tick_seconds=self._settings.METER_TICK_SECONDS,
                )
                if not self._settings.DEMO_MODE and not real:
                    self._logger.warning(
                        "meter.real_mode_without_linux_reader",
                        hint="Run on the Pi as root so /proc/net/nf_conntrack is readable",
                    )

            has_reader = self._traffic_reader is not None and sys.platform.startswith("linux")
            active_sessions = await self._store.list_active_sessions()
            now = datetime.now(UTC)
            for record in active_sessions:
                if record.expires_at <= now:
                    stopped = await self._store.stop_session(
                        session_id=record.session_id,
                        reason="host_stop",
                    )
                    await self._store.apply_settlement_fields(
                        stopped.session_id,
                        self._settings,
                    )
                    await self._enforcer.disconnect(stopped.mac_address, origin="meter")
                    self._logger.info(
                        "meter.session_ttl_expired",
                        session_id=str(stopped.session_id),
                        mac_address=stopped.mac_address,
                    )
                    continue

                bytes_in = 0
                bytes_out = 0
                used_real = False

                if has_reader:
                    abs_in, abs_out = self._traffic_reader.absolute_pair(record.mac_address)
                    if not record.meter_baseline_ready:
                        await self._store.set_meter_nf_baseline(
                            record.session_id,
                            abs_in,
                            abs_out,
                        )
                        continue
                    fresh = await self._store.get_by_session_id(record.session_id)
                    if fresh is None or fresh.status != "active":
                        continue
                    net_in = max(0, abs_in - fresh.meter_nf_baseline_in)
                    net_out = max(0, abs_out - fresh.meter_nf_baseline_out)
                    # Absolute-from-baseline minus already accounted totals
                    # avoids double-counting across ticks.
                    bytes_in = max(0, net_in - fresh.bytes_in)
                    bytes_out = max(0, net_out - fresh.bytes_out)
                    if bytes_in > 0 or bytes_out > 0:
                        used_real = True

                # Synthetic bytes only where there is no real reader (laptop
                # demos). On a Pi they would end up in an on-chain bill.
                if not used_real and self._settings.DEMO_MODE and not has_reader:
                    total_bytes = random.randint(256 * 1024, 4 * 1024 * 1024)
                    bytes_in = random.randint(int(total_bytes * 0.35), int(total_bytes * 0.75))
                    bytes_out = max(0, total_bytes - bytes_in)
                elif not used_real:
                    continue

                updated = await self._store.increment_usage(
                    session_id=record.session_id,
                    bytes_in=bytes_in,
                    bytes_out=bytes_out,
                )
                if updated is None:
                    continue

                if updated.bytes_used >= updated.quota_bytes:
                    stopped = await self._store.stop_session(
                        session_id=updated.session_id,
                        reason="quota_exhausted",
                    )
                    await self._store.apply_settlement_fields(
                        stopped.session_id,
                        self._settings,
                    )
                    await self._enforcer.disconnect(stopped.mac_address, origin="meter")
                    self._logger.info(
                        "meter.quota_exhausted",
                        session_id=str(stopped.session_id),
                        mac_address=stopped.mac_address,
                        bytes_used=stopped.bytes_used,
                        quota_bytes=stopped.quota_bytes,
                    )
