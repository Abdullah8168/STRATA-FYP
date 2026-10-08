"""Render the STRATA nftables ruleset from a `Settings` instance.

The template is the only source of truth for the firewall rules. This
module is the thin glue that turns a `Settings` object into a string you
can pipe into `nft -f -` (or `nft -c -f -` to syntax-check).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from strata_host.config import Settings

TEMPLATE_DIR = Path(__file__).parent
TEMPLATE_NAME = "strata.nft.j2"


@dataclass(frozen=True)
class NftContext:
    """Subset of `Settings` the template actually consumes.

    Kept as a dataclass so tests can build one without instantiating the
    full pydantic Settings object (which reads .env and the environment).
    """

    guest_iface: str = "wlan0"
    wan_iface: str = "eth0"
    wg_iface: str = "wg0"
    portal_port: int = 8080
    ssh_port: int = 22
    wg_enabled: bool = False
    # Only meaningful when wg_enabled: False = kill switch (guests may only
    # leave through the tunnel), True = guests may also use the WAN.
    wg_fallback_to_wan: bool = False

    @classmethod
    def from_settings(cls, settings: Settings) -> "NftContext":
        return cls(
            guest_iface=settings.GUEST_IFACE,
            wan_iface=settings.WAN_IFACE,
            wg_iface="wg0",
            portal_port=settings.PORTAL_PORT,
            ssh_port=settings.SSH_PORT,
            wg_enabled=settings.WG_ENABLED,
            wg_fallback_to_wan=settings.WG_FALLBACK_TO_WAN,
        )

    @property
    def guest_wan_egress(self) -> bool:
        """True when authed guests may leave through the WAN interface."""
        return not self.wg_enabled or self.wg_fallback_to_wan

    def guest_egress_ifaces(self) -> str:
        """nft anonymous set of interfaces authed guests may be forwarded to."""
        ifaces: list[str] = []
        if self.guest_wan_egress:
            ifaces.append(self.wan_iface)
        if self.wg_enabled:
            ifaces.append(self.wg_iface)
        return "{ " + ", ".join(f'"{i}"' for i in ifaces) + " }"

    def to_dict(self) -> dict:
        return {
            "guest_iface": self.guest_iface,
            "wan_iface": self.wan_iface,
            "wg_iface": self.wg_iface,
            "portal_port": self.portal_port,
            "ssh_port": self.ssh_port,
            "wg_enabled": self.wg_enabled,
            "guest_wan_egress": self.guest_wan_egress,
            "guest_egress_ifaces": self.guest_egress_ifaces(),
        }


def _env() -> Environment:
    return Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )


def render_ruleset(ctx: NftContext | Settings | None = None) -> str:
    """Render `strata.nft.j2` to a string ready for `nft -f -`.

    Accepts either a `NftContext` (most flexibility) or a `Settings`
    instance (typical production path). When called with `None`,
    pulls the cached `get_settings()`.
    """
    if ctx is None:
        from strata_host.config import get_settings  # local import to avoid cycles

        ctx = NftContext.from_settings(get_settings())
    elif isinstance(ctx, Settings):
        ctx = NftContext.from_settings(ctx)

    env = _env()
    template = env.get_template(TEMPLATE_NAME)
    return template.render(**ctx.to_dict())
