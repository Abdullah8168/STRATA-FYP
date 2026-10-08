# `firewall/` — Phase F

Owns:

- **`strata.nft.j2`** — the single nftables ruleset (Phase B captive
  portal + Phase F hardening + WireGuard-aware NAT). Renders to a
  string ready for `nft -f -`.
- **`nft_renderer.py`** — `render_ruleset(settings | NftContext)` glue
  around the Jinja template.
- **`wireguard.py`** — `WireGuardManager` that brings the wg0 exit
  tunnel up/down. Auto-falls into "fake mode" off-Linux / off-root.
- **`wireguard.conf.j2`** — wg-quick template.
- **`netns.py`** — context-managers used by integration tests
  (`guest_namespace`, `host_lan_target`, `applied_rules`).

Phase B's old import path (`strata_host.captive_portal.nft_loader`) emits
a `DeprecationWarning` pointing here. New code should import from
`strata_host.firewall` directly.

## Quick render check

```bash
python -c "from strata_host.firewall import render_ruleset; print(render_ruleset())"
```

## Layout

```
firewall/
├── __init__.py
├── strata.nft.j2          # Phase B + F ruleset
├── nft_renderer.py
├── wireguard.py
├── wireguard.conf.j2
├── netns.py
└── README.md
```

## What the rules do

| Layer | Rule | Purpose |
|-------|------|---------|
| input | `iif lo accept` | host-internal services |
| input | `ct state invalid drop` | bad/forged packets out of band |
| input | DHCP/DNS/portal/ssh allowlist | services guests need |
| input | `icmp echo limit rate 20/s` | rate-limited ping |
| forward | `ct state invalid drop` | drop bad state pre-fast-path |
| forward | `ct state {established,related} accept` | fast-path return traffic |
| forward | `ip daddr @strata_lan_v4 drop` | LAN isolation (Phase F) |
| forward | per-guest `update @strata_pmac` (upload, by MAC) + `@strata_pdown` (download, by IP) @ 6250 KB/s, before the established fast-path | 50 Mbit/s cap each way |
| forward | `oifname { wan, wg0 } accept` | authed egress, allow either path |
| forward | `iifname wan ct state new drop` | unsolicited inbound (Phase F) |
| postrouting | `oifname wg0 masquerade` (when wg_enabled) | route via VPN |
| postrouting | `oifname wan masquerade` (always) | residential fallback |

## WireGuard rollback

If `WG_ENABLED=true` and the tunnel fails (`wg.bring_up_failed` in logs),
the host node continues serving guests. To restore residential NAT:

1. Set `WG_ENABLED=false` in `.env`
2. Restart the host process
3. Confirm postrouting masquerades on `WAN_IFACE` (see `strata.nft.j2`)

Boot validation rejects `WG_ENABLED=true` without `WG_PEER_PUBLIC_KEY` /
`WG_PEER_ENDPOINT` so a half-configured tunnel cannot silently black-hole
guest traffic.

## Out of scope (post-FYP)

- DNS filtering by domain (suggested next step: dnscrypt-proxy + blocklist).
- VLAN tagging / multi-SSID isolation.
- BPF / XDP-based metering.
- Per-MAC QoS classes (we have one class: 50 Mbit/s).
- IDS/IPS (Snort, Suricata).
- A real exit-node business / multi-tenant exit selection.
