"""Fast syntax check for the rendered ruleset.

If `nft` is on the path (any platform that has it — most Linux distros,
Pi OS, also `brew install nftables` on macOS for the parser binary), we
pipe the rendered ruleset through `nft -c -f -` (check-only) and assert
exit 0. Otherwise the test skips with a clear message.

This catches stupid template typos without needing root or netns.
"""

from __future__ import annotations

import os
import shutil
import subprocess

import pytest

from strata_host.firewall import NftContext, render_ruleset


pytestmark = [
    pytest.mark.skipif(
        shutil.which("nft") is None,
        reason="nft binary not installed; install nftables to run this test",
    ),
    # `nft -c` validates against the kernel over netlink, which needs
    # CAP_NET_ADMIN: as a normal user it fails with "Operation not permitted".
    pytest.mark.skipif(
        hasattr(os, "geteuid") and os.geteuid() != 0,
        reason="nft -c needs root; run: sudo .venv/bin/python -m pytest tests/firewall/test_strata_nft_syntax.py",
    ),
]


def _check(rendered: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["nft", "-c", "-f", "-"],
        input=rendered,
        text=True,
        capture_output=True,
    )


def test_render_passes_nft_check_no_wg():
    out = render_ruleset(NftContext(wg_enabled=False))
    proc = _check(out)
    assert proc.returncode == 0, (
        f"nft -c rejected the ruleset:\nstderr={proc.stderr}\n--- rendered ---\n{out}"
    )


@pytest.mark.parametrize("fallback", [False, True], ids=["kill_switch", "fallback"])
def test_render_passes_nft_check_with_wg(fallback):
    out = render_ruleset(NftContext(wg_enabled=True, wg_fallback_to_wan=fallback))
    proc = _check(out)
    assert proc.returncode == 0, (
        f"nft -c rejected the ruleset:\nstderr={proc.stderr}\n--- rendered ---\n{out}"
    )
