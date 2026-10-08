"""Iteration 3 — periodic micropayment scheme, host (router) side.

``SessionEscrow`` locks the guest's deposit once and settles once, paying
the host ``amount * bytes / quota`` against a host-signed receipt. On top of
that, the router runs:

1. **Periodic checkpoints** — every ``SETTLEMENT_CHECKPOINT_SECONDS`` it signs
   a receipt for each active on-chain session's usage so far. The running
   cost is shown to the guest (``accrued_payment_wei``); the signature stays
   on the host because the contract has no receipt nonce, so a guest holding
   a stream of receipts could settle with the oldest, cheapest one.

2. **Host-driven settlement** — once a session stops, the guest gets
   ``SETTLE_GRACE_SECONDS`` to call ``closeSession`` from the app. If they
   haven't, the router submits it itself with the final receipt, so the
   host is paid even if the guest walks away. Retries with a cap; survives
   restarts when ``PERSIST_SESSIONS=true``.

3. **Dispute-window guard** — a session still running after
   ``SESSION_MAX_AGE_SECONDS`` is stopped so it can be settled before the
   guest becomes able to ``disputeSession`` (24 h after opening), which
   would refund them everything.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from typing import Any, Literal, Protocol

from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.errors import SessionNotActive
from strata_host.logging_setup import get_logger
from strata_host.settlement import sign_settlement
from strata_host.store import SessionRecord, SessionStore

TxState = Literal["success", "reverted", "pending", "unknown"]

# Only what the settler needs, so it doesn't depend on contracts/abi/ being
# present on the Pi.
ESCROW_SETTLE_ABI: list[dict[str, Any]] = [
    {
        "type": "function",
        "name": "closeSession",
        "stateMutability": "nonpayable",
        "inputs": [
            {"name": "sessionId", "type": "uint256"},
            {"name": "bytesConsumed", "type": "uint128"},
            {"name": "quotaBytes", "type": "uint128"},
            {"name": "hostSig", "type": "bytes"},
        ],
        "outputs": [],
    },
    {
        "type": "function",
        "name": "sessions",
        "stateMutability": "view",
        "inputs": [{"name": "", "type": "uint256"}],
        "outputs": [
            {"name": "guest", "type": "address"},
            {"name": "host", "type": "address"},
            {"name": "amount", "type": "uint128"},
            {"name": "openedAt", "type": "uint64"},
            {"name": "closed", "type": "bool"},
            {"name": "sessionRef", "type": "bytes32"},
        ],
    },
    {
        "type": "event",
        "name": "PaymentSettled",
        "anonymous": False,
        "inputs": [
            {"name": "sessionId", "type": "uint256", "indexed": True},
            {"name": "host", "type": "address", "indexed": True},
            {"name": "hostPayment", "type": "uint128", "indexed": False},
            {"name": "guest", "type": "address", "indexed": True},
            {"name": "refund", "type": "uint128", "indexed": False},
        ],
    },
]


class EscrowSettler(Protocol):
    async def is_closed(self, chain_session_id: int) -> bool: ...

    async def send_close(
        self, chain_session_id: int, bytes_consumed: int, quota_bytes: int, host_sig: str
    ) -> str: ...

    async def wait(self, tx_hash: str, timeout: float) -> tuple[TxState, int | None]: ...

    async def tx_state(self, tx_hash: str) -> tuple[TxState, int | None]: ...


class Web3EscrowSettler:
    """Talks to SessionEscrow with the host's key (HOST_SIGNING_PRIVATE_KEY)."""

    def __init__(self, settings: Settings) -> None:
        from eth_account import Account
        from web3 import AsyncWeb3

        self._rpc_url = settings.chain_rpc_url()
        self._escrow = AsyncWeb3.to_checksum_address(settings.SESSION_ESCROW_ADDRESS)
        self._chain_id = settings.CHAIN_ID
        self._account = Account.from_key(settings.HOST_SIGNING_PRIVATE_KEY)

    @asynccontextmanager
    async def _w3(self) -> AsyncIterator[Any]:
        from web3 import AsyncWeb3
        from web3.providers import AsyncHTTPProvider
        from web3.providers.persistent import WebSocketProvider

        if self._rpc_url.startswith(("ws://", "wss://")):
            async with AsyncWeb3(WebSocketProvider(self._rpc_url)) as w3:
                yield w3
        else:
            w3 = AsyncWeb3(AsyncHTTPProvider(self._rpc_url))
            try:
                yield w3
            finally:
                await w3.provider.disconnect()

    def _contract(self, w3: Any) -> Any:
        return w3.eth.contract(address=self._escrow, abi=ESCROW_SETTLE_ABI)

    async def is_closed(self, chain_session_id: int) -> bool:
        async with self._w3() as w3:
            row = await self._contract(w3).functions.sessions(chain_session_id).call()
        return bool(row[4])

    async def send_close(
        self, chain_session_id: int, bytes_consumed: int, quota_bytes: int, host_sig: str
    ) -> str:
        from web3 import Web3

        sig = bytes.fromhex(host_sig.removeprefix("0x"))
        async with self._w3() as w3:
            fn = self._contract(w3).functions.closeSession(
                chain_session_id, bytes_consumed, quota_bytes, sig
            )
            # build_transaction estimates gas, so a call that would revert
            # (already closed, bad signature) raises here instead of
            # wasting gas on-chain.
            tx = await fn.build_transaction(
                {
                    "from": self._account.address,
                    "nonce": await w3.eth.get_transaction_count(self._account.address, "pending"),
                    "chainId": self._chain_id,
                }
            )
            signed = self._account.sign_transaction(tx)
            tx_hash = await w3.eth.send_raw_transaction(signed.raw_transaction)
        return Web3.to_hex(tx_hash)

    def _host_payment(self, w3: Any, receipt: Any) -> int | None:
        from web3.logs import DISCARD

        # The receipt also carries the token's Transfer logs; skip them quietly.
        events = self._contract(w3).events.PaymentSettled().process_receipt(
            receipt, errors=DISCARD
        )
        return int(events[0]["args"]["hostPayment"]) if events else None

    async def wait(self, tx_hash: str, timeout: float) -> tuple[TxState, int | None]:
        async with self._w3() as w3:
            try:
                receipt = await w3.eth.wait_for_transaction_receipt(tx_hash, timeout=timeout)
            except Exception:  # noqa: BLE001 — TimeExhausted and transport errors
                return await self._state_with(w3, tx_hash)
            if receipt["status"] != 1:
                return ("reverted", None)
            return ("success", self._host_payment(w3, receipt))

    async def tx_state(self, tx_hash: str) -> tuple[TxState, int | None]:
        async with self._w3() as w3:
            return await self._state_with(w3, tx_hash)

    async def _state_with(self, w3: Any, tx_hash: str) -> tuple[TxState, int | None]:
        from web3.exceptions import TransactionNotFound

        try:
            receipt = await w3.eth.get_transaction_receipt(tx_hash)
        except TransactionNotFound:
            try:
                await w3.eth.get_transaction(tx_hash)
                return ("pending", None)
            except TransactionNotFound:
                return ("unknown", None)
        if receipt["status"] != 1:
            return ("reverted", None)
        return ("success", self._host_payment(w3, receipt))


