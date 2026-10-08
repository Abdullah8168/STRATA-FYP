"""Periodic micropayment checkpoints + host-driven settlement (Iteration 3).

The escrow is faked here; ``scripts/iter3_host_settlement_e2e.py`` runs the
same service against a real Hardhat chain.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from eth_account import Account
from eth_account.messages import encode_defunct

from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.models import StartSessionRequest
from strata_host.payments import PaymentService
from strata_host.settlement import receipt_hash
from strata_host.store import SessionRecord, SessionStore

HOST_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # Hardhat #0
HOST = Account.from_key(HOST_KEY).address
ESCROW = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
QUOTA = 1_000_000
DEPOSIT = 5 * 10**18


def _settings(**kw) -> Settings:
    base = {
        "CHAIN_ENABLED": True,
        "CHAIN_ID": 31337,
        "SESSION_ESCROW_ADDRESS": ESCROW,
        "HOST_WALLET_ADDRESS": HOST,
        "HOST_SIGNING_PRIVATE_KEY": HOST_KEY,
        "SETTLE_GRACE_SECONDS": 120,
        "SETTLE_MAX_ATTEMPTS": 3,
    }
    base.update(kw)
    return Settings(**base)


class FakeSettler:
    def __init__(self) -> None:
        self.closed: set[int] = set()
        self.sent: list[tuple] = []
        self.fail_send: Exception | None = None
        self.wait_state = "success"
        self.states: dict[str, str] = {}

    async def is_closed(self, chain_session_id: int) -> bool:
        return chain_session_id in self.closed

    async def send_close(self, chain_session_id, bytes_consumed, quota_bytes, host_sig):
        if self.fail_send:
            raise self.fail_send
        self.sent.append((chain_session_id, bytes_consumed, quota_bytes, host_sig))
        tx = f"0x{len(self.sent):064x}"
        self.states[tx] = self.wait_state
        return tx

    async def wait(self, tx_hash, timeout):
        state = self.states[tx_hash]
        if state == "success":
            self.closed.add(self.sent[-1][0])
        return (state, DEPOSIT * self.sent[-1][1] // QUOTA if state == "success" else None)

    async def tx_state(self, tx_hash):
        return (self.states.get(tx_hash, "unknown"), None)


class _Enforcer(EnforcerService):
    def __init__(self) -> None:
        super().__init__()
        self.disconnected: list[str] = []

    async def disconnect(self, mac_address: str, origin: str = "") -> None:  # type: ignore[override]
        self.disconnected.append(mac_address)


async def _paid_session(store: SessionStore, chain_id: int = 7, mac: str = "aa:bb:cc:dd:ee:01") -> SessionRecord:
    rec = await store.create_session(
        StartSessionRequest(
            guest_wallet_address="0x" + "1" * 40,
            host_wallet_address=HOST,
            mac_address=mac,
            quota_bytes=QUOTA,
            price_per_gb_wei="1",
            nonce=uuid4(),
            guest_signature="0x00",
        ),
        ttl_seconds=3600,
    )
    await store.mark_paid(rec.session_id, chain_session_id=chain_id, tx_hash="0x" + "a" * 64,
                          escrow_amount_wei=DEPOSIT)
    return rec


async def _stop(store: SessionStore, rec: SessionRecord, settings: Settings, ago: float) -> SessionRecord:
    stopped = await store.stop_session(rec.session_id, reason="client_disconnect")
    await store.apply_settlement_fields(stopped.session_id, settings)
    stopped.stopped_at = datetime.now(UTC) - timedelta(seconds=ago)
    return stopped


def _signer_of(sig: str, *, chain_session_id: int, bytes_consumed: int) -> str:
    rh = receipt_hash(chain_id=31337, escrow_address=ESCROW, session_id=chain_session_id,
                      bytes_consumed=bytes_consumed, quota_bytes=QUOTA)
    return Account.recover_message(encode_defunct(primitive=rh), signature=sig)


# --- 1. periodic checkpoints ---------------------------------------------------


async def test_checkpoint_signs_valid_receipt_for_usage_so_far():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await store.increment_usage(rec.session_id, 200_000, 50_000)
    svc = PaymentService(settings, store, _Enforcer())

    assert await svc.checkpoint_once() == 1
    r = await store.get_by_session_id(rec.session_id)
    assert r.checkpoint_bytes == 250_000
    assert r.checkpoint_count == 1
    # The contract would accept it: signed by the host over the escrow's receipt hash.
    assert _signer_of(r.checkpoint_sig, chain_session_id=7, bytes_consumed=250_000) == HOST


async def test_checkpoint_only_when_usage_moved_and_follows_growth():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    svc = PaymentService(settings, store, _Enforcer())
    await store.increment_usage(rec.session_id, 100, 0)
    assert await svc.checkpoint_once() == 1
    assert await svc.checkpoint_once() == 0, "no new usage, no new signature"
    await store.increment_usage(rec.session_id, 400, 0)
    assert await svc.checkpoint_once() == 1
    r = await store.get_by_session_id(rec.session_id)
    assert (r.checkpoint_bytes, r.checkpoint_count) == (500, 2)


async def test_checkpoint_caps_at_quota():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await store.increment_usage(rec.session_id, QUOTA * 3, 0)
    await PaymentService(settings, store, _Enforcer()).checkpoint_once()
    assert (await store.get_by_session_id(rec.session_id)).checkpoint_bytes == QUOTA


async def test_off_chain_sessions_are_not_checkpointed():
    settings, store = _settings(), SessionStore(require_payment=False)
    await store.create_session(
        StartSessionRequest(
            guest_wallet_address="0x" + "1" * 40, host_wallet_address=HOST,
            mac_address="aa:bb:cc:dd:ee:09", quota_bytes=QUOTA, price_per_gb_wei="1",
            nonce=uuid4(), guest_signature="0x00",
        ),
        ttl_seconds=3600,
    )
    assert await PaymentService(settings, store, _Enforcer()).checkpoint_once() == 0


async def test_guest_sees_accrued_cost_but_not_checkpoint_signature():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await store.increment_usage(rec.session_id, QUOTA // 4, 0)
    await PaymentService(settings, store, _Enforcer()).checkpoint_once()
    body = (await store.get_by_session_id(rec.session_id)).to_response().model_dump()
    assert body["accrued_payment_wei"] == str(DEPOSIT // 4)
    assert body["checkpoint_bytes"] == QUOTA // 4
    assert "checkpoint_sig" not in body
    assert body["host_settlement_sig"] is None, "no receipt for the guest while active"


# --- 2. host-driven settlement ---------------------------------------------------


async def test_waits_for_grace_period_before_settling():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=10)
    settler = FakeSettler()
    await PaymentService(settings, store, _Enforcer(), settler).settle_once()
    assert settler.sent == [], "the guest gets SETTLE_GRACE_SECONDS to settle first"


async def test_settles_with_final_receipt_after_grace():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await store.increment_usage(rec.session_id, 300_000, 100_000)
    stopped = await _stop(store, rec, settings, ago=500)
    settler = FakeSettler()
    await PaymentService(settings, store, _Enforcer(), settler).settle_once()

    assert settler.sent == [(7, 400_000, QUOTA, stopped.host_settlement_sig)]
    r = await store.get_by_session_id(rec.session_id)
    assert r.settlement_status == "settled"
    assert r.settlement_tx_hash == f"0x{1:064x}"
    assert r.host_payment_wei == DEPOSIT * 400_000 // QUOTA
    assert r.to_response().settlement_status == "settled"


async def test_guest_already_settled_means_no_host_tx():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=500)
    settler = FakeSettler()
    settler.closed.add(7)
    await PaymentService(settings, store, _Enforcer(), settler).settle_once()
    assert settler.sent == []
    assert (await store.get_by_session_id(rec.session_id)).settlement_status == "closed_by_guest"


async def test_settled_sessions_are_not_touched_again():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=500)
    settler = FakeSettler()
    svc = PaymentService(settings, store, _Enforcer(), settler)
    await svc.settle_once()
    await svc.settle_once()
    assert len(settler.sent) == 1


async def test_rpc_failure_retries_then_gives_up():
    settings, store = _settings(SETTLE_MAX_ATTEMPTS=3), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=500)
    settler = FakeSettler()
    settler.fail_send = ConnectionError("rpc down")
    svc = PaymentService(settings, store, _Enforcer(), settler)
    for _ in range(3):
        await svc.settle_once()
    r = await store.get_by_session_id(rec.session_id)
    assert r.settlement_status is None and r.settlement_attempts == 3
    assert "rpc down" in r.settlement_error

    await svc.settle_once()
    assert (await store.get_by_session_id(rec.session_id)).settlement_status == "failed"


async def test_recovers_after_transient_failure():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=500)
    settler = FakeSettler()
    settler.fail_send = ConnectionError("blip")
    svc = PaymentService(settings, store, _Enforcer(), settler)
    await svc.settle_once()
    settler.fail_send = None
    await svc.settle_once()
    r = await store.get_by_session_id(rec.session_id)
    assert r.settlement_status == "settled" and r.settlement_error is None


async def test_pending_tx_is_not_sent_twice():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=500)
    settler = FakeSettler()
    settler.wait_state = "pending"  # receipt didn't arrive within the timeout
    svc = PaymentService(settings, store, _Enforcer(), settler)
    await svc.settle_once()
    await svc.settle_once()
    assert len(settler.sent) == 1, "must not race a second closeSession against the first"

    settler.states[f"0x{1:064x}"] = "success"  # it mined later
    await svc.settle_once()
    assert (await store.get_by_session_id(rec.session_id)).settlement_status == "settled"


async def test_signs_missing_receipt_before_settling():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    stopped = await store.stop_session(rec.session_id, reason="client_disconnect")
    stopped.stopped_at = datetime.now(UTC) - timedelta(seconds=500)
    assert stopped.host_settlement_sig is None
    settler = FakeSettler()
    await PaymentService(settings, store, _Enforcer(), settler).settle_once()
    assert len(settler.sent) == 1
    assert _signer_of(settler.sent[0][3], chain_session_id=7, bytes_consumed=0) == HOST


async def test_auto_settle_disabled_only_checkpoints():
    settings, store = _settings(), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    await _stop(store, rec, settings, ago=500)
    await PaymentService(settings, store, _Enforcer(), settler=None).settle_once()
    assert (await store.get_by_session_id(rec.session_id)).settlement_status is None


# --- 3. dispute-window guard -------------------------------------------------------


async def test_overdue_session_is_stopped_signed_and_disconnected():
    settings, store = _settings(SESSION_MAX_AGE_SECONDS=3600), SessionStore(require_payment=True)
    rec = await _paid_session(store)
    fresh = await _paid_session(store, chain_id=8, mac="aa:bb:cc:dd:ee:02")
    rec.started_at = datetime.now(UTC) - timedelta(hours=2)
    enforcer = _Enforcer()
    assert await PaymentService(settings, store, enforcer).stop_overdue_sessions() == 1
    r = await store.get_by_session_id(rec.session_id)
    assert r.status == "stopped" and r.host_settlement_sig is not None
    assert enforcer.disconnected == ["aa:bb:cc:dd:ee:01"]
    assert (await store.get_by_session_id(fresh.session_id)).status == "active"


# --- persistence ------------------------------------------------------------------


@pytest.mark.parametrize("with_checkpoint", [True, False])
async def test_new_fields_survive_persistence_round_trip(with_checkpoint):
    store = SessionStore(require_payment=True)
    rec = await _paid_session(store)
    if with_checkpoint:
        await store.record_checkpoint(rec.session_id, bytes_consumed=42, signature="0xabc",
                                      at=datetime.now(UTC))
    await store.update_settlement(rec.session_id, status="settled", tx_hash="0x" + "b" * 64,
                                  host_payment_wei=DEPOSIT, count_attempt=True)
    original = await store.get_by_session_id(rec.session_id)
    restored = SessionRecord.from_persist_dict(original.to_persist_dict())
    assert restored == original
