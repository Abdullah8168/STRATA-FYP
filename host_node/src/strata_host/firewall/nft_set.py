"""nftables `strata_authed` set mutations — Phase G single-owner edition.

DO NOT IMPORT outside ``strata_host.enforcer`` (see CONTRIBUTING.md and the
test ``test_no_direct_nft_imports``). Every admit/disconnect path in the
codebase must go through ``EnforcerService`` so the captive portal, the
chain listener, the metering loop, and the admin API never race each
other on set membership.

The class binds itself to a single asyncio event loop on construction.
Calling its async methods from any other loop raises ``LoopMismatchError``
loudly so the test suite (and grumpy reviewers) catch a misuse before it
becomes a flaky-in-prod bug.

Off-Linux / off-root, the set is in ``fake_mode`` — methods log and return
without invoking ``nft``. This is what makes the host node startable on a
developer laptop.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import subprocess
import sys
from typing import Iterable

from strata_host.logging_setup import get_logger

TABLE = "inet strata"
SET_NAME = "strata_authed"


class LoopMismatchError(RuntimeError):
    """Raised when NftSet is touched from a different asyncio loop than the
    one it bound to at startup. Indicates a non-EnforcerService caller."""


class NftSetError(RuntimeError):
    """Raised when an `nft` subprocess returns non-zero in non-fake mode."""


class NftSet:
    def __init__(
        self,
        *,
        table: str = TABLE,
        set_name: str = SET_NAME,
        force_fake: bool | None = None,
    ) -> None:
        self._table = table
        self._set_name = set_name
        self._force_fake = force_fake
        self._logger = get_logger("nft_set")
        # Bind to the loop that constructed us — usually FastAPI's lifespan
        # loop. Any cross-loop call asserts loudly.
        try:
            self._owning_loop: asyncio.AbstractEventLoop | None = (
                asyncio.get_running_loop()
            )
        except RuntimeError:
            # Constructed outside an event loop (e.g. unit tests). The
            # binding takes effect on the first async call.
            self._owning_loop = None

    # --- mode ------------------------------------------------------------
    def fake_mode(self) -> bool:
        if self._force_fake is not None:
            return self._force_fake
        if os.environ.get("STRATA_NFT_FAKE", "false").lower() == "true":
            return True
        if not sys.platform.startswith("linux"):
            return True
        if shutil.which("nft") is None:
            return True
        try:
            return os.geteuid() != 0
        except AttributeError:
            return True

    # --- guarded ops -----------------------------------------------------
    def _check_loop(self) -> None:
        running = asyncio.get_running_loop()
        if self._owning_loop is None:
            self._owning_loop = running
            return
        if running is not self._owning_loop:
            raise LoopMismatchError(
                "NftSet was bound to a different event loop. Mutations must "
                "run inside the FastAPI app's lifespan loop. Route them "
                "through EnforcerService instead of touching NftSet "
                "directly."
            )

    async def add(self, mac_address: str) -> None:
        self._check_loop()
        if self.fake_mode():
            self._logger.info(
                "nft.fake_mode", action="add", mac=mac_address
            )
            return
        await asyncio.to_thread(
            self._run,
            ["nft", "add", "element", *self._table.split(),
             self._set_name, "{ " + mac_address + " }"],
        )

    async def remove(self, mac_address: str) -> None:
        self._check_loop()
        if self.fake_mode():
            self._logger.info(
                "nft.fake_mode", action="remove", mac=mac_address
            )
            return
        await asyncio.to_thread(
            self._run,
            ["nft", "delete", "element", *self._table.split(),
             self._set_name, "{ " + mac_address + " }"],
        )

    async def list(self) -> list[str]:
        """Returns the current MAC contents of strata_authed.

        Used by /admin/firewall/state. In fake mode returns whatever the
        EnforcerService thinks should be there (it tracks its own copy)."""
        self._check_loop()
        if self.fake_mode():
            return []
        proc = await asyncio.to_thread(
            self._run_capture,
            ["nft", "-j", "list", "set", *self._table.split(), self._set_name],
        )
        return self._parse_macs(proc.stdout)

    # --- internals -------------------------------------------------------
    @staticmethod
    def _run(cmd: Iterable[str]) -> None:
        result = subprocess.run(list(cmd), capture_output=True, text=True)
        if result.returncode != 0:
            raise NftSetError(
                f"nft {cmd} failed rc={result.returncode}: {result.stderr.strip()}"
            )

    @staticmethod
    def _run_capture(cmd: Iterable[str]) -> subprocess.CompletedProcess:
        return subprocess.run(list(cmd), capture_output=True, text=True, check=True)

    @staticmethod
    def _parse_macs(json_blob: str) -> list[str]:
        import json as _json

        try:
            data = _json.loads(json_blob)
        except _json.JSONDecodeError:
            return []
        out: list[str] = []
        for stanza in data.get("nftables", []):
            elem = stanza.get("set", {}).get("elem")
            if not elem:
                continue
            for entry in elem:
                if isinstance(entry, str):
                    out.append(entry)
                elif isinstance(entry, dict):
                    val = entry.get("elem", {}).get("val")
                    if isinstance(val, str):
                        out.append(val)
        return out
