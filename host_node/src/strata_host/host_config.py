"""Host settings the owner changes from the app (Iteration 3, /admin/host).

Two kinds:

* **Listing settings** — display name, price, max guests. Saved to
  ``HOST_CONFIG_PATH`` (JSON) and applied to the running ``Settings`` object
  in place, so ``/host/info``, session pricing and the guest limit change at
  once and survive restarts. ``.env`` is never edited.
* **Wi-Fi name / password** — rewritten in the generated ``hostapd.conf`` and
  in ``ap/.env`` (so a later ``setup_ap.sh`` keeps them), then the hotspot is
  restarted. The password is never stored in ``HOST_CONFIG_PATH`` and never
  returned by the API.

Sharing on/off starts/stops the hotspot. It is deliberately *not* persisted:
a host who switches it off from a phone on that very Wi-Fi loses the way back
in, so a reboot always brings the hotspot back.

Off-Linux / not root the hotspot part runs in fake mode (state kept in
memory) so the API is testable on a laptop.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import Any

from strata_host.config import Settings
from strata_host.logging_setup import get_logger

# API field -> Settings attribute
LISTING_FIELDS: dict[str, str] = {
    "display_name": "HOST_DISPLAY_NAME",
    "price_per_gb_wei": "DEFAULT_PRICE_PER_GB_WEI",
    "price_per_gb": "DEFAULT_PRICE_PER_GB",
    "max_guests": "MAX_GUESTS",
}

# Settings attributes that may be saved/restored (the Wi-Fi password never is).
SAVED_KEYS = frozenset(LISTING_FIELDS.values()) | {"HOST_SSID"}

# Values end up in hostapd.conf and in a bash-sourced .env, so only allow
# characters that are safe in both (no quotes, $, backticks, backslashes,
# newlines, ;, &, <, >).
_SSID_RE = re.compile(r"^[A-Za-z0-9_.\-]([A-Za-z0-9 _.\-]{0,30}[A-Za-z0-9_.\-])?$")
_PASS_RE = re.compile(r"^[A-Za-z0-9 !#%+,\-./:=?@_~^*()\[\]{}|]{8,63}$")
_NAME_RE = re.compile(r"^[^\x00-\x1f\x7f]{1,40}$")

Runner = Callable[[list[str]], subprocess.CompletedProcess]


class HostConfigError(ValueError):
    """Invalid value from the app; message is safe to show the host."""


def validate_listing(changes: dict[str, Any]) -> dict[str, Any]:
    """Return ``{settings_attr: value}`` for the listing fields present."""
    out: dict[str, Any] = {}
    if "display_name" in changes:
        name = str(changes["display_name"]).strip()
        if not _NAME_RE.match(name):
            raise HostConfigError("display_name must be 1-40 printable characters")
        out["HOST_DISPLAY_NAME"] = name
    if "price_per_gb_wei" in changes:
        raw = str(changes["price_per_gb_wei"]).strip()
        if not raw.isdigit() or len(raw) > 40 or int(raw) <= 0:
            raise HostConfigError("price_per_gb_wei must be a positive whole number")
        out["DEFAULT_PRICE_PER_GB_WEI"] = str(int(raw))
    if "price_per_gb" in changes:
        try:
            price = float(changes["price_per_gb"])
        except (TypeError, ValueError):
            raise HostConfigError("price_per_gb must be a number") from None
        if not 0 <= price <= 1_000_000:
            raise HostConfigError("price_per_gb must be between 0 and 1,000,000")
        out["DEFAULT_PRICE_PER_GB"] = price
    if "max_guests" in changes:
        mg = changes["max_guests"]
        if mg is not None:
            if isinstance(mg, bool) or not isinstance(mg, int) or not 1 <= mg <= 200:
                raise HostConfigError("max_guests must be 1-200, or null for no limit")
        out["MAX_GUESTS"] = mg
    return out


def validate_wifi(ssid: str | None, password: str | None) -> None:
    if ssid is not None and not _SSID_RE.match(ssid):
        raise HostConfigError(
            "wifi_name must be 1-32 letters, digits, spaces, '.', '_' or '-' "
            "(no leading/trailing space)"
        )
    if password is not None and not _PASS_RE.match(password):
        raise HostConfigError(
            "wifi_password must be 8-63 characters; quotes, $, backslash and ; are not allowed"
        )


class HostConfigStore:
    """The saved listing overrides (JSON, settings attribute names)."""

    def __init__(self, path: str) -> None:
        self._path = Path(path)
        self._logger = get_logger("host_config")

    def load(self) -> dict[str, Any]:
        try:
            data = json.loads(self._path.read_text())
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as exc:
            self._logger.warning("host_config.load_failed", error=type(exc).__name__)
            return {}
        return {k: v for k, v in data.items() if k in SAVED_KEYS}

    def save(self, values: dict[str, Any]) -> None:
        merged = {**self.load(), **values}
        self._path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(merged, indent=2))
        os.replace(tmp, self._path)


def apply_listing(settings: Settings, values: dict[str, Any]) -> None:
    """Set the values on the shared Settings object (every component that
    holds it sees the change)."""
    for attr, value in values.items():
        setattr(settings, attr, value)


def listing_view(settings: Settings) -> dict[str, Any]:
    return {field: getattr(settings, attr) for field, attr in LISTING_FIELDS.items()}


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=30)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def _set_keys(text: str, values: dict[str, str], *, quote: bool) -> str:
    """Replace ``KEY=...`` lines (appending missing keys)."""
    lines = text.splitlines()
    for key, value in values.items():
        rendered = f"{key}='{value}'" if quote else f"{key}={value}"
        for i, line in enumerate(lines):
            if line.startswith(f"{key}="):
                lines[i] = rendered
                break
        else:
            lines.append(rendered)
    return "\n".join(lines) + "\n"


class Hotspot:
    """The STRATA Wi-Fi (strata-hostapd + strata-dnsmasq from setup_ap.sh)."""

    def __init__(
        self,
        settings: Settings,
        *,
        runner: Runner | None = None,
        force_fake: bool | None = None,
    ) -> None:
        self._settings = settings
        self._run = runner or _default_runner
        self._force_fake = force_fake
        self._fake_enabled = True
        self._logger = get_logger("hotspot")

    def fake_mode(self) -> bool:
        if self._force_fake is not None:
            return self._force_fake
        from strata_host.nft_bootstrap import host_owns_kernel  # local: avoid import cycle

        return not host_owns_kernel()

    def is_enabled(self) -> bool:
        if self.fake_mode():
            return self._fake_enabled
        return self._run(["systemctl", "is-active", "strata-hostapd"]).stdout.strip() == "active"

    def set_enabled(self, enabled: bool) -> None:
        if self.fake_mode():
            self._fake_enabled = enabled
            self._logger.info("hotspot.fake_mode", enabled=enabled)
            return
        # strata-dnsmasq Requires strata-hostapd, so stopping hostapd stops both.
        units = ["strata-hostapd", "strata-dnsmasq"] if enabled else ["strata-hostapd"]
        proc = self._run(["systemctl", "start" if enabled else "stop", *units])
        if proc.returncode != 0:
            raise RuntimeError(f"systemctl failed: {proc.stderr.strip()[:200]}")
        self._logger.info("hotspot.sharing", enabled=enabled)

    def set_wifi(self, ssid: str | None, password: str | None) -> None:
        """Rewrite the hotspot's name/password and restart it. Call
        :func:`validate_wifi` first."""
        conf_values: dict[str, str] = {}
        env_values: dict[str, str] = {}
        if ssid is not None:
            conf_values["ssid"] = ssid
            env_values["SSID"] = ssid
        if password is not None:
            conf_values["wpa_passphrase"] = password
            env_values["WPA_PASSPHRASE"] = password
        if not conf_values:
            return
        if self.fake_mode():
            self._logger.info("hotspot.fake_mode", action="set_wifi", ssid_changed=ssid is not None)
            return

        conf = Path(self._settings.HOSTAPD_CONF_PATH)
        conf.write_text(_set_keys(conf.read_text(), conf_values, quote=False))
        conf.chmod(0o600)
        env = Path(self._settings.AP_ENV_PATH)
        if env.exists():
            env.write_text(_set_keys(env.read_text(), env_values, quote=True))
            env.chmod(0o600)

        if self.is_enabled():
            proc = self._run(["systemctl", "restart", "strata-hostapd", "strata-dnsmasq"])
            if proc.returncode != 0:
                raise RuntimeError(f"hotspot restart failed: {proc.stderr.strip()[:200]}")
        self._logger.info("hotspot.wifi_updated", ssid_changed=ssid is not None,
                          password_changed=password is not None)