class PaymentService:
    def __init__(
        self,
        settings: Settings,
        store: SessionStore,
        enforcer: EnforcerService,
        settler: EscrowSettler | None = None,
    ) -> None:
        self._settings = settings
        self._store = store
        self._enforcer = enforcer
        self._settler = settler
        self._logger = get_logger("payments")
        self._tasks: list[asyncio.Task] = []

    # --- lifecycle -------------------------------------------------------------
    async def start(self) -> None:
        self._tasks.append(
            asyncio.create_task(
                self._loop(self.checkpoint_once, self._settings.SETTLEMENT_CHECKPOINT_SECONDS),
                name="payments-checkpoint",
            )
        )
        self._tasks.append(
            asyncio.create_task(
                self._loop(self.settle_once, self._settings.SETTLE_POLL_SECONDS),
                name="payments-settle",
            )
        )
        self._logger.info(
            "payments.started",
            checkpoint_seconds=self._settings.SETTLEMENT_CHECKPOINT_SECONDS,
            auto_settle=self._settler is not None,
            grace_seconds=self._settings.SETTLE_GRACE_SECONDS,
        )

    async def stop(self) -> None:
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            try:
                await task
            except asyncio.CancelledError:
                pass
        self._tasks.clear()

    async def _loop(self, step, interval: float) -> None:
        while True:
            await asyncio.sleep(interval)
            try:
                await step()
            except Exception as exc:  # noqa: BLE001 — keep the loop alive
                self._logger.warning("payments.step_failed", step=step.__name__, error=repr(exc))

    # --- 1. periodic checkpoints -----------------------------------------------
    async def checkpoint_once(self) -> int:
        """Sign a receipt for every active on-chain session whose usage moved
        since its last checkpoint. Returns how many were signed."""
        signed = 0
        now = datetime.now(UTC)
        for record in await self._store.list_active_sessions():
            if record.chain_session_id is None:
                continue
            quota = max(1, record.quota_bytes)
            consumed = min(record.bytes_used, quota)
            if record.checkpoint_bytes == consumed:
                continue
            _, sig = sign_settlement(
                private_key_hex=self._settings.HOST_SIGNING_PRIVATE_KEY,
                chain_id=self._settings.CHAIN_ID,
                escrow_address=self._settings.SESSION_ESCROW_ADDRESS,
                session_id=record.chain_session_id,
                bytes_consumed=consumed,
                quota_bytes=quota,
            )
            await self._store.record_checkpoint(
                record.session_id, bytes_consumed=consumed, signature=sig, at=now
            )
            signed += 1
            self._logger.info(
                "payments.checkpoint",
                session_id=str(record.session_id),
                chain_session_id=record.chain_session_id,
                bytes_consumed=consumed,
                quota_bytes=quota,
                accrued_payment_wei=str(record.accrued_payment_wei()),
            )
        return signed

    # --- 3. dispute-window guard -------------------------------------------------
    async def stop_overdue_sessions(self) -> int:
        cutoff = datetime.now(UTC) - timedelta(seconds=self._settings.SESSION_MAX_AGE_SECONDS)
        stopped = 0
        for record in await self._store.list_active_sessions():
            if record.chain_session_id is None or record.started_at > cutoff:
                continue
            try:
                rec = await self._store.stop_session(record.session_id, reason="host_stop")
            except SessionNotActive:
                continue
            await self._store.apply_settlement_fields(rec.session_id, self._settings)
            await self._enforcer.disconnect(rec.mac_address, origin="payments")
            stopped += 1
            self._logger.warning(
                "payments.session_max_age_stop",
                session_id=str(rec.session_id),
                hint="stopped so the host can settle before the guest may dispute",
            )
        return stopped

    # --- 2. host-driven settlement ------------------------------------------------
    async def settle_once(self) -> None:
        await self.stop_overdue_sessions()
        if self._settler is None:
            return
        grace = timedelta(seconds=self._settings.SETTLE_GRACE_SECONDS)
        now = datetime.now(UTC)
        for record in await self._store.list_unsettled_chain_sessions():
            if record.stopped_at is not None and now - record.stopped_at < grace:
                continue  # the guest's turn to settle from the app
            await self._settle_one(record)

    async def _settle_one(self, record: SessionRecord) -> None:
        sid = record.session_id
        chain_id = record.chain_session_id
        log = self._logger.bind(session_id=str(sid), chain_session_id=chain_id)

        if record.settlement_attempts >= self._settings.SETTLE_MAX_ATTEMPTS:
            await self._store.update_settlement(
                sid, status="failed", error=record.settlement_error
            )
            log.error("payments.settle_gave_up", attempts=record.settlement_attempts,
                      last_error=record.settlement_error)
            return

        if record.host_settlement_sig is None:
            # Stop-time signing can fail (e.g. key added after the session
            # stopped); sign now from the recorded usage.
            await self._store.apply_settlement_fields(sid, self._settings)
            record = await self._store.get_by_session_id(sid) or record
            if record.host_settlement_sig is None:
                await self._store.update_settlement(
                    sid, error="no host receipt; check HOST_SIGNING_PRIVATE_KEY",
                    count_attempt=True,
                )
                return

        try:
            # A tx from an earlier round whose outcome we never saw.
            if record.settlement_tx_hash:
                state, payment = await self._settler.tx_state(record.settlement_tx_hash)
                if state == "success":
                    await self._mark_settled(record, record.settlement_tx_hash, payment, log)
                    return
                if state == "pending":
                    return  # don't send a second tx while the first may still mine

            if await self._settler.is_closed(chain_id):
                await self._store.update_settlement(sid, status="closed_by_guest")
                log.info("payments.closed_by_guest")
                return

            tx_hash = await self._settler.send_close(
                chain_id,
                record.settlement_bytes_consumed,
                record.settlement_quota_bytes,
                record.host_settlement_sig,
            )
            await self._store.update_settlement(sid, tx_hash=tx_hash, count_attempt=True)
            log.info("payments.settle_sent", tx_hash=tx_hash)

            state, payment = await self._settler.wait(
                tx_hash, self._settings.SETTLE_TX_TIMEOUT_SECONDS
            )
            if state == "success":
                await self._mark_settled(record, tx_hash, payment, log)
            else:
                await self._store.update_settlement(sid, error=f"closeSession tx {state}")
                log.warning("payments.settle_not_confirmed", tx_hash=tx_hash, state=state)
        except Exception as exc:  # noqa: BLE001 — RPC down, revert on estimate, …
            await self._store.update_settlement(
                sid, error=f"{type(exc).__name__}: {exc}"[:300], count_attempt=True
            )
            log.warning("payments.settle_failed", error=repr(exc))

    async def _mark_settled(self, record, tx_hash, payment, log) -> None:
        await self._store.update_settlement(
            record.session_id, status="settled", tx_hash=tx_hash, host_payment_wei=payment
        )
        log.info("payments.settled", tx_hash=tx_hash, host_payment_wei=str(payment))
