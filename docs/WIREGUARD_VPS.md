# WireGuard exit tunnel (Iteration 3)

## What it does

```text
Guest phone ─ wlan0 ─ STRATA Pi ─ wg0 (WireGuard) ─ VPS ─ Internet   (egress IP = VPS)
                          └────── eth0 ─ home router ─ Internet       (the Pi's own traffic only)
```

- **Only guest traffic uses the tunnel.** `wg-quick` runs with `Table = off`,
  and `strata_host.firewall.wg_routing` adds a policy rule for packets
  forwarded from the AP:

  ```text
  ip rule:           10000: from 192.168.50.0/24 iif wlan0 lookup 51820
  table 51820:       192.168.50.0/24 dev wlan0
                     default dev wg0
                     unreachable default metric 4000000000   (kill switch)
  ```

  The Pi's own traffic (SSH, chain RPC, the WireGuard handshake itself) keeps
  using the main table, i.e. `eth0`.
- **Kill switch (default).** If `wg0` goes down, guests hit the
  `unreachable` route and the nftables forward chain only allows guests out of
  `wg0`, so guest traffic is dropped rather than leaking out of the host's
  residential IP. Set `WG_FALLBACK_TO_WAN=true` to let guests use `eth0`
  while the tunnel is down instead.
- **Self-repair.** Every `WG_ROUTE_CHECK_SECONDS` (15 s) the host node checks
  that the tunnel route exists and re-installs it after `wg0` is bounced.
- **MSS clamp** on SYNs into `wg0` (tunnel MTU 1420 < AP MTU 1500).
- **`GET /health`** gains a `wireguard` block: `tunnel_up`, `rule_installed`,
  `tunnel_route_installed`, `kill_switch`, `latest_handshake_age_seconds`.
- On shutdown the rule and table are removed.

Known limit: guests resolve DNS through the Pi's dnsmasq, whose upstream
queries leave via `eth0` (the Pi's IP, not the guest's). Guest IPv4 traffic
is tunnelled; guest IPv6 is blocked by the kill switch, not tunnelled.

## Configuration

`host_node/.env` on the Pi:

```text
WG_ENABLED=true
WG_PRIVATE_KEY_PATH=/etc/strata/wg0.key
WG_LISTEN_PORT=51820
WG_ADDRESS=10.66.66.2/24
WG_PEER_PUBLIC_KEY=<VPS public key>
WG_PEER_ENDPOINT=<VPS public IP>:51820
WG_PEER_ALLOWED_IPS=0.0.0.0/0
GUEST_SUBNET=192.168.50.0/24
WG_FALLBACK_TO_WAN=false
```

Boot refuses `WG_ENABLED=true` without the peer key/endpoint, or with a
`GUEST_SUBNET` that has host bits set.

---

## Manual test

### Test 1 — Pi only, no VPS (≈ 5 min)

Runs the real Linux kernel code in network namespaces. A fake "tunnel" and a
fake "WAN" both serve the same IP; the test checks which one a guest reaches.

```bash
sudo apt install -y nftables iperf3 netcat-openbsd wireguard-tools
cd host_node
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"

# ruleset syntax check (kill switch + fallback variants)
sudo .venv/bin/python -m pytest -q tests/firewall/test_strata_nft_syntax.py

# real routing behaviour
sudo .venv/bin/python -m pytest -v -m integration tests/firewall/integration/test_wg_guest_routing.py
```

Expected: all pass.

| Test | Proves |
|------|--------|
| `test_guest_traffic_exits_via_tunnel_pi_traffic_stays_on_wan` | guest → tunnel; the Pi itself → WAN |
| `test_kill_switch_blocks_guest_when_tunnel_down` | tunnel down → guest blocked, Pi still online |
| `test_fallback_uses_wan_when_tunnel_down` | `WG_FALLBACK_TO_WAN=true` → guest uses WAN |
| `test_ensure_restores_tunnel_route_after_bounce` | tunnel comes back → guests routed again |
| `test_remove_leaves_no_rule_or_table` | clean shutdown |

### Test 2 — real VPS, end to end

**VPS** (any Ubuntu/Debian VPS with a public IP; open UDP 51820 in its cloud firewall):

```bash
sudo apt install -y wireguard
wg genkey | sudo tee /etc/wireguard/vps.key | wg pubkey | sudo tee /etc/wireguard/vps.pub
```

**Pi** — create its key and print the public half:

```bash
sudo mkdir -p /etc/strata
wg genkey | sudo tee /etc/strata/wg0.key >/dev/null && sudo chmod 600 /etc/strata/wg0.key
sudo wg pubkey < /etc/strata/wg0.key
```

**VPS** `/etc/wireguard/wg0.conf` (replace `eth0` with the VPS's internet interface, see `ip route | grep default`):

```ini
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = <contents of /etc/wireguard/vps.key>
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE; iptables -I FORWARD -i wg0 -j ACCEPT; iptables -I FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o eth0 -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

[Peer]
PublicKey = <Pi public key>
AllowedIPs = 10.66.66.2/32
```

```bash
sudo systemctl enable --now wg-quick@wg0
```

**Pi** — set the `.env` values above, then start the host node as root:

```bash
cd host_node && sudo .venv/bin/strata-host
```

Then check, on the Pi (second terminal):

| # | Do | Expect |
|---|----|--------|
| 1 | `sudo wg show wg0` | `latest handshake: N seconds ago` |
| 2 | `ip rule show` | `10000: from 192.168.50.0/24 iif wlan0 lookup 51820` |
| 3 | `ip route show table 51820` | `default dev wg0` and `unreachable default … metric 4000000000` |
| 4 | `curl -s localhost:8080/health` | `"wireguard": {"tunnel_up": true, "rule_installed": true, "tunnel_route_installed": true, "kill_switch": true, …}` |
| 5 | `curl -4 -s https://ifconfig.me` | your **home** IP (the Pi itself is not tunnelled) |

Connect a phone to the STRATA Wi-Fi and admit it. Either pay through the
app, or admit it by hand:

```bash
ip neigh show dev wlan0                 # find the phone's MAC
sudo nft add element inet strata strata_authed '{ aa:bb:cc:dd:ee:ff }'
```

| # | Do | Expect |
|---|----|--------|
| 6 | Phone: open `https://ifconfig.me` | the **VPS** IP |
| 7 | Pi: `sudo wg-quick down /etc/strata/wg0.conf`, phone: reload | page fails to load (kill switch); Pi's `curl ifconfig.me` still works |
| 8 | Pi: `sudo wg-quick up /etc/strata/wg0.conf`, wait ≤ 15 s, phone: reload | VPS IP again; host log shows `wg_routing.repairing` |
| 9 | Stop the host node (Ctrl+C), then `ip rule show` | no `lookup 51820` rule |

Optional: set `WG_FALLBACK_TO_WAN=true`, restart, repeat step 7 — the phone
now shows your **home** IP instead of failing.

## Rollback

`WG_ENABLED=false` → restart host_node → guests use normal `eth0` NAT.

See also `host_node/src/strata_host/firewall/README.md`.
