"""Iteration 2 — signature verification + host info + portal client."""

from uuid import uuid4

import pytest
from eth_account import Account
from eth_account.messages import encode_defunct

from strata_host.session_crypto import (
    build_session_start_message,
    verify_session_start_signature,
)


def test_verify_session_start_roundtrip():
    acct = Account.create()
    nonce = str(uuid4())
    msg = build_session_start_message(
        guest_wallet=acct.address,
        host_wallet="0x2222222222222222222222222222222222222222",
        mac_address="aa:bb:cc:dd:ee:ff",
        quota_bytes=1_000,
        nonce=nonce,
    )
    signed = acct.sign_message(encode_defunct(text=msg))
    sig = signed.signature.hex()
    if not sig.startswith("0x"):
        sig = "0x" + sig
    recovered = verify_session_start_signature(
        guest_wallet=acct.address,
        host_wallet="0x2222222222222222222222222222222222222222",
        mac_address="aa:bb:cc:dd:ee:ff",
        quota_bytes=1_000,
        nonce=nonce,
        signature_hex=sig,
    )
    assert recovered.lower() == acct.address.lower()


def test_verify_rejects_wrong_signer():
    acct = Account.create()
    other = Account.create()
    nonce = str(uuid4())
    msg = build_session_start_message(
        guest_wallet=acct.address,
        host_wallet="0x2222222222222222222222222222222222222222",
        mac_address="aa:bb:cc:dd:ee:ff",
        quota_bytes=1_000,
        nonce=nonce,
    )
    # Sign as `other` but claim guest is `acct`.
    signed = other.sign_message(encode_defunct(text=msg))
    sig = signed.signature.hex()
    if not sig.startswith("0x"):
        sig = "0x" + sig
    with pytest.raises(ValueError, match="signer mismatch"):
        verify_session_start_signature(
            guest_wallet=acct.address,
            host_wallet="0x2222222222222222222222222222222222222222",
            mac_address="aa:bb:cc:dd:ee:ff",
            quota_bytes=1_000,
            nonce=nonce,
            signature_hex=sig,
        )


async def test_start_rejects_bad_signature(client, start_payload):
    bad = {**start_payload, "guest_signature": "0x" + ("ab" * 65)}
    response = await client.post("/session/start", json=bad)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "INVALID_SIGNATURE"


async def test_host_info(client, test_settings):
    response = await client.get("/host/info")
    assert response.status_code == 200
    body = response.json()
    assert body["ssid"] == test_settings.HOST_SSID
    assert body["demo_mode"] is True
    assert body["wallet_address"].lower() == test_settings.HOST_WALLET_ADDRESS.lower()


async def test_portal_client(client):
    response = await client.get("/portal/client")
    assert response.status_code == 200
    body = response.json()
    assert "mac_source" in body
    assert body["guest_iface"]


async def test_portal_handshake(client, start_payload):
    response = await client.post("/portal/handshake", json=start_payload)
    assert response.status_code == 200
    body = response.json()
    assert body["handshake"] == "ok"
    assert body["status"] == "active"
    assert body["mac_address"] == "aa:bb:cc:dd:ee:ff"


async def test_start_rejects_wrong_host_wallet(client, start_payload, guest_account):
    from eth_account.messages import encode_defunct

    from strata_host.session_crypto import build_session_start_message

    wrong = {**start_payload}
    wrong["host_wallet_address"] = "0x9999999999999999999999999999999999999999"
    msg = build_session_start_message(
        guest_wallet=wrong["guest_wallet_address"],
        host_wallet=wrong["host_wallet_address"],
        mac_address=wrong["mac_address"],
        quota_bytes=wrong["quota_bytes"],
        nonce=wrong["nonce"],
    )
    signed = guest_account.sign_message(encode_defunct(text=msg))
    sig = signed.signature.hex()
    wrong["guest_signature"] = sig if sig.startswith("0x") else "0x" + sig
    response = await client.post("/session/start", json=wrong)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "HOST_WALLET_MISMATCH"
