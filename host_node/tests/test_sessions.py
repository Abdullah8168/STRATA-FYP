import asyncio
from uuid import uuid4

from eth_account.messages import encode_defunct

from strata_host.session_crypto import build_session_start_message


def _resign(account, payload: dict, *, mac: str | None = None, nonce: str | None = None) -> dict:
    """Copy payload with a fresh EIP-191 signature for the given mac/nonce."""
    out = {**payload}
    if mac is not None:
        out["mac_address"] = mac
    if nonce is not None:
        out["nonce"] = nonce
    msg = build_session_start_message(
        guest_wallet=out["guest_wallet_address"],
        host_wallet=out["host_wallet_address"],
        mac_address=out["mac_address"],
        quota_bytes=out["quota_bytes"],
        nonce=out["nonce"],
    )
    signed = account.sign_message(encode_defunct(text=msg))
    sig = signed.signature.hex()
    out["guest_signature"] = sig if sig.startswith("0x") else "0x" + sig
    return out


async def test_start_session_returns_active(client, start_payload):
    response = await client.post("/session/start", json=start_payload)
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "active"
    assert payload["mac_address"] == "aa:bb:cc:dd:ee:ff"
    assert payload["bytes_used"] == 0
    # Phase E — session_ref is always present on the response.
    assert payload["session_ref"].startswith("0x")
    assert len(payload["session_ref"]) == 66


async def test_start_session_chain_enabled_is_pending_payment(chain_client, start_payload):
    response = await chain_client.post("/session/start", json=start_payload)
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "pending_payment"
    # MAC is not yet "active" — meter shouldn't count bytes.
    by_mac = await chain_client.get("/session/status?mac_address=aa:bb:cc:dd:ee:ff")
    assert by_mac.status_code == 200
    assert by_mac.json()["bytes_used"] == 0


async def test_start_same_mac_conflict(client, start_payload, guest_account):
    first = await client.post("/session/start", json=start_payload)
    assert first.status_code == 200
    second_payload = _resign(
        guest_account, start_payload, nonce=str(uuid4())
    )
    second = await client.post("/session/start", json=second_payload)
    assert second.status_code == 409
    body = second.json()
    assert body["error"]["code"] == "MAC_ALREADY_ACTIVE"


async def test_nonce_replay_conflict(client, start_payload, guest_account):
    first = await client.post("/session/start", json=start_payload)
    assert first.status_code == 200
    replay_payload = _resign(
        guest_account, start_payload, mac="aa:bb:cc:dd:ee:01"
    )
    replay = await client.post("/session/start", json=replay_payload)
    assert replay.status_code == 409
    assert replay.json()["error"]["code"] == "NONCE_REPLAY"



async def test_status_query_by_session_id_and_mac(client, start_payload):
    started = await client.post("/session/start", json=start_payload)
    sid = started.json()["session_id"]

    by_id = await client.get(f"/session/status?session_id={sid}")
    assert by_id.status_code == 200
    assert by_id.json()["session_id"] == sid

    by_mac = await client.get("/session/status?mac_address=aa:bb:cc:dd:ee:ff")
    assert by_mac.status_code == 200
    assert by_mac.json()["mac_address"] == "aa:bb:cc:dd:ee:ff"


async def test_status_missing_query(client):
    response = await client.get("/session/status")
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "MISSING_QUERY"


async def test_stop_session_transitions_to_stopped(client, start_payload):
    started = await client.post("/session/start", json=start_payload)
    sid = started.json()["session_id"]
    response = await client.post(
        "/session/stop",
        json={"session_id": sid, "reason": "host_stop"},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "stopped"


async def test_meter_loop_increments_bytes(client, start_payload):
    started = await client.post("/session/start", json=start_payload)
    sid = started.json()["session_id"]

    await asyncio.sleep(0.15)
    status = await client.get(f"/session/status?session_id={sid}")
    assert status.status_code == 200
    assert status.json()["bytes_used"] > 0


async def test_meter_loop_skips_pending_payment(chain_client, start_payload):
    started = await chain_client.post("/session/start", json=start_payload)
    sid = started.json()["session_id"]

    await asyncio.sleep(0.2)
    status = await chain_client.get(f"/session/status?session_id={sid}")
    assert status.status_code == 200
    body = status.json()
    assert body["status"] == "pending_payment"
    # CHAIN_ENABLED + no listener → MAC never gets admitted, so meter
    # never sees this session.
    assert body["bytes_used"] == 0


async def test_meter_loop_stops_at_quota(client, start_payload, guest_account):
    tiny = _resign(
        guest_account,
        {**start_payload, "quota_bytes": 500},
        nonce=str(uuid4()),
    )
    started = await client.post("/session/start", json=tiny)
    assert started.status_code == 200
    sid = started.json()["session_id"]

    await asyncio.sleep(0.15)
    status = await client.get(f"/session/status?session_id={sid}")
    assert status.status_code == 200
    assert status.json()["status"] == "stopped"


async def test_payment_hint_does_not_promote(chain_client, start_payload):
    """POST /session/{id}/payment must not flip status — only the on-chain
    event does that."""
    started = await chain_client.post("/session/start", json=start_payload)
    sid = started.json()["session_id"]

    fake_tx = "0x" + "ab" * 32
    response = await chain_client.post(
        f"/session/{sid}/payment",
        json={"tx_hash": fake_tx},
    )
    assert response.status_code == 202
    body = response.json()
    assert body["status"] == "pending_payment"
    assert body["tx_hash"] == fake_tx

    status = await chain_client.get(f"/session/status?session_id={sid}")
    assert status.json()["status"] == "pending_payment"
    assert status.json()["tx_hash"] == fake_tx


async def test_payment_hint_unknown_session(client):
    fake_tx = "0x" + "ab" * 32
    response = await client.post(
        f"/session/{uuid4()}/payment",
        json={"tx_hash": fake_tx},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "SESSION_NOT_FOUND"


async def test_payment_hint_rejects_bad_tx(chain_client, start_payload):
    started = await chain_client.post("/session/start", json=start_payload)
    sid = started.json()["session_id"]
    response = await chain_client.post(
        f"/session/{sid}/payment",
        json={"tx_hash": "not-a-tx"},
    )
    assert response.status_code == 422
