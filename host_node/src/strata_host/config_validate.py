"""Fail-fast validation for Iteration 3 configuration.

Broken combinations (e.g. ``CHAIN_ENABLED=true`` without escrow addresses)
must raise before the app accepts sessions into ``pending_payment`` with no
listener that can ever authorize them.
"""

from __future__ import annotations

import ipaddress

from eth_account import Account

from strata_host.config import Settings


class ConfigurationError(RuntimeError):
    """Raised when settings are inconsistent for the requested mode."""


def validate_settings(settings: Settings) -> None:
    """Raise :class:`ConfigurationError` with an actionable message, or return."""
    errors: list[str] = []

    if settings.CHAIN_ENABLED:
        if not settings.SESSION_ESCROW_ADDRESS:
            errors.append(
                "CHAIN_ENABLED=true requires SESSION_ESCROW_ADDRESS "
                "(deploy contracts and set the escrow address)."
            )
        if not settings.HOST_WALLET_ADDRESS:
            errors.append(
                "CHAIN_ENABLED=true requires HOST_WALLET_ADDRESS "
                "(the host EOA that appears in SessionOpened.host)."
            )
        if not settings.STRATA_TOKEN_ADDRESS:
            errors.append(
                "CHAIN_ENABLED=true requires STRATA_TOKEN_ADDRESS "
                "(needed for Flutter approve + host documentation)."
            )
        if not settings.chain_rpc_url():
            errors.append(
                "CHAIN_ENABLED=true requires CHAIN_RPC_URL or AMOY_WSS_URL "
                "(WebSocket for Amoy, or http://127.0.0.1:8545 for Hardhat)."
            )
        if not settings.HOST_SIGNING_PRIVATE_KEY:
            errors.append(
                "CHAIN_ENABLED=true requires HOST_SIGNING_PRIVATE_KEY "
                "(EIP-191 key for closeSession receipts; must match HOST_WALLET_ADDRESS)."
            )
        elif settings.HOST_WALLET_ADDRESS and settings.HOST_SIGNING_PRIVATE_KEY:
            try:
                key = settings.HOST_SIGNING_PRIVATE_KEY.strip()
                if key.startswith("0x"):
                    key = key[2:]
                derived = Account.from_key(key).address
                expected = settings.HOST_WALLET_ADDRESS
                if derived.lower() != expected.lower():
                    errors.append(
                        f"HOST_SIGNING_PRIVATE_KEY derives {derived} but "
                        f"HOST_WALLET_ADDRESS is {expected} — they must match."
                    )
            except Exception as exc:  # noqa: BLE001
                errors.append(
                    f"HOST_SIGNING_PRIVATE_KEY is invalid: {type(exc).__name__}"
                )

    if settings.WG_ENABLED:
        if not (settings.WG_PEER_PUBLIC_KEY or "").strip():
            errors.append(
                "WG_ENABLED=true requires WG_PEER_PUBLIC_KEY "
                "(VPS WireGuard peer public key)."
            )
        if not (settings.WG_PEER_ENDPOINT or "").strip():
            errors.append(
                "WG_ENABLED=true requires WG_PEER_ENDPOINT "
                "(e.g. vps.example.com:51820)."
            )
        # Strict: `ip rule` prints the canonical network, and wg_routing
        # compares against it to stay idempotent.
        try:
            ipaddress.IPv4Network(settings.GUEST_SUBNET, strict=True)
        except ValueError:
            errors.append(
                f"GUEST_SUBNET={settings.GUEST_SUBNET!r} must be an IPv4 network "
                "address with no host bits set (e.g. 192.168.50.0/24)."
            )

    if errors:
        joined = "\n  - ".join(errors)
        raise ConfigurationError(
            "Invalid STRATA host configuration:\n  - "
            + joined
            + "\nFix host_node/.env (see .env.example) or set CHAIN_ENABLED=false / "
            "WG_ENABLED=false for Iteration 2 off-chain demos."
        )
