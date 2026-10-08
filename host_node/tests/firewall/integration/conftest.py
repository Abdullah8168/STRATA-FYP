"""Integration-test fixtures.

Auto-skips the whole subdirectory unless we're on Linux, running as root,
and have nft + iperf3 + ip on the path. CI runs ``pytest -q -m "not
integration"`` by default; the integration suite is opt-in via
``sudo pytest -q -m integration host_node/tests/firewall/integration``.
"""

from __future__ import annotations

import os
import shutil
import sys

import pytest


REQUIRED_TOOLS = ("nft", "ip", "iperf3")


def _missing_tools() -> list[str]:
    return [t for t in REQUIRED_TOOLS if shutil.which(t) is None]


def pytest_collection_modifyitems(config, items):
    """Mark everything in this directory as @integration AND auto-skip
    when the environment can't possibly satisfy it."""
    skip_reason = None
    if not sys.platform.startswith("linux"):
        skip_reason = "integration tests require Linux (need netns + nft kernel modules)"
    elif hasattr(os, "geteuid") and os.geteuid() != 0:
        skip_reason = "integration tests require root (need to manage netns / nft tables)"
    else:
        missing = _missing_tools()
        if missing:
            skip_reason = f"missing required tools on PATH: {', '.join(missing)}"

    skip_marker = pytest.mark.skip(reason=skip_reason) if skip_reason else None
    integration_marker = pytest.mark.integration
    for item in items:
        # All tests under this directory get the integration marker.
        if "firewall/integration" in str(item.fspath) or "firewall\\integration" in str(item.fspath):
            item.add_marker(integration_marker)
            if skip_marker is not None:
                item.add_marker(skip_marker)


@pytest.fixture(scope="session")
def authed_mac() -> str:
    """A MAC the integration tests place into strata_authed."""
    return "aa:bb:cc:dd:ee:01"
