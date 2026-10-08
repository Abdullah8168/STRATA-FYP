# STRATA Raspberry Pi Wireless AP (Iteration 1)

This directory is the **version-controlled, reproducible guest Wi-Fi access
point** for a STRATA host. It matches the network layout already assumed by:

| Consumer | Expectation |
|----------|-------------|
| `host_node` `GUEST_IFACE` | default `wlan0` (overridable) |
| `host_node` `WAN_IFACE` | default `eth0` (overridable) |
| Flutter `HostApiConfig.defaultBaseUrl` | `http://192.168.50.1:8080` |
| Firewall integration harness | guest subnet `192.168.50.0/24`, gateway `.1` |

```
                  ┌─────────────────────────────────────────┐
  Internet / ISP  │  Raspberry Pi                           │
       │          │                                         │
       ▼          │   eth0 (WAN_IFACE)                       │
   [ modem ]──────┼──────────────┐                          │
                  │              │                          │
                  │         host_node :8080                 │
                  │         (later iterations)              │
                  │              │                          │
                  │   wlan0 (AP_IFACE)  192.168.50.1/24     │
                  │      hostapd + dnsmasq                  │
                  └──────────────┬──────────────────────────┘
                                 │  SSID: STRATA-…
                                 ▼
                          Guest phones / laptops
                          DHCP 192.168.50.50–200
```

**Iteration 1 scope:** broadcast a STRATA SSID, hand out DHCP leases, let
clients reach the Pi at `192.168.50.1`.  

**Not in this directory (later iterations):** captive-portal auth handshake,
`nftables` admit/deny, WireGuard exit, blockchain listener, Flutter payment.

The Python `host_node` process **does not start hostapd**. Bring the AP up
with these scripts first (or equivalently), then run `strata-host` with
`GUEST_IFACE` equal to `AP_IFACE`.

---

## Prerequisites

| Item | Requirement |
|------|-------------|
| Hardware | Raspberry Pi 3/4/5 (or clone) with a Wi-Fi radio that supports **AP mode** |
| OS | Raspberry Pi OS **Bookworm** (or Debian 12+) recommended |
| Privileges | `sudo` / root for setup, teardown, verify |
| Packages | Installed automatically by `setup_ap.sh`: `hostapd`, `dnsmasq`, `iw`, `rfkill` |
| Uplink | `WAN_IFACE` (default `eth0`) for management / later NAT — not required just to join the SSID |
| Repo | This git checkout on the Pi |

USB Wi-Fi dongles: set `AP_IFACE` to the dongle’s name if it is not `wlan0`.

---

## Configuration (secrets vs committed)

| File | Commit? | Purpose |
|------|---------|---------|
| `env.example` | yes | Documented defaults + placeholder passphrase |
| `.env` | **no** | Local SSID passphrase, country, iface overrides |
| `templates/*.in` | yes | hostapd / dnsmasq templates |
| `scripts/*` | yes | setup / teardown / verify / check |
| `/etc/strata/ap/*` | on Pi only | Generated runtime configs (hostapd.conf mode `600`) |

```bash
cd host_node/ap
cp env.example .env
# edit .env — set WPA_PASSPHRASE (8–63 chars), COUNTRY_CODE, AP_IFACE if needed
```

`setup_ap.sh` **refuses to start** if `WPA_PASSPHRASE=CHANGE_ME_DEV_ONLY`.

Keep `AP_ADDRESS=192.168.50.1` unless you also change Flutter
`--dart-define=HOST_API_URL=...` and `host_node` docs/tests.

Align interfaces with `host_node/.env`:

```dotenv
GUEST_IFACE=wlan0   # == AP_IFACE
WAN_IFACE=eth0      # == WAN_IFACE
```

---

## Installation & start

On the Pi, from the repository root:

```bash
# 1) Offline check (also works on a laptop — no radio required)
just ap-check
# or:  bash host_node/ap/scripts/check_ap.sh

# 2) Local secrets
cp host_node/ap/env.example host_node/ap/.env
nano host_node/ap/.env    # set WPA_PASSPHRASE, COUNTRY_CODE, …

# 3) Bring AP up
just ap-setup
# or:  sudo bash host_node/ap/scripts/setup_ap.sh

# 4) Service-level verify
just ap-verify
# or:  sudo bash host_node/ap/scripts/verify_ap.sh
```

Tear down:

```bash
just ap-teardown
# or:  sudo bash host_node/ap/scripts/teardown_ap.sh
```

### What setup does

1. Validates `.env` and that `AP_IFACE` exists under `/sys/class/net`
2. Installs missing packages via `apt`
3. Stops NetworkManager / `wpa_supplicant` from holding the AP iface
4. Renders configs into `/etc/strata/ap/`
5. Assigns `AP_ADDRESS/AP_PREFIX` on `AP_IFACE`
6. Enables `strata-hostapd.service` + `strata-dnsmasq.service`
7. Optionally enables **lab-only** iptables NAT if `ENABLE_LAB_NAT=true`

---

## Verification checklist

### On the Pi (`just ap-verify`)

- [ ] `/sys/class/net/$AP_IFACE` exists  
- [ ] `ip addr` shows `192.168.50.1` on the AP iface  
- [ ] `strata-hostapd` active  
- [ ] `strata-dnsmasq` active  
- [ ] `iw dev $AP_IFACE info` reports **type AP**

### On a client device (hardware — required for full sign-off)

- [ ] SSID `STRATA-…` visible  
- [ ] Client associates with the passphrase from `.env`  
- [ ] Client receives DHCP address in `192.168.50.50–200`  
- [ ] `ping 192.168.50.1` succeeds  
- [ ] DNS to the Pi works for basic queries (when upstream DNS reachable)  

### After host_node is running (not Iteration 1, smoke only)

- [ ] `curl -s http://192.168.50.1:8080/health` from a client  

---

## Troubleshooting

| Symptom | Likely cause | What to try |
|---------|--------------|-------------|
| `interface 'wlan0' not found` | Wrong name / no Wi-Fi | `ls /sys/class/net`; set `AP_IFACE` |
| `hostapd` fails immediately | Radio busy / no AP mode / country | `journalctl -u strata-hostapd -e`; `iw list \| grep -A5 'Supported interface modes'`; set `COUNTRY_CODE` |
| SSID never appears | hostapd down / rfkill | `rfkill unblock wifi`; `systemctl status strata-hostapd` |
| Client associates but no IP | dnsmasq down / wrong iface | `systemctl status strata-dnsmasq`; confirm `bind-interfaces` iface |
| IP conflict / no traffic | Another router on `192.168.50.0/24` | Change lab topology or temporarily alter subnet **and** Flutter/host defaults together |
| `wlan0` managed by NetworkManager | NM fights hostapd | setup runs `nmcli dev set wlan0 managed no`; re-run setup |
| Permission denied writing `/etc/strata/ap` | Not root | use `sudo` |
| Internet works with lab NAT but breaks after host_node nft | Double NAT / flush ruleset | set `ENABLE_LAB_NAT=false`, teardown, rely on host_node firewall later |

---

## Lab NAT warning

`ENABLE_LAB_NAT=true` adds a simple **iptables** MASQUERADE on `WAN_IFACE` so
clients can browse before the Python host node is running. The production
path uses **nftables** (`strata_host.firewall`) applied by `host_node`. Do
not leave both fighting each other on a demo Pi.

---

## Developer / CI checks (no Pi)

```bash
just ap-check
```

Renders templates with a temporary passphrase, runs `bash -n` on all
scripts, and runs `dnsmasq --test` when the binary exists.
