"""Integration: usage metering from real conntrack counters (Iteration 3).

A guest downloads files of known size through the Pi; the TrafficReader
must report that many bytes, and must keep them after the connections are
gone from the conntrack table (the old reader dropped them).

Run on Linux as root:
    sudo .venv/bin/python -m pytest -v -m integration tests/firewall/integration/test_conntrack_metering.py
"""

from __future__ import annotations

import os
import shutil

import pytest

from strata_host.nft_bootstrap import enable_kernel_prereqs
from strata_host.traffic import TrafficReader

from ._topology import TARGET, fetch, sh
from .test_guest_firewall import GUEST_IP, guest_network

BLOB = os.urandom(3 * 1024 * 1024)  # 3 MiB


class _Log:
    def info(self, *a, **k): ...
    def warning(self, *a, **k): ...
    def error(self, event, **k):
        raise AssertionError(f"{event}: {k}")


@pytest.mark.integration
@pytest.mark.skipif(shutil.which("conntrack") is None, reason="apt install conntrack")
def test_reader_counts_real_download_bytes_and_keeps_them(authed_mac):
    enable_kernel_prereqs(_Log(), force_fake=False)  # ip_forward + nf_conntrack_acct

    reader = TrafficReader("vstrata0")
    with guest_network(authed_mac, internet_files={"blob": BLOB}) as ns:
        assert fetch(ns) == "INTERNET"  # also puts the guest in the Pi's neighbour table
        reader.refresh(force=True)
        base_in, base_out = reader.absolute_pair(authed_mac)

        for _ in range(2):
            assert fetch(ns, TARGET, "/blob", size_only=True) == str(len(BLOB))
        reader.refresh(force=True)
        got_in, got_out = reader.absolute_pair(authed_mac)
        downloaded = got_in - base_in
        assert 2 * len(BLOB) <= downloaded <= 2 * len(BLOB) * 1.05, (
            f"metered {downloaded} bytes for a {2 * len(BLOB)}-byte download"
        )
        assert 0 < got_out - base_out < len(BLOB) // 10, "upload should be small (requests/ACKs)"

        # The connections expire from conntrack (here: deleted); usage must stay.
        sh("conntrack", "-D", "-s", GUEST_IP, check=False)
        reader.refresh(force=True)
        assert reader.absolute_pair(authed_mac) == (got_in, got_out), (
            "metered usage dropped when connections left the conntrack table"
        )
