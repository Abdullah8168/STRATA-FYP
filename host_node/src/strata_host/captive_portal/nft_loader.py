"""Phase B → Phase F shim.

The nftables ruleset moved out of ``captive_portal/`` into
``strata_host.firewall``. This module re-exports the new public API so
old imports keep working — but emits a one-time DeprecationWarning to
nudge callers to update.
"""

from __future__ import annotations

import warnings

from strata_host.firewall.nft_renderer import (  # noqa: F401  (re-export)
    NftContext,
    render_ruleset,
)

warnings.warn(
    "strata_host.captive_portal.nft_loader is deprecated; import "
    "strata_host.firewall.render_ruleset / NftContext instead. The "
    "nft template was moved in Phase F.",
    DeprecationWarning,
    stacklevel=2,
)


# Backwards-compatible name some Phase B callers used.
def render(settings) -> str:  # type: ignore[no-untyped-def]
    """Legacy alias for ``render_ruleset(settings)``."""
    return render_ruleset(settings)
