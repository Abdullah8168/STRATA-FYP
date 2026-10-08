"""Phase E — real on-chain listener.

Subscribes to ``SessionEscrow.SessionOpened`` events on Polygon Amoy
filtered by ``host == HOST_WALLET_ADDRESS`` and admits the matching MAC
to the firewall when a session is paid.

This module is only imported when ``settings.CHAIN_ENABLED`` is true and
``SESSION_ESCROW_ADDRESS`` + ``HOST_WALLET_ADDRESS`` are configured. See
``strata_host.main.create_app``.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any
from uuid import UUID

from web3 import AsyncWeb3
from web3.providers import AsyncHTTPProvider
from web3.providers.persistent import WebSocketProvider

from strata_host.enforcer import EnforcerService
from strata_host.logging_setup import get_logger
from strata_host.store import SessionStore


def _rpc_is_websocket(url: str) -> bool:
    u = (url or "").strip().lower()
    return u.startswith("ws://") or u.startswith("wss://")

# Minimal ABI fragment — only the SessionOpened event is needed at
# runtime. Keeping this in code (instead of reading deployments/amoy.json
# at startup) lets the host node boot without a live contracts/ workspace.
SESSION_OPENED_ABI: list[dict[str, Any]] = [
    {
        "anonymous": False,
        "inputs": [
            {"indexed": True, "internalType": "uint256", "name": "sessionId", "type": "uint256"},
            {"indexed": True, "internalType": "address", "name": "guest", "type": "address"},
            {"indexed": True, "internalType": "address", "name": "host", "type": "address"},
            {"indexed": False, "internalType": "uint128", "name": "amount", "type": "uint128"},
            {"indexed": False, "internalType": "bytes32", "name": "sessionRef", "type": "bytes32"},
            {"indexed": False, "internalType": "uint64", "name": "openedAt", "type": "uint64"},
        ],
        "name": "SessionOpened",
        "type": "event",
    }
]


def load_session_escrow_abi() -> list[dict[str, Any]]:
    """Load the full SessionEscrow ABI from contracts/abi/ if available;
    fall back to the SessionOpened-only ABI otherwise."""
    candidate = (
        Path(__file__).resolve().parents[3] / "contracts" / "abi" / "SessionEscrow.json"
    )
    if candidate.exists():
        try:
            data = json.loads(candidate.read_text())
            return data["abi"]
        except (KeyError, json.JSONDecodeError):
            pass
    return SESSION_OPENED_ABI


class ChainListener:
    """Async listener that admits guest MACs when the on-chain SessionEscrow
    confirms payment.

    Supports both WebSocket (``wss://`` / ``ws://``) and HTTP JSON-RPC
    (``http://`` / ``https://``) endpoints. Hardhat ``localhost:8545`` uses
    HTTP polling of ``eth_getLogs``; Amoy typically uses WSS subscriptions.
    Either way, ``confirmations > 0`` runs a tip watcher that calls
    ``_promote_pending``.

    Lifecycle is managed by ``main.create_app``'s lifespan context.
    """

    _BACKOFFS = (1, 2, 4, 8, 16, 30)

    def __init__(
        self,
        wss_url: str,
        session_escrow_address: str,
        host_address: str,
        store: SessionStore,
        enforcer: EnforcerService,
        session_escrow_abi: list[dict[str, Any]] | None = None,
        from_block: int | str = "latest",
        confirmations: int = 0,
    ) -> None:
        # Name kept for back-compat; value may be http(s) or ws(s).
        self._rpc_url = wss_url
        self._escrow_address = AsyncWeb3.to_checksum_address(session_escrow_address)
        self._host_address = AsyncWeb3.to_checksum_address(host_address)
        self._store = store
        self._enforcer = enforcer
        self._abi = session_escrow_abi or load_session_escrow_abi()
        self._from_block = from_block
        self._confirmations = max(0, confirmations)
        self._logger = get_logger("chain")
        self._task: asyncio.Task | None = None
        self._stopping = asyncio.Event()
        # Pending events keyed on (block, log_index) waiting for confirmations.
        self._pending: dict[tuple[int, int], dict[str, Any]] = {}
        # Last chain tip processed by the confirmation / reorg watcher.
        self._last_seen_block: int = 0
        # How often to poll eth.block_number / eth_getLogs.
        self._block_poll_seconds: float = 2.0
        # HTTP poll cursor (exclusive lower bound for next get_logs fromBlock).
        self._http_from_block: int | None = None

    def _use_websocket(self) -> bool:
        return _rpc_is_websocket(self._rpc_url)

    def _http_w3(self) -> AsyncWeb3:
        return AsyncWeb3(AsyncHTTPProvider(self._rpc_url))

    async def start(self) -> None:
        if self._task is not None and not self._task.done():
            return
        self._stopping.clear()
        self._task = asyncio.create_task(self._loop(), name="chain-listener")
        self._logger.info(
            "chain.listener_started",
            rpc=self._rpc_url,
            transport="websocket" if self._use_websocket() else "http_poll",
            escrow=self._escrow_address,
            host=self._host_address,
            confirmations=self._confirmations,
        )

    async def stop(self) -> None:
        self._stopping.set()
        if self._task is None:
            return
        self._task.cancel()
        try:
            await self._task
        except asyncio.CancelledError:
            pass
        finally:
            self._task = None
        self._logger.info("chain.listener_stopped")

    # --- Phase G — startup reconciliation -------------------------------------
    async def reconcile(self, lookback_blocks: int = 1024) -> int:
        """Scan the last ``lookback_blocks`` for SessionOpened events filtered
        by host_address. For each event whose sessionRef maps to a known local
        session that is still in 'pending_payment', authorize it now.

        Returns the count of late-authorized sessions. Logs
        ``chain.reconciled count=N took=Xs``.
        """
        import time

        started = time.perf_counter()
        late = 0
        try:
            if self._use_websocket():
                async with AsyncWeb3(WebSocketProvider(self._rpc_url)) as w3:
                    late = await self._reconcile_with_w3(w3, lookback_blocks)
            else:
                w3 = self._http_w3()
                late = await self._reconcile_with_w3(w3, lookback_blocks)
        except Exception as exc:  # noqa: BLE001
            self._logger.warning(
                "chain.reconcile_failed", error=type(exc).__name__
            )
        took = round(time.perf_counter() - started, 3)
        self._logger.info("chain.reconciled", count=late, took=took)
        return late

    async def _reconcile_with_w3(self, w3: AsyncWeb3, lookback_blocks: int) -> int:
        late = 0
        latest = await w3.eth.block_number
        from_block = max(0, latest - lookback_blocks)
        contract = w3.eth.contract(address=self._escrow_address, abi=self._abi)
        event = contract.events.SessionOpened
        host_topic = "0x" + self._host_address[2:].rjust(64, "0").lower()
        logs = await w3.eth.get_logs(
            {
                "address": self._escrow_address,
                "fromBlock": from_block,
                "toBlock": latest,
                "topics": [
                    event.build_filter().topics[0],  # type: ignore[attr-defined]
                    None,
                    None,
                    host_topic,
                ],
            }
        )
        for raw in logs:
            try:
                decoded = event().process_log(raw)  # type: ignore[call-arg]
            except Exception:  # noqa: BLE001
                continue
            if await self._handle_event(decoded, force_confirm=True):
                late += 1
        # Advance HTTP poll cursor so we don't re-fetch the same tip forever.
        self._http_from_block = int(latest) + 1
        return late

    # --- back-compat shim for the Phase A interface ---------------------------
    async def on_session_opened(self, session_id: str, guest_wallet: str) -> None:
        # Real session events come from the websocket; this callback exists
        # purely so the routes/sessions.py call site doesn't need to branch
        # on which implementation is wired up.
        self._logger.debug(
            "chain.on_session_opened_noop",
            session_id=session_id,
            guest_wallet=guest_wallet,
        )

    # --- private --------------------------------------------------------------
    async def _loop(self) -> None:
        attempt = 0
        while not self._stopping.is_set():
            try:
                await self._run_subscription()
                attempt = 0
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                backoff = self._BACKOFFS[min(attempt, len(self._BACKOFFS) - 1)]
                self._logger.warning(
                    "chain.subscription_failed",
                    error=type(exc).__name__,
                    backoff_seconds=backoff,
                )
                attempt += 1
                try:
                    await asyncio.wait_for(self._stopping.wait(), timeout=backoff)
                except asyncio.TimeoutError:
                    pass

    async def _run_subscription(self) -> None:
        """Follow SessionOpened logs and promote pending confirms.

        WebSocket endpoints use ``eth_subscribe("logs")``.
        HTTP endpoints (Hardhat localhost) poll ``eth_getLogs``.
        """
        if self._use_websocket():
            await self._run_websocket_subscription()
        else:
            await self._run_http_poll()

    async def _run_websocket_subscription(self) -> None:
        async with AsyncWeb3(WebSocketProvider(self._rpc_url)) as w3:
            contract = w3.eth.contract(address=self._escrow_address, abi=self._abi)
            event = contract.events.SessionOpened
            host_topic = "0x" + self._host_address[2:].rjust(64, "0").lower()
            session_opened_topic = event.build_filter().topics[0]  # type: ignore[attr-defined]
            filter_params = {
                "address": self._escrow_address,
                "topics": [session_opened_topic, None, None, host_topic],
            }
            sub_id = await w3.eth.subscribe("logs", filter_params)
            self._logger.info(
                "chain.subscription_active",
                subscription_id=sub_id,
                transport="websocket",
                confirmations=self._confirmations,
            )

            watcher: asyncio.Task | None = None
            if self._confirmations > 0:
                watcher = asyncio.create_task(
                    self._block_watcher(w3),
                    name="chain-block-watcher",
                )

            try:
                async for raw in w3.socket.process_subscriptions():  # type: ignore[attr-defined]
                    if self._stopping.is_set():
                        break
                    log = raw.get("result") if isinstance(raw, dict) else raw
                    if log is None:
                        continue
                    try:
                        decoded = event().process_log(log)  # type: ignore[call-arg]
                    except Exception as exc:  # noqa: BLE001
                        self._logger.warning(
                            "chain.event_decode_failed",
                            error=type(exc).__name__,
                        )
                        continue
                    await self._handle_event(decoded)
            finally:
                if watcher is not None:
                    watcher.cancel()
                    try:
                        await watcher
                    except asyncio.CancelledError:
                        pass
                try:
                    await w3.eth.unsubscribe(sub_id)
                except Exception:  # noqa: BLE001
                    pass

    async def _run_http_poll(self) -> None:
        """Poll eth_getLogs + tip for Hardhat / HTTP JSON-RPC endpoints."""
        w3 = self._http_w3()
        contract = w3.eth.contract(address=self._escrow_address, abi=self._abi)
        event = contract.events.SessionOpened
        host_topic = "0x" + self._host_address[2:].rjust(64, "0").lower()
        session_opened_topic = event.build_filter().topics[0]  # type: ignore[attr-defined]

        if self._http_from_block is None:
            tip = int(await w3.eth.block_number)
            self._http_from_block = tip  # start at tip; reconcile covers history
        self._logger.info(
            "chain.subscription_active",
            transport="http_poll",
            from_block=self._http_from_block,
            confirmations=self._confirmations,
        )

        while not self._stopping.is_set():
            try:
                tip = int(await w3.eth.block_number)
                from_block = self._http_from_block or tip
                if tip >= from_block:
                    logs = await w3.eth.get_logs(
                        {
                            "address": self._escrow_address,
                            "fromBlock": from_block,
                            "toBlock": tip,
                            "topics": [
                                session_opened_topic,
                                None,
                                None,
                                host_topic,
                            ],
                        }
                    )
                    for raw in logs:
                        try:
                            decoded = event().process_log(raw)  # type: ignore[call-arg]
                        except Exception as exc:  # noqa: BLE001
                            self._logger.warning(
                                "chain.event_decode_failed",
                                error=type(exc).__name__,
                            )
                            continue
                        await self._handle_event(decoded)
                    self._http_from_block = tip + 1

                if tip != self._last_seen_block:
                    self._last_seen_block = tip
                    await self._check_reorgs(w3)
                    if self._confirmations > 0:
                        await self._promote_pending(tip)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                self._logger.warning(
                    "chain.http_poll_error",
                    error=type(exc).__name__,
                )
                raise

            try:
                await asyncio.wait_for(
                    self._stopping.wait(),
                    timeout=self._block_poll_seconds,
                )
            except asyncio.TimeoutError:
                pass

    async def _block_watcher(self, w3: AsyncWeb3) -> None:
        """Poll chain tip; promote confirmed pending events; drop reorgs."""
        self._logger.info(
            "chain.block_watcher_started",
            poll_seconds=self._block_poll_seconds,
            confirmations=self._confirmations,
        )
        while not self._stopping.is_set():
            try:
                tip = int(await w3.eth.block_number)
                if tip != self._last_seen_block:
                    self._last_seen_block = tip
                    await self._check_reorgs(w3)
                    await self._promote_pending(tip)
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                self._logger.warning(
                    "chain.block_watcher_error",
                    error=type(exc).__name__,
                )
            try:
                await asyncio.wait_for(
                    self._stopping.wait(),
                    timeout=self._block_poll_seconds,
                )
            except asyncio.TimeoutError:
                pass

    async def _check_reorgs(self, w3: AsyncWeb3) -> None:
        """Drop pending events whose transaction receipt disappeared."""
        if not self._pending:
            return
        missing: set[tuple[int, int]] = set()
        for key, ev in list(self._pending.items()):
            tx = ev.get("tx_hash")
            if not tx:
                continue
            try:
                receipt = await w3.eth.get_transaction_receipt(tx)
            except Exception:  # noqa: BLE001
                receipt = None
            if receipt is None:
                missing.add(key)
        if missing:
            await self.drop_reorged(missing)

    async def _handle_event(self, event: Any, *, force_confirm: bool = False) -> bool:
        """Validate + admit. Returns True iff a session was actually
        authorized (used by reconcile() to count "catch-up" admits).

        When ``self._confirmations`` is greater than 0 and force_confirm is
        false, we don't admit immediately — we stash the event and let the
        block-watcher promote it once it's deep enough. ``force_confirm`` is
        only used by reconcile(), which is by definition past the
        confirmation threshold (it's looking at historical blocks).
        """
        try:
            args = event.args
            session_ref = "0x" + bytes(args.sessionRef).hex()
            guest = args.guest.lower()
            chain_session_id = int(args.sessionId)
            amount_wei = int(args.amount)
            tx_hash = event.transactionHash.hex()
            block_number = int(getattr(event, "blockNumber", 0) or 0)
            log_index = int(getattr(event, "logIndex", 0) or 0)
        except Exception as exc:  # noqa: BLE001
            self._logger.warning("chain.event_shape_unexpected", error=type(exc).__name__)
            return False

        record = await self._store.get_by_ref(session_ref)
        if record is None:
            self._logger.warning("chain.session_ref_unknown", ref=session_ref)
            return False
        if record.guest_wallet_address.lower() != guest:
            self._logger.warning(
                "chain.guest_mismatch",
                expected=record.guest_wallet_address,
                got=guest,
            )
            return False
        if record.status != "pending_payment":
            # Already active (idempotent reconcile pass) — no-op + audit.
            self._logger.info(
                "chain.idempotent_event",
                status=record.status,
                local_session=str(record.session_id),
            )
            return False

        if self._confirmations > 0 and not force_confirm:
            # Defer admit until the event is deep enough that a 1-2 block
            # reorg can't undo it.
            key = (block_number, log_index)
            self._pending[key] = {
                "session_ref": session_ref,
                "session_id": record.session_id,
                "mac": record.mac_address,
                "chain_session_id": chain_session_id,
                "tx_hash": tx_hash,
                "block_number": block_number,
                "escrow_amount_wei": amount_wei,
            }
            self._logger.info(
                "chain.session_pending_confirmations",
                local_session=str(record.session_id),
                block=block_number,
                need=self._confirmations,
            )
            return False

        await self._enforcer.admit(record.mac_address, origin="chain")
        await self._store.mark_paid(
            session_id=record.session_id,
            chain_session_id=chain_session_id,
            tx_hash=tx_hash,
            escrow_amount_wei=amount_wei,
        )
        self._logger.info(
            "chain.session_authorized",
            local_session=str(record.session_id),
            chain_session=chain_session_id,
            tx=tx_hash,
            mac=record.mac_address,
        )
        return True

    async def _promote_pending(self, current_block: int) -> None:
        """Walk pending events and admit any that are deep enough."""
        if not self._pending:
            return
        ready = [
            key
            for key, ev in self._pending.items()
            if current_block - ev["block_number"] >= self._confirmations
        ]
        for key in ready:
            ev = self._pending.pop(key)
            # Re-check local state — guest may have cancelled while waiting.
            record = await self._store.get_by_session_id(ev["session_id"])
            if record is None or record.status != "pending_payment":
                self._logger.info(
                    "chain.promote_skipped",
                    local_session=str(ev["session_id"]),
                    status=None if record is None else record.status,
                )
                continue
            await self._enforcer.admit(ev["mac"], origin="chain")
            await self._store.mark_paid(
                session_id=ev["session_id"],
                chain_session_id=ev["chain_session_id"],
                tx_hash=ev["tx_hash"],
                escrow_amount_wei=ev.get("escrow_amount_wei"),
            )
            self._logger.info(
                "chain.session_authorized",
                local_session=str(ev["session_id"]),
                chain_session=ev["chain_session_id"],
                tx=ev["tx_hash"],
                mac=ev["mac"],
                confirmations=current_block - ev["block_number"],
            )

    async def drop_reorged(self, missing_keys: set[tuple[int, int]]) -> None:
        """Hook for the reorg watchdog: drop pending events whose tx hash
        no longer exists on chain. ``chain.reorg_dropped`` fires for each."""
        for key in list(self._pending.keys()):
            if key in missing_keys:
                ev = self._pending.pop(key)
                self._logger.warning(
                    "chain.reorg_dropped",
                    local_session=str(ev["session_id"]),
                    block=ev["block_number"],
                    tx=ev["tx_hash"],
                )


def session_id_to_ref(session_id: UUID) -> str:
    """Re-export so callers don't need a second import path."""
    from strata_host.store import session_id_to_ref as _impl  # avoid cycles

    return _impl(session_id)
