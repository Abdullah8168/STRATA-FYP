"""Phase G — Seam 4 single-owner discipline.

The strata_authed nftables set has exactly one owner: ``EnforcerService``.
This test fails (and CI goes red) the moment any other module reaches into
``firewall/nft_set.py`` directly.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "src" / "strata_host"
ALLOWED_OWNERS = {"enforcer.py"}
PATTERN = re.compile(r"from\s+strata_host\.firewall\.nft_set\b|import\s+strata_host\.firewall\.nft_set\b")


def test_only_enforcer_imports_nft_set():
    offenders: list[Path] = []
    for py in ROOT.rglob("*.py"):
        if py.name in ALLOWED_OWNERS:
            continue
        # Allow nft_set.py itself.
        if py.name == "nft_set.py" and py.parent.name == "firewall":
            continue
        text = py.read_text()
        if PATTERN.search(text):
            offenders.append(py)
    assert not offenders, (
        "Direct imports of strata_host.firewall.nft_set found outside "
        f"EnforcerService: {[str(p) for p in offenders]}. Route through "
        "EnforcerService.admit/disconnect instead."
    )
