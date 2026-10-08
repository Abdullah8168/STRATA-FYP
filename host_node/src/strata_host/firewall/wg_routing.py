"""Guest-only policy routing through the WireGuard exit tunnel.

``wg-quick`` runs with ``Table = off`` (see ``wireguard.conf.j2``), so it
installs no routes and the Pi's own traffic keeps using the WAN. This
module steers only packets sourced from ``GUEST_SUBNET`` into a dedicated
routing table whose default route is the tunnel::

    ip rule  add from 192.168.50.0/24 iif wlan0 lookup 51820 priority 10000
    ip route replace 192.168.50.0/24 dev wlan0 table 51820
    ip route replace default dev wg0 table 51820
    ip route replace unreachable default table 51820 metric 4000000000

The ``unreachable`` route is the kill switch: when wg0 disappears its
route goes with it, the lookup lands on ``unreachable`` and guests get an
immediate ICMP error instead of silently leaking out of the WAN. With
``WG_FALLBACK_TO_WAN=true`` it is omitted, the table lookup misses and the
kernel falls through to the main table (WAN egress).

Like ``WireGuardManager`` and ``NftSet``, everything shells out to ``ip`` /
``sysctl`` and drops into fake mode off-Linux or off-root. The command
runner is injectable so the exact commands are unit-testable.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass

from strata_host.config import Settings
from strata_host.logging_setup import get_logger

# Higher than any metric the tunnel route will ever get, so the tunnel
# route always wins while wg0 exists.
KILL_SWITCH_METRIC = 4_000_000_000

Runner = Callable[[list[str]], subprocess.CompletedProcess]


class RoutingError(RuntimeError):
    """Raised when a required ``ip`` command fails."""


def _default_runner(cmd: list[str]) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


@dataclass(frozen=True)
class RoutingStatus:
    mode: str  # "real" | "fake"
    rule_installed: bool
    tunnel_route_installed: bool
    kill_switch: bool
    tunnel_up: bool
    latest_handshake_age_seconds: int | None

    def to_dict(self) -> dict:
        return {
            "mode": self.mode,
            "rule_installed": self.rule_installed,
            "tunnel_route_installed": self.tunnel_route_installed,
            "kill_switch": self.kill_switch,
            "tunnel_up": self.tunnel_up,
            "latest_handshake_age_seconds": self.latest_handshake_age_seconds,
        }


class GuestRouting:
    def __init__(
        self,
        settings: Settings,
        *,
        wg_iface: str = "wg0",
        runner: Runner | None = None,
        force_fake: bool | None = None,
    ) -> None:
        self._settings = settings
        self._wg_iface = wg_iface
        self._run = runner or _default_runner
        self._force_fake = force_fake
        self._logger = get_logger("wg_routing")

    @property
    def _table(self) -> str:
        return str(self._settings.WG_ROUTE_TABLE)

    @property
    def _priority(self) -> str:
        return str(self._settings.WG_RULE_PRIORITY)

    @property
    def _subnet(self) -> str:
        return self._settings.GUEST_SUBNET

    @property
    def _rule_selector(self) -> list[str]:
        # ``iif`` limits the rule to packets forwarded from the AP. Traffic
        # the Pi originates itself from 192.168.50.1 (portal replies, mDNS)
        # has iif lo and keeps using the normal tables.
        return [
            "from", self._subnet, "iif", self._settings.GUEST_IFACE,
            "lookup", self._table,
        ]

    # --- mode ----------------------------------------------------------------
    def fake_mode(self) -> bool:
        if self._force_fake is not None:
            return self._force_fake
        if os.environ.get("STRATA_WG_FAKE", "false").lower() == "true":
            return True
        if not sys.platform.startswith("linux"):
            return True
        if shutil.which("ip") is None:
            return True
        try:
            return os.geteuid() != 0
        except AttributeError:
            return True

    # --- helpers -------------------------------------------------------------
    def _must(self, cmd: list[str]) -> None:
        proc = self._run(cmd)
        if proc.returncode != 0:
            raise RoutingError(
                f"{' '.join(cmd)} failed: rc={proc.returncode} "
                f"stderr={(proc.stderr or '').strip()}"
            )

    def _iface_exists(self) -> bool:
        return self._run(["ip", "link", "show", "dev", self._wg_iface]).returncode == 0

    def _rule_installed(self) -> bool:
        proc = self._run(["ip", "rule", "show", "priority", self._priority])
        if proc.returncode != 0:
            return False
        return " ".join(self._rule_selector) in (proc.stdout or "")

    def _tunnel_route_installed(self) -> bool:
        proc = self._run(["ip", "route", "show", "table", self._table])
        if proc.returncode != 0:
            return False
        return any(
            line.startswith("default dev " + self._wg_iface)
            for line in (proc.stdout or "").splitlines()
        )

    def _latest_handshake_age(self) -> int | None:
        proc = self._run(["wg", "show", self._wg_iface, "latest-handshakes"])
        if proc.returncode != 0:
            return None
        newest = 0
        for line in (proc.stdout or "").splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                newest = max(newest, int(parts[1]))
        if newest == 0:
            return None  # peer configured but never handshaked
        return max(0, int(time.time()) - newest)

    # --- lifecycle -----------------------------------------------------------
    def apply(self) -> None:
        """Install (or refresh) guest routing. Idempotent."""
        if self.fake_mode():
            self._logger.info("wg_routing.fake_mode", action="apply")
            return

        # Guests are forwarded, so forwarding must be on. rp_filter=2 (loose)
        # on wg0 because replies arrive on wg0 while the main table would
        # route their source out of the WAN.
        self._must(["sysctl", "-q", "-w", "net.ipv4.ip_forward=1"])

        # Guest-to-guest and guest-to-Pi stay on the AP; without this route
        # the guest table would send them into the tunnel.
        self._must([
            "ip", "route", "replace", self._subnet,
            "dev", self._settings.GUEST_IFACE, "table", self._table,
        ])

        tunnel_up = self._iface_exists()
        if tunnel_up:
            self._run(["sysctl", "-q", "-w", f"net.ipv4.conf.{self._wg_iface}.rp_filter=2"])
            self._must([
                "ip", "route", "replace", "default",
                "dev", self._wg_iface, "table", self._table,
            ])

        if self._settings.WG_FALLBACK_TO_WAN:
            # Make sure a kill-switch route from a previous run isn't left
            # behind, otherwise fallback would never happen.
            self._run([
                "ip", "route", "del", "unreachable", "default",
                "table", self._table, "metric", str(KILL_SWITCH_METRIC),
            ])
        else:
            self._must([
                "ip", "route", "replace", "unreachable", "default",
                "table", self._table, "metric", str(KILL_SWITCH_METRIC),
            ])

        if not self._rule_installed():
            self._must(
                ["ip", "rule", "add", *self._rule_selector, "priority", self._priority]
            )

        self._logger.info(
            "wg_routing.applied",
            subnet=self._subnet,
            table=self._table,
            tunnel_up=tunnel_up,
            kill_switch=not self._settings.WG_FALLBACK_TO_WAN,
        )
        if not tunnel_up:
            self._logger.warning(
                "wg_routing.tunnel_missing",
                interface=self._wg_iface,
                guests="blocked" if not self._settings.WG_FALLBACK_TO_WAN else "via_wan",
            )

    def ensure(self) -> bool:
        """Re-apply if the tunnel is up but its route went missing.

        ``wg-quick down`` + ``up`` outside the host node deletes wg0 and
        with it our table route. Returns True when a repair happened.
        """
        if self.fake_mode():
            return False
        if self._iface_exists() and not (self._tunnel_route_installed() and self._rule_installed()):
            self._logger.info("wg_routing.repairing")
            self.apply()
            return True
        return False

    def remove(self) -> None:
        """Remove the guest rule and flush the guest table. Never raises."""
        if self.fake_mode():
            self._logger.info("wg_routing.fake_mode", action="remove")
            return
        # A crash mid-apply could leave duplicates; delete until none remain.
        for _ in range(10):
            proc = self._run(
                ["ip", "rule", "del", *self._rule_selector, "priority", self._priority]
            )
            if proc.returncode != 0:
                break
        self._run(["ip", "route", "flush", "table", self._table])
        self._logger.info("wg_routing.removed", table=self._table)

    def status(self) -> RoutingStatus:
        kill_switch = not self._settings.WG_FALLBACK_TO_WAN
        if self.fake_mode():
            return RoutingStatus("fake", False, False, kill_switch, False, None)
        return RoutingStatus(
            mode="real",
            rule_installed=self._rule_installed(),
            tunnel_route_installed=self._tunnel_route_installed(),
            kill_switch=kill_switch,
            tunnel_up=self._iface_exists(),
            latest_handshake_age_seconds=self._latest_handshake_age(),
        )
