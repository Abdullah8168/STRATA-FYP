#!/usr/bin/env bash
# Tear down the STRATA guest AP started by setup_ap.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ "${EUID}" -ne 0 ]]; then
  echo "error: teardown_ap.sh must run as root (sudo)" >&2
  exit 1
fi

# Prefer live .env; fall back to generated network.env for iface name.
if [[ -f "${AP_DIR}/.env" ]]; then
  ap_load_env "${AP_DIR}"
elif [[ -f /etc/strata/ap/network.env ]]; then
  # shellcheck disable=SC1091
  source /etc/strata/ap/network.env
  : "${AP_IFACE:=wlan0}"
  : "${WAN_IFACE:=eth0}"
  : "${GENERATED_DIR:=/etc/strata/ap}"
else
  AP_IFACE="${AP_IFACE:-wlan0}"
  WAN_IFACE="${WAN_IFACE:-eth0}"
  GENERATED_DIR="${GENERATED_DIR:-/etc/strata/ap}"
fi

echo "== STRATA AP teardown =="

systemctl disable --now strata-dnsmasq.service 2>/dev/null || true
systemctl disable --now strata-hostapd.service 2>/dev/null || true
rm -f /etc/systemd/system/strata-dnsmasq.service
rm -f /etc/systemd/system/strata-hostapd.service
systemctl daemon-reload

# Best-effort removal of lab NAT rules (ignore if absent).
iptables -t nat -D POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "${AP_IFACE}" -o "${WAN_IFACE}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "${WAN_IFACE}" -o "${AP_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

if [[ -d "/sys/class/net/${AP_IFACE}" ]]; then
  ip addr flush dev "${AP_IFACE}" 2>/dev/null || true
  ip link set "${AP_IFACE}" down 2>/dev/null || true
fi

if command -v nmcli >/dev/null 2>&1; then
  nmcli dev set "${AP_IFACE}" managed yes 2>/dev/null || true
fi

systemctl unmask hostapd 2>/dev/null || true

echo "AP services stopped. Generated configs left in ${GENERATED_DIR:-/etc/strata/ap} (delete manually if desired)."
