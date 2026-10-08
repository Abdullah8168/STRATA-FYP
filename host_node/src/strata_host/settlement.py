"""Host EIP-191 settlement signatures for ``SessionEscrow.closeSession``."""

from __future__ import annotations

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3

from strata_host.config import Settings

RECEIPT_DOMAIN = "STRATA-SESSION-RECEIPT-V1"
_MAX_U128 = (1 << 128) - 1


def _u128(n: int) -> int:
    return max(0, min(int(n), _MAX_U128))


def receipt_hash(
    *,
    chain_id: int,
    escrow_address: str,
    session_id: int,
    bytes_consumed: int,
    quota_bytes: int,
) -> bytes:
    escrow_cs = Web3.to_checksum_address(escrow_address)
    packed = abi_encode(
        ["string", "uint256", "address", "uint256", "uint128", "uint128"],
        [
            RECEIPT_DOMAIN,
            chain_id,
            escrow_cs,
            session_id,
            _u128(bytes_consumed),
            _u128(quota_bytes),
        ],
    )
    return Web3.keccak(packed)


def sign_settlement(
    *,
    private_key_hex: str,
    chain_id: int,
    escrow_address: str,
    session_id: int,
    bytes_consumed: int,
    quota_bytes: int,
) -> tuple[str, str]:
    """Return ``(receipt_hash_0x, signature_0x)`` for JSON responses."""
    key = private_key_hex.strip()
    if key.startswith("0x"):
        key = key[2:]
    rh = receipt_hash(
        chain_id=chain_id,
        escrow_address=escrow_address,
        session_id=session_id,
        bytes_consumed=bytes_consumed,
        quota_bytes=quota_bytes,
    )
    acct = Account.from_key(key)
    msg = encode_defunct(primitive=rh)
    signed = acct.sign_message(msg)
    sig_hex = "0x" + signed.signature.hex()
    return ("0x" + rh.hex(), sig_hex)


def maybe_sign_stop(
    settings: Settings,
    *,
    chain_session_id: int | None,
    bytes_used: int,
    quota_bytes: int,
) -> tuple[str | None, str | None, int | None, int | None]:
    """If configured, build settlement fields for a stopped session."""
    if (
        chain_session_id is None
        or not settings.CHAIN_ENABLED
        or not settings.SESSION_ESCROW_ADDRESS
        or not settings.HOST_SIGNING_PRIVATE_KEY
    ):
        return (None, None, None, None)
    cap = _u128(min(max(0, bytes_used), max(1, quota_bytes)))
    q = _u128(max(1, quota_bytes))
    try:
        rh, sig = sign_settlement(
            private_key_hex=settings.HOST_SIGNING_PRIVATE_KEY,
            chain_id=settings.CHAIN_ID,
            escrow_address=settings.SESSION_ESCROW_ADDRESS,
            session_id=int(chain_session_id),
            bytes_consumed=int(cap),
            quota_bytes=int(q),
        )
        return (rh, sig, int(cap), int(q))
    except Exception:  # noqa: BLE001
        return (None, None, None, None)
