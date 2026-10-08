"""EIP-191 session-start message + signature verification.

Must stay byte-compatible with Flutter ``strataSessionStartMessageTemplate``
in ``lib/services/wallet_service.dart``.
"""

from __future__ import annotations

from eth_account import Account
from eth_account.messages import encode_defunct

# Keep in lockstep with Flutter:
# STRATA-SESSION-START\nguest:{guest}\nhost:{host}\nmac:{mac}\nquota:{quota}\nnonce:{nonce}
SESSION_START_TEMPLATE = (
    "STRATA-SESSION-START\n"
    "guest:{guest}\n"
    "host:{host}\n"
    "mac:{mac}\n"
    "quota:{quota}\n"
    "nonce:{nonce}"
)


def build_session_start_message(
    *,
    guest_wallet: str,
    host_wallet: str,
    mac_address: str,
    quota_bytes: int,
    nonce: str,
) -> str:
    return SESSION_START_TEMPLATE.format(
        guest=guest_wallet.lower(),
        host=host_wallet.lower(),
        mac=mac_address.lower(),
        quota=str(quota_bytes),
        nonce=str(nonce),
    )


def verify_session_start_signature(
    *,
    guest_wallet: str,
    host_wallet: str,
    mac_address: str,
    quota_bytes: int,
    nonce: str,
    signature_hex: str,
) -> str:
    """Recover the signer and ensure it matches ``guest_wallet``.

    Returns the recovered checksum address (0x-prefixed).
    Raises ``ValueError`` on malformed signatures or address mismatch.
    """
    message = build_session_start_message(
        guest_wallet=guest_wallet,
        host_wallet=host_wallet,
        mac_address=mac_address,
        quota_bytes=quota_bytes,
        nonce=nonce,
    )
    sig = signature_hex.strip()
    if not sig.startswith("0x"):
        sig = "0x" + sig
    try:
        recovered = Account.recover_message(encode_defunct(text=message), signature=sig)
    except Exception as exc:  # noqa: BLE001 — eth_account raises varied types
        raise ValueError(f"signature recovery failed: {type(exc).__name__}") from exc

    if recovered.lower() != guest_wallet.lower():
        raise ValueError(
            f"signer mismatch: expected {guest_wallet.lower()}, got {recovered.lower()}"
        )
    return recovered
