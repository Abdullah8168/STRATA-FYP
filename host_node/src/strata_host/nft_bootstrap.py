"""Apply the rendered STRATA nftables ruleset at process startup."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING

from strata_host.firewall.nft_renderer import NftContext, render_ruleset

if TYPE_CHECKING:
    from strata_host.config import Settings


def verify_nft_environment(logger: object) -> None:
    if shutil.which("nft") is None:
        logger.error("nft.binary_missing")
        return
    mod = Path("/sys/module/nf_tables")
    if not mod.exists():
        logger.error("nft.kernel_module_missing")


def host_owns_kernel() -> bool:
    """True when the host node really manages the kernel (Linux, root, nft
    present, not STRATA_NFT_FAKE) — i.e. NftSet is not in fake mode."""
    nft_set_mod = __import__("strata_host.firewall.nft_set", fromlist=["NftSet"])
    return not nft_set_mod.NftSet().fake_mode()


def apply_strata_ruleset(settings: "Settings", logger: object) -> None:
    if not host_owns_kernel():
        logger.warning("nft.ruleset_skipped_fake_mode")
        return
    rendered = render_ruleset(NftContext.from_settings(settings))
    try:
        subprocess.run(
            ["nft", "-f", "-"],
            input=rendered,
            text=True,
            check=True,
            capture_output=True,
        )
        logger.info("nft.ruleset_applied")
    except subprocess.CalledProcessError as exc:
        logger.warning(
            "nft.ruleset_apply_failed",
            stderr=(exc.stderr or "").strip(),
            returncode=exc.returncode,
        )


# Kernel settings the host node depends on:
#   ip_forward          guests' packets are forwarded, not delivered locally —
#                       without it admitted guests get no internet at all.
#   nf_conntrack_acct   conntrack keeps byte counters per connection; the
#                       meter bills from them and reads 0 when it is off.
KERNEL_PREREQS: dict[str, str] = {
    "net.ipv4.ip_forward": "1",
    "net.netfilter.nf_conntrack_acct": "1",
}


def _sysctl_path(key: str) -> Path:
    return Path("/proc/sys") / key.replace(".", "/")


def enable_kernel_prereqs(logger: object, *, force_fake: bool | None = None) -> dict[str, bool]:
    """Set :data:`KERNEL_PREREQS` and read them back.

    Returns ``{key: ok}``. Skipped (all False) in fake mode, i.e. off-Linux
    or not root, where the host node can't change the kernel anyway.
    """
    if force_fake is None:
        force_fake = not host_owns_kernel()
    if force_fake:
        logger.warning("kernel.prereqs_skipped_fake_mode", keys=list(KERNEL_PREREQS))
        return {k: False for k in KERNEL_PREREQS}

    # nf_conntrack_acct only exists once the conntrack module is loaded.
    # The ruleset's `ct state` rules load it, but be explicit in case the
    # ruleset failed to apply.
    subprocess.run(["modprobe", "nf_conntrack"], capture_output=True, text=True, check=False)

    results: dict[str, bool] = {}
    for key, value in KERNEL_PREREQS.items():
        subprocess.run(
            ["sysctl", "-q", "-w", f"{key}={value}"],
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            actual = _sysctl_path(key).read_text().strip()
        except OSError:
            actual = None
        results[key] = actual == value
        if results[key]:
            logger.info("kernel.prereq_ok", key=key, value=value)
        else:
            logger.error("kernel.prereq_failed", key=key, wanted=value, actual=actual)
    return results


def delete_strata_table(logger: object) -> None:
    if shutil.which("nft") is None:
        return
    subprocess.run(
        ["nft", "delete", "table", "inet", "strata"],
        capture_output=True,
        text=True,
    )
    logger.debug("nft.ruleset_cleanup_attempted")
