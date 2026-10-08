"""Tests for the Phase E ChainListener.

We don't spin up a real Polygon Amoy websocket here — we exercise
``_handle_event`` directly with fabricated event payloads. The web3
serialization side is covered separately by the contracts/ Hardhat test
suite (which round-trips real events through the real ABI).
"""

from types import SimpleNamespace
from uuid import uuid4

import pytest

from strata_host.chain_real import ChainListener
from strata_host.enforcer import EnforcerService
from strata_host.models import StartSessionRequest
from strata_host.store import SessionStore, session_id_to_ref


GUEST = "0xAaaAaaaaAaAaaaAAAAaaAAaAaAAaAAaaaaAaAAaA"
HOST = "0xBbBBBBbbBBBbBBbBbbBbBBbBBBBbBBbbbBbbBbBb"
ESCROW = "0xCcCcccccccCCcccCCCCccCCCccCcCCcCccccCCCC"


def _make_listener() -> tuple[ChainListener, SessionStore, EnforcerService]:
    store = SessionStore(require_payment=True)
    enforcer = EnforcerService()
    listener = ChainListener(
        wss_url="wss://example",
        session_escrow_address=ESCROW,
        host_address=HOST,
        store=store,
        enforcer=enforcer,
        # Use only the SessionOpened ABI fragment — keeps the test free
        # of a contracts/ build dependency.
        session_escrow_abi=[
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
        ],
    )
    return listener, store, enforcer


def _fake_event(session_ref_hex: str, guest: str, chain_session_id: int = 1) -> SimpleNamespace:
    ref_bytes = bytes.fromhex(session_ref_hex.removeprefix("0x"))
    return SimpleNamespace(
        args=SimpleNamespace(
            sessionId=chain_session_id,
            guest=guest,
            host=HOST,
            amount=5 * 10**18,
            sessionRef=ref_bytes,
            openedAt=1234567890,
        ),
        transactionHash=SimpleNamespace(hex=lambda: "0x" + "ab" * 32),
    )


@pytest.mark.asyncio
async def test_handle_event_admits_and_marks_paid():
    listener, store, _ = _make_listener()
    record = await store.create_session(
        StartSessionRequest(
            guest_wallet_address=GUEST,
            host_wallet_address=HOST,
            mac_address="aa:bb:cc:dd:ee:01",
            quota_bytes=10_000_000,
            guest_signature="0xdead",
            nonce=uuid4(),
            price_per_gb_wei="1000",
        ),
        ttl_seconds=600,
    )
    assert record.status == "pending_payment"

    event = _fake_event(record.session_ref, GUEST)
    await listener._handle_event(event)

    refreshed = await store.get_by_session_id(record.session_id)
    assert refreshed is not None
    assert refreshed.status == "active"
    assert refreshed.tx_hash is not None
    assert refreshed.chain_session_id == 1


@pytest.mark.asyncio
async def test_handle_event_drops_unknown_ref():
    listener, store, _ = _make_listener()
    event = _fake_event(session_id_to_ref(uuid4()), GUEST)
    # Should not raise, just log + return.
    await listener._handle_event(event)
    assert await store.list_active_sessions() == []


@pytest.mark.asyncio
async def test_handle_event_drops_guest_mismatch():
    listener, store, _ = _make_listener()
    record = await store.create_session(
        StartSessionRequest(
            guest_wallet_address=GUEST,
            host_wallet_address=HOST,
            mac_address="aa:bb:cc:dd:ee:02",
            quota_bytes=10_000_000,
            guest_signature="0xdead",
            nonce=uuid4(),
            price_per_gb_wei="1000",
        ),
        ttl_seconds=600,
    )
    other_guest = "0x9999999999999999999999999999999999999999"
    event = _fake_event(record.session_ref, other_guest)

    await listener._handle_event(event)
    refreshed = await store.get_by_session_id(record.session_id)
    assert refreshed is not None
    assert refreshed.status == "pending_payment"  # unchanged


@pytest.mark.asyncio
async def test_handle_event_idempotent_on_already_active():
    listener, store, _ = _make_listener()
    record = await store.create_session(
        StartSessionRequest(
            guest_wallet_address=GUEST,
            host_wallet_address=HOST,
            mac_address="aa:bb:cc:dd:ee:03",
            quota_bytes=10_000_000,
            guest_signature="0xdead",
            nonce=uuid4(),
            price_per_gb_wei="1000",
        ),
        ttl_seconds=600,
    )
    event = _fake_event(record.session_ref, GUEST)
    await listener._handle_event(event)
    await listener._handle_event(event)  # duplicate — should noop

    refreshed = await store.get_by_session_id(record.session_id)
    assert refreshed is not None
    assert refreshed.status == "active"


@pytest.mark.asyncio
async def test_session_id_to_ref_round_trip():
    sid = uuid4()
    ref = session_id_to_ref(sid)
    assert ref.startswith("0x")
    assert len(ref) == 66

    store = SessionStore(require_payment=True)
    record = await store.create_session(
        StartSessionRequest(
            guest_wallet_address=GUEST,
            host_wallet_address=HOST,
            mac_address="aa:bb:cc:dd:ee:04",
            quota_bytes=10_000_000,
            guest_signature="0xdead",
            nonce=uuid4(),
            price_per_gb_wei="1000",
        ),
        ttl_seconds=600,
    )
    looked_up = await store.get_by_ref(record.session_ref)
    assert looked_up is not None
    assert looked_up.session_id == record.session_id


@pytest.mark.asyncio
async def test_listener_start_stop_clean():
    """`start` only spawns the loop task — we cancel before any websocket
    work happens to confirm shutdown is clean."""
    listener, _, _ = _make_listener()
    await listener.start()
    # Don't actually connect — just stop immediately.
    await listener.stop()
    assert listener._task is None
