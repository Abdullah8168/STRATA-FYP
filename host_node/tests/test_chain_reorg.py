"""Phase G — confirmation gating + reorg tests for ChainListener.

We don't need a real chain here — we feed fabricated events into
``_handle_event`` and exercise the pending-event bookkeeping that
``_promote_pending`` and ``drop_reorged`` operate on.
"""

from __future__ import annotations

from types import SimpleNamespace
from uuid import uuid4

import pytest

from strata_host.chain_real import ChainListener
from strata_host.enforcer import EnforcerService
from strata_host.firewall.nft_set import NftSet
from strata_host.models import StartSessionRequest
from strata_host.store import SessionStore

GUEST = "0xAaaAaaaaAaAaaaAAAAaaAAaAaAAaAAaaaaAaAAaA"
HOST = "0xBbBBBBbbBBBbBBbBbbBbBBbBBBBbBBbbbBbbBbBb"
ESCROW = "0xCcCcccccccCCcccCCCCccCCCccCcCCcCccccCCCC"

SESSION_OPENED_ABI = [
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


def _make_listener(confirmations: int) -> tuple[ChainListener, SessionStore, EnforcerService]:
    store = SessionStore(require_payment=True)
    enforcer = EnforcerService(NftSet(force_fake=True))
    listener = ChainListener(
        wss_url="wss://example",
        session_escrow_address=ESCROW,
        host_address=HOST,
        store=store,
        enforcer=enforcer,
        session_escrow_abi=SESSION_OPENED_ABI,
        confirmations=confirmations,
    )
    return listener, store, enforcer


def _event(session_ref: str, *, block: int, log_index: int = 0) -> SimpleNamespace:
    ref_bytes = bytes.fromhex(session_ref.removeprefix("0x"))
    return SimpleNamespace(
        args=SimpleNamespace(
            sessionId=42,
            guest=GUEST,
            host=HOST,
            amount=5 * 10**18,
            sessionRef=ref_bytes,
            openedAt=1234567890,
        ),
        transactionHash=SimpleNamespace(hex=lambda: "0x" + "ab" * 32),
        blockNumber=block,
        logIndex=log_index,
    )


async def _create_pending_session(store: SessionStore) -> str:
    record = await store.create_session(
        StartSessionRequest(
            guest_wallet_address=GUEST,
            host_wallet_address=HOST,
            mac_address="aa:bb:cc:dd:ee:f1",
            quota_bytes=10_000_000,
            guest_signature="0xdead",
            nonce=uuid4(),
            price_per_gb_wei="1000",
        ),
        ttl_seconds=600,
    )
    assert record.status == "pending_payment"
    return record.session_ref


@pytest.mark.asyncio
async def test_event_with_confirmations_stays_pending():
    listener, store, _ = _make_listener(confirmations=3)
    ref = await _create_pending_session(store)

    await listener._handle_event(_event(ref, block=100))

    refreshed = await store.get_by_ref(ref)
    assert refreshed is not None
    assert refreshed.status == "pending_payment"
    assert (100, 0) in listener._pending


@pytest.mark.asyncio
async def test_promote_pending_admits_when_deep_enough():
    listener, store, _ = _make_listener(confirmations=3)
    ref = await _create_pending_session(store)

    await listener._handle_event(_event(ref, block=100))
    # Block tip moves forward but not far enough yet.
    await listener._promote_pending(current_block=101)
    assert (await store.get_by_ref(ref)).status == "pending_payment"

    # Now the event is 3 blocks deep — promote.
    await listener._promote_pending(current_block=103)
    refreshed = await store.get_by_ref(ref)
    assert refreshed is not None
    assert refreshed.status == "active"
    assert (100, 0) not in listener._pending


@pytest.mark.asyncio
async def test_drop_reorged_evicts_pending_event():
    listener, store, _ = _make_listener(confirmations=3)
    ref = await _create_pending_session(store)

    await listener._handle_event(_event(ref, block=200))
    assert (200, 0) in listener._pending

    await listener.drop_reorged({(200, 0)})

    assert (200, 0) not in listener._pending
    refreshed = await store.get_by_ref(ref)
    assert refreshed is not None
    assert refreshed.status == "pending_payment"


@pytest.mark.asyncio
async def test_force_confirm_bypasses_gating_for_reconcile():
    listener, store, _ = _make_listener(confirmations=3)
    ref = await _create_pending_session(store)

    # reconcile() calls _handle_event with force_confirm=True so historical
    # events admit immediately regardless of the confirmations setting.
    await listener._handle_event(_event(ref, block=10), force_confirm=True)
    refreshed = await store.get_by_ref(ref)
    assert refreshed is not None
    assert refreshed.status == "active"


@pytest.mark.asyncio
async def test_block_watcher_promote_path_via_public_hook():
    """Simulate the live watcher: stash → tip advances → promote → admit."""
    listener, store, enforcer = _make_listener(confirmations=3)
    await enforcer.start()
    ref = await _create_pending_session(store)

    await listener._handle_event(_event(ref, block=100))
    assert (await store.get_by_ref(ref)).status == "pending_payment"

    # Mimic _block_watcher calling _promote_pending each tip.
    for tip in (100, 101, 102, 103):
        await listener._promote_pending(current_block=tip)

    refreshed = await store.get_by_ref(ref)
    assert refreshed is not None
    assert refreshed.status == "active"
    assert "aa:bb:cc:dd:ee:f1" in enforcer.current_macs()
    await enforcer.stop()


@pytest.mark.asyncio
async def test_zero_confirmations_admits_immediately():
    listener, store, enforcer = _make_listener(confirmations=0)
    await enforcer.start()
    ref = await _create_pending_session(store)

    authorized = await listener._handle_event(_event(ref, block=50))
    assert authorized is True
    assert (await store.get_by_ref(ref)).status == "active"
    assert "aa:bb:cc:dd:ee:f1" in enforcer.current_macs()
    await enforcer.stop()


@pytest.mark.asyncio
async def test_promote_skips_if_session_already_stopped():
    listener, store, _ = _make_listener(confirmations=3)
    ref = await _create_pending_session(store)
    await listener._handle_event(_event(ref, block=100))

    record = await store.get_by_ref(ref)
    assert record is not None
    await store.stop_session(record.session_id, reason="guest_stopped")

    await listener._promote_pending(current_block=110)
    refreshed = await store.get_by_ref(ref)
    assert refreshed is not None
    assert refreshed.status == "stopped"
    assert (100, 0) not in listener._pending

