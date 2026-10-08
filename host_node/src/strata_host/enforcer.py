"""EnforcerService — the SINGLE owner of the strata_authed nftables set.

Phase G architecture rule:
    Every admit/disconnect path in the codebase goes through this class.
    The captive portal, the chain listener, the metering loop, and the
    admin API call ``EnforcerService.admit/disconnect``; nothing else
    imports ``firewall/nft_set.py``.

To prevent races between a chain-listener admit and a meter-loop disconnect
landing on the same MAC at the same time, requests are serialized through
an ``asyncio.Queue`` consumed by a single worker task. The queue also
makes it trivial to log the *origin* of every mutation (portal, chain,
meter, admin), which is exactly what an operator wants when answering
"who admitted this MAC?" at 2am.

In fake mode (``NftSet.fake_mode()`` true) we skip the kernel side-effect
but still maintain the in-memory mirror so ``current_macs()`` and the
``/admin/firewall/state`` endpoint return useful data on a developer
laptop.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Literal

from strata_host.firewall.nft_set import NftSet, NftSetError
from strata_host.logging_setup import get_logger


Origin = Literal["portal", "chain", "meter", "admin", "test"]


@dataclass
class _Op:
    action: Literal["admit", "disconnect"]
    mac: str
    origin: Origin
    done: asyncio.Event = field(default_factory=asyncio.Event)
    error: BaseException | None = None


class EnforcerService:
    def __init__(self, nft_set: NftSet | None = None) -> None:
        self._logger = get_logger("enforcer")
        # NftSet is constructed lazily so unit tests that don't run inside a
        # running loop can still create the EnforcerService.
        self._nft_set = nft_set
        self._queue: asyncio.Queue[_Op] | None = None
        self._worker: asyncio.Task | None = None
        # Mirror of the kernel set so admin endpoints / fake mode can answer
        # "who's currently admitted?" without hitting `nft` again.
        self._current: set[str] = set()

    # --- lifecycle -------------------------------------------------------
    async def start(self) -> None:
        """Spawn the queue worker. Called from FastAPI lifespan."""
        if self._worker is not None and not self._worker.done():
            return
        if self._nft_set is None:
            self._nft_set = NftSet()
        self._queue = asyncio.Queue()
        self._worker = asyncio.create_task(self._worker_loop(), name="enforcer-worker")
        self._logger.info("enforcer.started", fake=self._nft_set.fake_mode())

    async def stop(self) -> None:
        if self._worker is None:
            return
        self._worker.cancel()
        try:
            await self._worker
        except asyncio.CancelledError:
            pass
        finally:
            self._worker = None
            self._queue = None
        self._logger.info("enforcer.stopped")

    # --- public API ------------------------------------------------------
    async def admit(self, mac_address: str, *, origin: Origin = "portal") -> None:
        await self._enqueue("admit", mac_address, origin)

    async def disconnect(self, mac_address: str, *, origin: Origin = "portal") -> None:
        await self._enqueue("disconnect", mac_address, origin)

    def current_macs(self) -> list[str]:
        """In-memory mirror of the strata_authed set. Used by
        /admin/firewall/state and chatroom presence."""
        return sorted(self._current)

    # --- internals -------------------------------------------------------
    async def _enqueue(self, action: str, mac: str, origin: Origin) -> None:
        if self._queue is None:
            # Tests that construct EnforcerService without calling start()
            # take the fast path: log the action, mutate the mirror, and
            # return. This keeps Phase A test_sessions.py green without
            # forcing every test to spin up the worker.
            self._fast_path(action, mac, origin)
            return

        op = _Op(action=action, mac=mac, origin=origin)  # type: ignore[arg-type]
        await self._queue.put(op)
        await op.done.wait()
        if op.error is not None:
            raise op.error

    def _fast_path(self, action: str, mac: str, origin: Origin) -> None:
        if action == "admit":
            self._current.add(mac)
            self._logger.info("enforcer.admit", mac=mac, origin=origin, fake=True)
        else:
            self._current.discard(mac)
            self._logger.info("enforcer.disconnect", mac=mac, origin=origin, fake=True)

    async def _worker_loop(self) -> None:
        assert self._queue is not None
        assert self._nft_set is not None
        while True:
            op = await self._queue.get()
            try:
                if op.action == "admit":
                    await self._nft_set.add(op.mac)
                    self._current.add(op.mac)
                    self._logger.info(
                        "enforcer.admit", mac=op.mac, origin=op.origin
                    )
                else:
                    await self._nft_set.remove(op.mac)
                    self._current.discard(op.mac)
                    self._logger.info(
                        "enforcer.disconnect", mac=op.mac, origin=op.origin
                    )
            except NftSetError as exc:
                op.error = exc
                self._logger.warning(
                    "enforcer.nft_failure",
                    mac=op.mac,
                    origin=op.origin,
                    error=str(exc),
                )
            except Exception as exc:  # noqa: BLE001
                op.error = exc
                self._logger.warning(
                    "enforcer.unexpected_failure",
                    mac=op.mac,
                    origin=op.origin,
                    error=type(exc).__name__,
                )
            finally:
                op.done.set()
                self._queue.task_done()
