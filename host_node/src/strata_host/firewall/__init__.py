"""Phase F — firewall package.

Owns the nftables ruleset template (`strata.nft.j2`) and a thin renderer
that builds the final ruleset string from `Settings`. The captive portal's
old import path lives at `captive_portal/nft_loader.py` and emits a
DeprecationWarning that points here.
"""

from strata_host.firewall.nft_renderer import (
    NftContext,
    render_ruleset,
)
from strata_host.firewall.wireguard import WireGuardManager

__all__ = ["NftContext", "render_ruleset", "WireGuardManager"]
