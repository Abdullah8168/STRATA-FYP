"""Settlement EIP-191 receipt signing tests (Iteration 3)."""

from __future__ import annotations

import pytest
from eth_account import Account
from eth_account.messages import encode_defunct

from strata_host.config import Settings
from strata_host.settlement import maybe_sign_stop, receipt_hash, sign_settlement

ESCROW = "0x1111111111111111111111111111111111111111"


@pytest.fixture
def host_account():
    return Account.create()


def test_sign_settlement_recovers_host(host_account):
    rh, sig = sign_settlement(
        private_key_hex=host_account.key.hex(),
        chain_id=80002,
        escrow_address=ESCROW,
        session_id=7,
        bytes_consumed=1_000_000,
        quota_bytes=10_000_000,
    )
    assert rh.startswith("0x")
    assert sig.startswith("0x")
    expected = receipt_hash(
        chain_id=80002,
        escrow_address=ESCROW,
        session_id=7,
        bytes_consumed=1_000_000,
        quota_bytes=10_000_000,
    )
    assert rh == "0x" + expected.hex()
    recovered = Account.recover_message(encode_defunct(primitive=expected), signature=sig)
    assert recovered.lower() == host_account.address.lower()


def test_maybe_sign_stop_returns_none_when_chain_off(host_account):
    settings = Settings(
        CHAIN_ENABLED=False,
        SESSION_ESCROW_ADDRESS=ESCROW,
        HOST_SIGNING_PRIVATE_KEY=host_account.key.hex(),
        CHAIN_ID=80002,
    )
    assert maybe_sign_stop(
        settings, chain_session_id=1, bytes_used=100, quota_bytes=1000
    ) == (None, None, None, None)


def test_maybe_sign_stop_caps_bytes_at_quota(host_account):
    settings = Settings(
        CHAIN_ENABLED=True,
        SESSION_ESCROW_ADDRESS=ESCROW,
        HOST_SIGNING_PRIVATE_KEY=host_account.key.hex(),
        CHAIN_ID=80002,
    )
    rh, sig, sb, sq = maybe_sign_stop(
        settings, chain_session_id=3, bytes_used=99_999_999, quota_bytes=5_000
    )
    assert rh is not None and sig is not None
    assert sb == 5_000
    assert sq == 5_000


def test_invalid_signature_does_not_recover_host(host_account):
    rh, sig = sign_settlement(
        private_key_hex=host_account.key.hex(),
        chain_id=80002,
        escrow_address=ESCROW,
        session_id=1,
        bytes_consumed=100,
        quota_bytes=1000,
    )
    # Tamper usage — recovered address for wrong hash must not match when
    # verifying the original receipt hash against a sig for different bytes.
    other = receipt_hash(
        chain_id=80002,
        escrow_address=ESCROW,
        session_id=1,
        bytes_consumed=200,
        quota_bytes=1000,
    )
    recovered = Account.recover_message(encode_defunct(primitive=other), signature=sig)
    assert recovered.lower() != host_account.address.lower()
    # Original still verifies
    original = bytes.fromhex(rh[2:])
    assert Account.recover_message(
        encode_defunct(primitive=original), signature=sig
    ).lower() == host_account.address.lower()
