"""WireGuard exit-tunnel helper.

Used by `main.create_app`'s lifespan when `WG_ENABLED=true`. On non-Linux
or non-root environments the manager auto-falls into "fake mode": all
methods log a `wg.fake_mode` line and return without side-effects so the
host node still starts cleanly on a developer laptop.

Subprocess is preferred over pyroute2 so we share the same shell-out
shape as the (Phase B) `nft_set.py` and so the failure modes (`wg-quick
up` exit code, stderr content) are identical to what an operator would
see at the terminal.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from strata_host.config import Settings
from strata_host.logging_setup import get_logger


TEMPLATE_NAME = "wireguard.conf.j2"
DEFAULT_CONFIG_PATH = "/etc/strata/wg0.conf"
DEFAULT_INTERFACE = "wg0"


class WireGuardError(RuntimeError):
    """Raised when a wg-quick / wg subprocess returns non-zero."""


class WireGuardManager:
    def __init__(
        self,
        settings: Settings,
        *,
        config_path: str = DEFAULT_CONFIG_PATH,
        interface: str = DEFAULT_INTERFACE,
        force_fake: bool | None = None,
    ) -> None:
        self._settings = settings
        self._config_path = Path(config_path)
        self._interface = interface
        self._logger = get_logger("wireguard")
        self._force_fake = force_fake

    # --- mode ----------------------------------------------------------------
    def fake_mode(self) -> bool:
        """Returns True when we should NOT actually touch the kernel.

        Triggers:
          - explicit override via the constructor (used by tests)
          - STRATA_WG_FAKE=true env var
          - non-Linux platform (no wireguard kernel module on macOS)
          - missing wg / wg-quick binaries on PATH
          - running as a non-root user (we can't bring up wg0 anyway)
        """
        if self._force_fake is not None:
            return self._force_fake
        env_flag = os.environ.get("STRATA_WG_FAKE", "false").lower() == "true"
        if env_flag:
            return True
        if not sys.platform.startswith("linux"):
            return True
        if shutil.which("wg") is None or shutil.which("wg-quick") is None:
            return True
        try:
            return os.geteuid() != 0
        except AttributeError:
            return True

    # --- keypair -------------------------------------------------------------
    def ensure_keypair(self) -> tuple[str, str]:
        """Read or generate the keypair. Returns ``(private_key, public_key)``.

        The private key is stored at ``settings.WG_PRIVATE_KEY_PATH`` with
        mode 0o600. In fake mode we generate ephemeral keys in /tmp so
        tests don't need root or /etc write access.
        """
        if self.fake_mode():
            self._logger.info("wg.fake_mode", action="ensure_keypair")
            return ("FAKE_PRIVATE_KEY", "FAKE_PUBLIC_KEY")

        priv_path = Path(self._settings.WG_PRIVATE_KEY_PATH)
        priv_path.parent.mkdir(parents=True, exist_ok=True)

        if priv_path.exists():
            private_key = priv_path.read_text().strip()
        else:
            result = subprocess.run(
                ["wg", "genkey"],
                check=True,
                capture_output=True,
                text=True,
            )
            private_key = result.stdout.strip()
            priv_path.write_text(private_key + "\n")
            priv_path.chmod(0o600)

        pub = subprocess.run(
            ["wg", "pubkey"],
            check=True,
            capture_output=True,
            text=True,
            input=private_key,
        )
        public_key = pub.stdout.strip()
        self._logger.info("wg.keypair_loaded", public_key=public_key)
        return private_key, public_key

    # --- config rendering ----------------------------------------------------
    def render_config(self, *, private_key: str | None = None) -> str:
        if private_key is None:
            private_key = self.ensure_keypair()[0]
        template_dir = Path(__file__).parent
        env = Environment(
            loader=FileSystemLoader(str(template_dir)),
            undefined=StrictUndefined,
            keep_trailing_newline=True,
            trim_blocks=True,
            lstrip_blocks=True,
        )
        template = env.get_template(TEMPLATE_NAME)
        return template.render(
            private_key=private_key,
            address=self._settings.WG_ADDRESS,
            listen_port=self._settings.WG_LISTEN_PORT,
            peer_pubkey=self._settings.WG_PEER_PUBLIC_KEY,
            peer_endpoint=self._settings.WG_PEER_ENDPOINT,
            peer_allowed_ips=self._settings.WG_PEER_ALLOWED_IPS,
        )

    # --- lifecycle -----------------------------------------------------------
    def is_up(self) -> bool:
        if self.fake_mode():
            return False
        result = subprocess.run(
            ["wg", "show", self._interface],
            capture_output=True,
            text=True,
        )
        return result.returncode == 0

    def bring_up(self) -> None:
        """Idempotent. Writes the rendered config and runs ``wg-quick up``."""
        if self.fake_mode():
            self._logger.info("wg.fake_mode", action="bring_up")
            return
        if self.is_up():
            self._logger.info("wg.already_up", interface=self._interface)
            return

        private_key, public_key = self.ensure_keypair()
        rendered = self.render_config(private_key=private_key)

        self._config_path.parent.mkdir(parents=True, exist_ok=True)
        self._config_path.write_text(rendered)
        self._config_path.chmod(0o600)

        try:
            subprocess.run(
                ["wg-quick", "up", str(self._config_path)],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            raise WireGuardError(
                f"wg-quick up failed: rc={exc.returncode} stderr={exc.stderr.strip()}"
            ) from exc

        self._logger.info("wg.up", interface=self._interface, public_key=public_key)

    def bring_down(self) -> None:
        if self.fake_mode():
            self._logger.info("wg.fake_mode", action="bring_down")
            return
        if not self.is_up():
            self._logger.info("wg.already_down", interface=self._interface)
            return
        try:
            subprocess.run(
                ["wg-quick", "down", str(self._config_path)],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            # Non-fatal — log but don't raise during shutdown.
            self._logger.warning(
                "wg.bring_down_failed",
                rc=exc.returncode,
                stderr=exc.stderr.strip(),
            )
            return
        self._logger.info("wg.down", interface=self._interface)
