#!/usr/bin/env bash
# Render AP config templates into a directory (no root required).
# Usage:
#   ./render_config.sh [output_dir]
#
# Default output: ./generated  under host_node/ap (gitignored)
# Does not start services. Safe to run on macOS/CI for Iteration 1 checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

AP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${1:-${AP_DIR}/generated}"

ap_load_env "${AP_DIR}"
ap_require_passphrase

mkdir -p "${OUT_DIR}"
ap_render_file "${AP_DIR}/templates/hostapd.conf.in" "${OUT_DIR}/hostapd.conf"
ap_render_file "${AP_DIR}/templates/dnsmasq.conf.in" "${OUT_DIR}/dnsmasq.conf"

# Sanity: no placeholders left (would mean a missing env var mapping).
if grep -E '__[A-Z0-9_]+__' "${OUT_DIR}/hostapd.conf" "${OUT_DIR}/dnsmasq.conf" >/dev/null 2>&1; then
  echo "error: unresolved placeholders remain in rendered configs" >&2
  grep -nE '__[A-Z0-9_]+__' "${OUT_DIR}/hostapd.conf" "${OUT_DIR}/dnsmasq.conf" >&2 || true
  exit 1
fi

# Confirm passphrase did not leak into dnsmasq (it shouldn't).
if grep -F "${WPA_PASSPHRASE}" "${OUT_DIR}/dnsmasq.conf" >/dev/null 2>&1; then
  echo "error: passphrase unexpectedly present in dnsmasq.conf" >&2
  exit 1
fi

echo "rendered:"
echo "  ${OUT_DIR}/hostapd.conf  (mode 600)"
echo "  ${OUT_DIR}/dnsmasq.conf"
echo "  iface=${AP_IFACE}  ssid=${SSID}  gateway=${AP_ADDRESS}/${AP_PREFIX}"
echo "(passphrase omitted from log)"
