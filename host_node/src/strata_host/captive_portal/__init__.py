"""Deprecated — see ``strata_host.firewall``.

The Phase B captive-portal package is in the process of being split: the
nftables ruleset moved to ``strata_host.firewall``. The portal-specific
HTTP routes (Phase B Python web layer) will eventually live here once
that work lands. For now this package only re-exports the firewall
renderer behind a `DeprecationWarning` so any code still pointed at the
old path keeps working.
"""

import warnings

warnings.warn(
    "strata_host.captive_portal.* is deprecated; the nftables template "
    "and renderer moved to strata_host.firewall in Phase F. Update your "
    "imports.",
    DeprecationWarning,
    stacklevel=2,
)
