"""Phase G — mDNS service advertisement for the host node.

Advertises ``_strata._tcp.local.`` so a Flutter client on the same LAN can
find this Pi without a hardcoded URL. The TXT record carries the host's
on-chain wallet address and the SessionEscrow contract so the client can
prove it's talking to the right host before signing anything.

Off-Linux/Windows we still try to bind because zeroconf works fine on
macOS too. The ``MDNS_ENABLED`` flag lets operators turn this off in
shared-LAN scenarios where the discovery noise is unwelcome.
"""

from __future__ import annotations

import socket
import subprocess
from typing import TYPE_CHECKING

from strata_host.logging_setup import get_logger

if TYPE_CHECKING:
    from zeroconf.asyncio import AsyncServiceInfo, AsyncZeroconf

    from strata_host.config import Settings


def _get_iface_ipv4(iface: str) -> str | None:
    """IPv4 address of ``iface`` (e.g. the guest AP ``wlan0``), or None.

    Guests must be pointed at the Pi's address on *their* network; the
    default-route address below is the WAN side, which guests can't use.
    """
    try:
        out = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "dev", iface],
            capture_output=True, text=True, check=False, timeout=5,
        ).stdout
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        parts = line.split()
        if "inet" in parts:
            return parts[parts.index("inet") + 1].split("/")[0]
    return None


def _get_local_ipv4() -> str:
    """Best-effort detection of the LAN-facing IPv4 address.

    Trick: open a UDP socket pointed at a public IP, ask the kernel which
    local interface it would route through, then close. No traffic is
    actually sent.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 53))
        ip = s.getsockname()[0]
    except OSError:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


class DiscoveryAdvertiser:
    """Advertises the host node over mDNS."""

    def __init__(self, settings: "Settings") -> None:
        self._settings = settings
        self._logger = get_logger("discovery")
        self._zc: "AsyncZeroconf | None" = None
        self._info: "AsyncServiceInfo | None" = None

    async def start(self) -> None:
        if not self._settings.MDNS_ENABLED:
            self._logger.info("discovery.disabled")
            return
        # Local import — zeroconf is heavy and we only want it loaded when
        # actually advertising.
        from zeroconf import IPVersion
        from zeroconf.asyncio import AsyncServiceInfo, AsyncZeroconf

        host_wallet = (self._settings.HOST_WALLET_ADDRESS or "").lower()
        last6 = host_wallet[-6:] if host_wallet else "anon00"
        instance_name = f"strata-{last6}"
        full_name = f"{instance_name}.{self._settings.MDNS_SERVICE_TYPE}"

        ip = _get_iface_ipv4(self._settings.GUEST_IFACE) or _get_local_ipv4()
        properties = {
            "version": self._settings.SERVICE_VERSION.encode(),
            "chain_id": str(self._settings.CHAIN_ID).encode(),
            "host_wallet": host_wallet.encode(),
            "contracts_session_escrow": (
                self._settings.SESSION_ESCROW_ADDRESS or ""
            ).encode(),
            "contracts_strata_token": (
                self._settings.STRATA_TOKEN_ADDRESS or ""
            ).encode(),
            "demo_mode": str(self._settings.DEMO_MODE).lower().encode(),
        }

        self._info = AsyncServiceInfo(
            type_=self._settings.MDNS_SERVICE_TYPE,
            name=full_name,
            addresses=[socket.inet_aton(ip)],
            port=self._settings.PORT,
            properties=properties,
            server=f"{instance_name}.local.",
        )
        self._zc = AsyncZeroconf(ip_version=IPVersion.V4Only)
        try:
            await self._zc.async_register_service(self._info)
        except Exception as exc:  # noqa: BLE001
            self._logger.warning(
                "discovery.register_failed", error=type(exc).__name__
            )
            await self._teardown_zc()
            return
        self._logger.info(
            "discovery.advertised", name=full_name, ip=ip, port=self._settings.PORT
        )

    async def stop(self) -> None:
        if self._zc is None:
            return
        try:
            if self._info is not None:
                await self._zc.async_unregister_service(self._info)
        except Exception as exc:  # noqa: BLE001
            self._logger.warning(
                "discovery.unregister_failed", error=type(exc).__name__
            )
        await self._teardown_zc()
        self._logger.info("discovery.stopped")

    async def _teardown_zc(self) -> None:
        if self._zc is None:
            return
        try:
            await self._zc.async_close()
        except Exception:  # noqa: BLE001
            pass
        self._zc = None
        self._info = None
