"""GET /host/sessions — earnings fields match SessionEscrow settlement math."""

from __future__ import annotations

from uuid import uuid4

import pytest

from strata_host.models import StartSessionRequest


@pytest.mark.asyncio
async def test_host_sessions_earned_is_proportional(chain_app, chain_client, guest_account):
    store = chain_app.state.store
    guest = guest_account.address
    host = "0x2222222222222222222222222222222222222222"
    mac = "aa:bb:cc:dd:ee:01"
    quota = 1_000_000_000
    payload = StartSessionRequest(
        guest_wallet_address=guest,
        host_wallet_address=host,
        mac_address=mac,
        quota_bytes=quota,
        guest_signature="0x" + ("11" * 65),
        nonce=str(uuid4()),
        price_per_gb_wei="1000000000000000000",
    )
    # Bypass EIP-191 for store-level inject (tests already cover crypto elsewhere).
    record = await store.create_session(payload, ttl_seconds=3600)
    await store.mark_paid(
        record.session_id,
        chain_session_id=7,
        tx_hash="0xabc",
        escrow_amount_wei=10**18,
    )
    # Simulate 50% quota consumed.
    async with store._lock:  # noqa: SLF001
        rec = store._sessions[record.session_id]
        rec.bytes_in = 250_000_000
        rec.bytes_out = 250_000_000

    resp = await chain_client.get("/host/sessions")
    assert resp.status_code == 200
    rows = resp.json()["sessions"]
    assert len(rows) >= 1
    row = next(r for r in rows if r["session_id"] == str(record.session_id))
    assert row["earned_amount_wei"] == str(10**18 // 2)
    assert row["escrow_amount_wei"] == str(10**18)
    assert row["strt_amount_wei"] == str(10**18)
    assert row["mac_address"] == mac
    assert row["status"] == "active"


@pytest.mark.asyncio
async def test_host_sessions_offchain_approx(app, client, guest_account, start_payload):
    started = await client.post("/session/start", json=start_payload)
    assert started.status_code == 200
    sid = started.json()["session_id"]
    store = app.state.store
    async with store._lock:  # noqa: SLF001
        from uuid import UUID

        rec = store._sessions[UUID(sid)]
        # 1 GB used at 0.001 STRT/GB (start_payload price) → approx wei
        rec.bytes_in = 10**9
        rec.bytes_out = 0
        rec.price_per_gb_wei = "1000000000000000000"

    resp = await client.get("/host/sessions")
    assert resp.status_code == 200
    row = next(r for r in resp.json()["sessions"] if r["session_id"] == sid)
    assert row["earned_amount_wei"] == "1000000000000000000"
    assert row["escrow_amount_wei"] is None
