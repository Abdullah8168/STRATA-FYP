# STRATA

**Decentralized Peer-to-Peer Bandwidth Exchange Platform**  
**Final Year Project — Scope Document (Implementation-Aligned Revision)**

| Field | Value |
|-------|--------|
| **Project Team** | Abdul Rehman **22I-0785** · Laila Tariq **22I-1574** |
| **Session** | 2022–2026 |
| **Supervised by** | Mr. Shehreyar Rashid |
| **Department** | Computer Science |
| **Institution** | National University of Computer and Emerging Sciences, Islamabad, Pakistan |
| **Document version** | **3.0** (aligned with STRATA repository implementation) |
| **Date** | February 2026 |

---

## Summary of Revisions (v3.0)

This revision replaces over-ambitious wording in `FYP1-ScopeDocument-S26-056-D-STRATA.pdf` with a scope that matches the **actual STRATA codebase** (`host_node`, Flutter app, `contracts/`). It is a research/prototype FYP contract—not a production network product.

| Change | Detail |
|--------|--------|
| Payment model | **SessionEscrow** lock → meter → EIP-191 receipt → `closeSession` settle. **Not** L2 streaming channels. |
| Metering | Measured in **bytes** (`quota_bytes` / `bytes_used`); UI may display GB. Quota exhaustion disconnects the guest. |
| Firewall | **nftables** only: isolation, captive redirect, rate limit, NAT, authenticated MAC set. No IPS/IDS. |
| SOS | Always-available **LAN WebSocket chatroom**; no disaster auto-detection. |
| Discovery | Authoritative FYP path: **mDNS + captive-portal pin** (+ `/host/info`). SSID scan is auxiliary UI only. |
| DNS filtering | **Out of scope** (not implemented; DNS port allowed for guests). |
| Staking | **Out of scope** (no staking contracts). |
| May–Aug 2026 | Neutral calendar note—**no fabricated iteration** invented for that gap. |
| Ownership | Single primary owner per feature (§2.5 + feature matrix). |
| New sections | Success criteria, risks, ethics, testing, BoM, iteration DoD, topology, APIs, feature matrix, glossary, bibliography. |

---

# Contents

1. Introduction  
 1.1 Problem Statement · 1.2 Motivation · 1.3 Problem Solution · 1.4 Stakeholders  
2. Project Description  
 2.1 Project Scope · 2.2 Modules · 2.3 Key Technical Features · 2.4 Tools and Technologies  
 2.5 Work Division · 2.6 Timeline · 2.7 Success Criteria · 2.8 Risk Analysis  
 2.9 Ethics, Privacy, and Legal · 2.10 Testing Strategy · 2.11 Requirements (BoM)  
 2.12 Per-Iteration Deliverables · 2.13 Demo Topology · 2.14 API / Interface Contracts  
 2.15 Feature → Module → Owner → Iteration Matrix  
Appendix A: Glossary · Appendix B: Bibliography  
Change Report · Remaining Issues  

---

# Chapter 1 — Introduction

The purpose of this project is to design and develop **STRATA**, a decentralized physical infrastructure (DePIN) **research prototype** for peer-to-peer Wi‑Fi bandwidth exchange. Individuals can share surplus connectivity with nearby guests through a mobile guest client and a software host on commodity hardware (for the FYP: **Raspberry Pi**).

STRATA is **software-first**: it does not require proprietary radio hardware. Settlement uses an on-chain **SessionEscrow** contract on an Ethereum-compatible testnet (**Polygon Amoy**), not continuous L2 micropayment channels. Guest egress may optionally traverse a **WireGuard** tunnel to a team-operated VPS so the public exit IP is not the host’s residential address.

This FYP integrates Linux networking (**hostapd**, **nftables**), a Python host service (**FastAPI**), a Flutter guest app, Solidity contracts (**Hardhat**), and optional WireGuard. The prototype is validated in a small lab / multi-Pi testbed—not as a commercial ISP product.

## 1.1 Problem Statement

Current connectivity models are inefficient and inconvenient for many users:

- **Underused fixed broadband.** Home and small-business links often carry spare capacity that connection owners cannot easily share in a controlled, accountable way.
- **Expensive or insecure alternatives for travelers.** Roaming data is costly; open public Wi‑Fi is often untrusted and awkward to join.
- **Authentication friction.** Password sharing and untrusted captive portals create poor UX and phishing risk.
- **High hardware barriers in some DePIN Wi‑Fi approaches.** Networks that require specialized radios raise adoption cost for students and small hosts.

**FYP problem (testable):** In a controlled environment, there is no complete open prototype that combines (a) Pi-based guest Wi‑Fi with captive onboarding, (b) cryptographic guest identity, (c) escrow-based settlement for metered sessions, (d) firewall admission control, and (e) optional privacy-preserving egress—without proprietary host hardware.

Unsupported industry-wide idle-bandwidth percentages are **not** used as formal claims in this document.

## 1.2 Motivation

1. Demonstrate that **idle capacity** can be shared under explicit session and payment rules.  
2. Serve travelers/students who need **local Wi‑Fi** without SIM contracts.  
3. Apply **DePIN-style incentives** via a simple, auditable escrow contract.  
4. Provide **academic integration** of networking, security, mobile development, and smart contracts in one end-to-end system.

## 1.3 Problem Solution

STRATA is a layered prototype:

### Guest Client (Marketplace)

A **Flutter** app in which guests:

1. Join the STRATA Wi‑Fi (AP).  
2. Discover the host API via **captive-portal deep link** and/or **mDNS** (`_strata._tcp`), then fetch **`/host/info`**.  
3. Use a **non-custodial** BIP-39 wallet.  
4. Sign a session-start message with **EIP-191** (`personal_sign`).  
5. Lock funds with **`approve` + `SessionEscrow.openSession`**.  
6. Wait until the host marks the session **active**, then browse.  
7. Stop the session; obtain a host-signed usage receipt; call **`closeSession`** to settle.

### Host Node (Protocol)

A **Python FastAPI** service on Raspberry Pi that:

- Runs **hostapd** + DHCP for a guest subnet (default gateway `192.168.50.1`).  
- Uses **nftables** for captive HTTP redirect, LAN isolation, per-MAC rate limiting, and NAT.  
- Resolves guest **IP → MAC** from the neighbour table.  
- Creates sessions on verified EIP-191 signatures (`POST /session/start`).  
- When chain mode is on, keeps sessions in **`pending_payment`** until **`SessionOpened`** is observed and confirmed.  
- Meters usage in **bytes** (Linux nf_conntrack when `DEMO_MODE=false`).  
- Disconnects on stop or **quota exhaustion**.  
- Hosts an always-on **SOS chatroom** at `WS /ws/chatroom` (LAN; no WAN required).  
- Optionally brings up **WireGuard** to a VPS exit (`WG_ENABLED`).

### Settlement Layer (Official FYP Payment Model)

**SessionEscrow-based metered settlement** (not streaming):

```text
approve STRT
    → openSession(host, amount, sessionRef)
    → SessionOpened (on-chain)
    → ChainListener (+ confirmations / reconcile)
    → host admits MAC (nftables)
    → metered session (bytes vs quota_bytes)
    → stop → host EIP-191 usage receipt
    → closeSession(sessionId, bytesConsumed, quotaBytes, hostSig)
    → PaymentSettled (host paid proportionally; guest refunded remainder)
```

### Firewall (FYP scope)

**nftables** policy providing: guest isolation from private LAN, captive redirect of unauthenticated HTTP, authenticated MAC set (`strata_authed`), ~50 Mbit/s per-MAC rate limit, WAN/WG masquerade.  

**Not in FYP:** Snort/Suricata, adaptive IPS, signature feeds, complex VLAN product security.

### SOS Chatroom (FYP scope)

Always-available local WebSocket chat with history and SOS messages.  

**Not in FYP:** automatic natural-disaster detection or auto-activation.

### WireGuard (FYP scope)

Optional path: Guest → Pi → WG → VPS → Internet. Misconfiguration fails closed at boot validation; operators roll back with `WG_ENABLED=false` (WAN NAT).

## 1.4 Stakeholders

### 1.4.1 Primary Stakeholders

| Stakeholder | Role |
|-------------|------|
| Hosts | Run Pi host software; earn testnet tokens for metered sessions. |
| Guests | Use Flutter app; pay via escrow on testnet. |
| Development team | Abdul Rehman (22I-0785), Laila Tariq (22I-1574). |
| Supervisors / faculty | Academic oversight. |
| Exit-node operator (FYP) | Team-provisioned VPS for WireGuard (owned by Host assignee). |

### 1.4.2 Secondary Stakeholders

ISPs (ToS constraints), telcos (future offload interest), regulators (privacy/VPN), open-source communities, university lab testbed, academic DePIN researchers.

---

# Chapter 2 — Project Description

## 2.1 Project Scope

Design and implement a **functional STRATA prototype** demonstrating end-to-end guest Wi‑Fi, escrow payment, metering, enforcement, optional WG egress, and LAN SOS in a **controlled 3–5 node testbed**.

### 2.1.1 In Scope (FYP)

**Guest (Flutter)**

- Real-host discovery: **mDNS** and/or **captive-portal pin**; `/host/info` enrichment.  
- Non-custodial wallet; EIP-191 session signing.  
- Escrow `approve` / `openSession` / wait for host active / `closeSession` with host receipt bytes.  
- Session dashboard fed by host status (bytes used / quota).  
- Demo marketplace (`STRATA_DEMO_MARKETPLACE`) only when explicitly enabled—not the graded path.

**Host (Raspberry Pi + FastAPI)**

- hostapd AP + DHCP; portal `GET /`, `/portal/client`, `/portal/handshake`.  
- Session API: `/session/start|stop|status`, payment hint endpoint.  
- ChainListener for `SessionOpened` (WSS or HTTP RPC), confirmations, reconcile.  
- Byte metering; quota disconnect; settlement signature fields on stop.  
- nftables enforcement + optional WireGuard.  
- SOS: `/ws/chatroom`, `/chatroom/sos`, `/chatroom/messages`.

**Contracts**

- `StrataToken` (ERC-20) + `SessionEscrow` (Hardhat + Amoy deploy).  
- Events and close/settle as implemented in `contracts/`.

**Validation**

- Automated tests (pytest, Flutter test, Hardhat) plus planned Pi/phone/VPS field checks (§2.10, §2.13).

### 2.1.2 Out of Scope / Future Work

| Item | Reason |
|------|--------|
| L2 streaming payment channels / continuous micropayment streams | Not implemented; SessionEscrow is the FYP model |
| Host staking, slashing, DAO governance, inflation models | No staking code |
| DNS content filtering / blocklists | Not implemented (DNS allowed; post-FYP) |
| IPS/IDS (Snort, Suricata), adaptive threat engines | Not implemented |
| Automatic disaster detection for SOS | Not implemented |
| Mainnet / real-money commercial deployment | Legal & ToS risk |
| Native OpenWRT merge, telco APIs, desktop clients | Beyond FYP |
| Production multi-tenant exit-node marketplace | Beyond FYP |
| Claiming `/ws/metering/...` live streaming | Advertised field only; metering status via HTTP/status stream |

## 2.2 Modules

### 2.2.1 Guest Client (Mobile Application)

**Stack:** Flutter/Dart (`pubspec.yaml` SDK `>=3.0.0 <4.0.0`), web3dart, secure storage.

| Feature | Implementation basis |
|---------|----------------------|
| Discovery | mDNS `_strata._tcp` + captive `strata://onboard` pin; fallback base URL `http://192.168.50.1:8080` |
| Wallet | BIP-39 non-custodial; Amoy balance reads when configured |
| Auth | EIP-191 session-start signature including resolved MAC |
| Payment | SessionEscrow via dart-defined `STRATA_TOKEN` / `SESSION_ESCROW` |
| UX | Quota/usage from host status; blocked/revoked screens |

### 2.2.2 Host Node (Router)

**Stack:** Python ≥3.11, FastAPI, hostapd, dnsmasq, nftables, web3.py.

| Feature | Implementation basis |
|---------|----------------------|
| AP | `host_node/ap/` templates & scripts |
| Portal / MAC | nftables redirect; ARP/neigh MAC resolution |
| Sessions | In-memory store (+ optional SQLite persistence) |
| Metering | Bytes via nf_conntrack when `DEMO_MODE=false` |
| Chain | `ChainListener` HTTP poll or WSS; `_promote_pending`; reconcile |
| Firewall | `strata.nft.j2` |
| SOS | Chatroom WebSocket + REST |
| WG | `WireGuardManager`; fake mode off-Linux/off-root |

### 2.2.3 Security & Settlement Layer

**Stack:** Solidity 0.8.24, Hardhat ^2.22, Polygon Amoy (80002), EIP-191 receipts, WireGuard.

No staking module. No DNS filter module in FYP.

## 2.3 Key Technical Features

| Feature | What it means in FYP |
|---------|----------------------|
| Cryptographic guest auth | EIP-191; invalid signatures rejected |
| Escrow settlement | Lock → meter (bytes) → receipt → close |
| Hardware-light host | Raspberry Pi + open software |
| Traffic isolation | nftables drop guest→private LAN |
| Captive onboarding | Unauthenticated HTTP redirected to portal |
| Optional private egress | WireGuard to VPS |
| LAN emergency chat | SOS chatroom without WAN |

## 2.4 Tools and Technologies

**In use (repository):**

| Tool | Role |
|------|------|
| Python 3.11+, FastAPI, uvicorn | Host service |
| web3.py | Chain listener / settlement helpers |
| Flutter / Dart | Guest app |
| Hardhat, Solidity 0.8.24 | Contracts |
| hostapd, dnsmasq | AP + DHCP |
| nftables | Firewall / portal / NAT |
| WireGuard | Optional exit tunnel |
| pytest (+ markers `integration`, `e2e`) | Host tests |
| Flutter test / analyze | App tests |
| Hardhat test | Contract tests |
| GitHub Actions | `ap-check.yml`, `firewall.yml` |
| just | Task runner (`justfile`) |
| Git / GitHub | Version control |

**Not FYP-required:** scapy, fail2ban, Snort, Suricata, Flask-SocketIO (chatroom is FastAPI WebSocket).

## 2.5 Work Division

**Table 2.1 — Work Division**

| Name | Reg. No. | Primary ownership |
|------|----------|-------------------|
| **Abdul Rehman** | 22I-0785 | Raspberry Pi AP (hostapd/DHCP), **nftables** captive portal & isolation & rate limit & NAT, metering engine, session enforcement, WireGuard **client + VPS exit provisioning**, SOS **host** service, deployment/AP scripts, hardware field bring-up, contribution to final report. |
| **Laila Tariq** | 22I-1574 | Flutter guest app (UI, wallet, discovery, payment UX, blocked-session UX), Solidity **SessionEscrow/StrataToken**, Hardhat tests/deploy artefacts, host **web3 ChainListener** integration & settlement receipt design, ABI sync / dart-defines, contribution to final report. |
| **Shared** | — | End-to-end integration, multi-node field logs, documentation consistency, supervisor demos. |

**Rule:** Firewall/netfilter code has **one** primary owner (Abdul). Laila owns only app-visible enforcement outcomes (blocked/revoked UX).

## 2.6 Timeline

**Table 2.2 — Project Timeline**

| Iteration | Time frame | Objective |
|-----------|------------|-----------|
| **01** | Jan–Feb 2026 | Requirements, literature, architecture, repos/tooling, Pi AP foundation (`hostapd`). |
| **02** | Mar–Apr 2026 | Captive portal + MAC path, metering/enforcement baseline, Flutter discovery/wallet, draft contracts, nftables baseline. |
| **—** | **May–August 2026** | **Calendar interval** between formally numbered Iteration 02 and Iteration 03 in the original plan. **No separate fabricated iteration is declared here.** Repository work may continue (Iteration 2 software completion and Iteration 3 SessionEscrow integration) and is tracked by repo milestones and supervisor checkpoints rather than inventing unscheduled activities for these months. |
| **03** | Sep–Oct 2026 | SessionEscrow integration, ChainListener confirmations/reconcile, Flutter on-chain pay/settle, WireGuard path, SOS chatroom completion, automated chain E2E (Hardhat). |
| **04** | Nov–Dec 2026 | Final integration, 3–5 node field validation, documentation, demo/polish, final report. |

Detailed deliverables and Definitions of Done: **§2.12**.

## 2.7 Success Criteria / Evaluation Metrics

Criteria are **functional and measurable**. Numeric performance SLOs are only stated where they are operationally meaningful for a lab demo; otherwise pass/fail applies.

| ID | Criterion | Pass condition | How measured |
|----|-----------|----------------|--------------|
| SC-1 | AP connectivity | Guest obtains DHCP on STRATA SSID | Phone Wi‑Fi details / `ip neigh` on Pi |
| SC-2 | Captive redirect | Unauthenticated HTTP reaches portal | Browser or `curl` to `http://example.com` |
| SC-3 | Client identity | `/portal/client` returns ARP MAC for guest IP | Compare to `ip neigh` |
| SC-4 | Auth reject | Tampered/invalid EIP-191 signature rejected | Host API error code |
| SC-5 | Auth accept | Valid signature + resolvable MAC creates session | `POST /session/start` 200 |
| SC-6 | Chain open | `openSession` emits `SessionOpened` | Tx receipt / explorer / Hardhat logs |
| SC-7 | Listener admit | After confirmations, session becomes `active` and MAC in `strata_authed` | Status API + `nft list set` |
| SC-8 | Metering | `bytes_used` increases under load when `DEMO_MODE=false` | Status before/after known transfer |
| SC-9 | Quota stop | At `bytes_used ≥ quota_bytes`, session stops and MAC removed | Logs `quota_exhausted` + nft set |
| SC-10 | Settlement | `closeSession` succeeds with host receipt bytes | Tx success + balance change matches contract math |
| SC-11 | Discovery | Flutter lists live host without demo marketplace | mDNS or captive pin; `STRATA_DEMO_MARKETPLACE=false` |
| SC-12 | WG egress (when enabled) | Guest public IP equals VPS IP | `curl` ifconfig from guest |
| SC-13 | WG rollback | With `WG_ENABLED=false`, guest still NATs via WAN | Connectivity + config |
| SC-14 | SOS LAN | Two clients exchange messages and SOS with WAN down | Dual WS clients on guest AP |
| SC-15 | Isolation | Guest cannot reach host private LAN peers | Ping/scan to non-gateway private hosts fails |
| SC-16 | Field set | Planned **3–5 host nodes**, ≥2 guest phones, scripted session log | Field spreadsheet (§2.13) |

## 2.8 Risk Analysis and Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| ISP ToS restricts bandwidth sharing | High | Position as **lab research prototype**; no commercial mainnet rollout in FYP |
| Amoy RPC / faucet outage | High | Local Hardhat node + `iter3_local_chain_e2e.py`; document Amoy as optional public demo |
| Pi hardware failure | Medium–High | Backup SD image; keep AP/host configs in git |
| Wallet mnemonic loss | High | Non-custodial design; backup/confirm screens; never commit keys |
| WireGuard failure | Medium | Boot validation; rollback to WAN NAT (`WG_ENABLED=false`) |
| Incorrect metering | High | `DEMO_MODE=false` on Pi; controlled byte-transfer tests; unit tests |
| Confirmation delay / missed events | Medium | Pending state + block watcher + `reconcile` / admin reconcile |
| Unauthorized Internet access | High | nftables default-deny forward + crypto admit path |
| Privacy exposure | High | Minimal fields; no DPI; retention policy (§2.9) |
| Scope creep (L2 channels, IDS, DNS filter) | Medium | Frozen in §2.1.2 |

## 2.9 Ethics, Privacy, and Legal Considerations

| Topic | Policy |
|-------|--------|
| **Data collected** | Guest wallet address; MAC (for firewall); session id/ref; byte counters; timestamps; optional SOS chat text. **No application payload inspection.** |
| **Why needed** | AuthZ, metering, settlement, enforcement, emergency chat demo. |
| **Retention** | Default: SOS history TTL hours (config); session persistence optional. Lab logs retained only as needed for evaluation, then deleted (target ≤ 30 days on lab devices). |
| **Custody** | **Non-custodial** guest wallets; STRATA does not take custody of guest private keys. Host signing key remains on host device / operator secret store—not in git. |
| **Host liability** | Guests may egress via host WAN or VPS; FYP is educational. Hosts acknowledge ISP ToS may restrict resale. |
| **ISP ToS** | Prototype does **not** grant legal authorization for commercial bandwidth resale. |
| **Consent** | Guests explicitly start a paid session in-app after seeing host/price/quota. |
| **University** | Obtain lab ethics/testbed approval if department requires it before multi-user field tests. |

## 2.10 Testing Strategy

| Layer | Coverage | Tools (actual) |
|-------|----------|----------------|
| **Unit** | Store, crypto, meter modes, settlement hash, config validation, Flutter wallet/storage, Solidity | `pytest -m "not integration and not e2e"`, `flutter test`, `npx hardhat test` |
| **Integration** | Portal/session APIs; ChainListener HTTP E2E vs Hardhat; chatroom multi-client | ASGI TestClient; `host_node/scripts/iter3_local_chain_e2e.py` |
| **Security** | Bad signatures; MAC unresolved; host wallet mismatch; chain misconfig fail-fast; duplicate settle/idempotent events | Host API tests + contract tests |
| **Network** | AP check scripts; nft render/syntax CI; planned Pi captive/nft/WG | `ap-check` workflow; `firewall` workflow; tcpdump/Wireshark in lab as needed |
| **Usability** | Onboarding, pay flow, dashboard, stop/settle | Scripted walkthroughs |
| **Field** | SC-1–SC-16 on Pi/phones/VPS | Field log; `verify_iter2_pi.sh` style checklists |

CI present: `.github/workflows/ap-check.yml`, `.github/workflows/firewall.yml`.

## 2.11 Hardware and Software Requirements (BoM)

### Hardware

| Item | Qty (planned) | Role |
|------|---------------|------|
| Raspberry Pi 4 (4 GB+) or Pi 5 | 3–5 | Host nodes |
| microSD ≥32 GB + official PSU | 1/Pi | Storage/power |
| Ethernet uplink / lab switch | 1 | WAN |
| Android phones | ≥2 | Guests |
| USB Wi‑Fi adapter | 0–2 | Only if needed for AP |
| VPS (1 vCPU, 1 GB, public IPv4) | 1 | WireGuard exit |
| Dev laptop(s) | 1–2 | Flutter/Hardhat/host |

### Software (from repository constraints)

| Component | Constraint / note |
|-----------|-------------------|
| Raspberry Pi OS | Current stable (Bookworm-class) |
| Python | **≥3.11** (`host_node/pyproject.toml`) |
| Flutter/Dart | SDK **≥3.0.0 <4.0.0** (`pubspec.yaml`) |
| Node.js | 20+ recommended for Hardhat |
| Hardhat | **^2.22.10** (`contracts/package.json`) |
| Solidity | **0.8.24** |
| hostapd, dnsmasq, nftables, WireGuard | Distro packages |
| Polygon Amoy | Chain ID **80002** (when used) |

## 2.12 Per-Iteration Deliverables and Definition of Done

| Iter | Time | Features | Deliverables | Definition of Done | Demo / validation |
|------|------|----------|--------------|--------------------|-------------------|
| **01** | Jan–Feb 2026 | Requirements, architecture, Pi AP | Docs, repos, AP scripts | SSID up; DHCP lease | Phone joins AP |
| **02** | Mar–Apr 2026 | Portal, MAC, EIP-191 start, metering/enforce baseline, Flutter wallet/discovery, draft contracts, nftables baseline | Working portal+session software path; contract compile/tests | Portal identifies client; start session off-chain; Flutter wallet works | Software demo + unit tests green |
| **03** | Sep–Oct 2026 | SessionEscrow, ChainListener, Flutter pay/settle, WG, SOS | Deploy artefacts, ABI sync, local chain E2E script | openSession→admit→meter→receipt→close on Hardhat; SOS two-client; WG config/rollback docs | Local chain E2E; optional Amoy if keys available |
| **04** | Nov–Dec 2026 | Field integration, polish, report | Field log, final report, slides | SC table completed or variances explained | 3–5 node viva demo |

## 2.13 Demo Topology and Node Roles

```text
                 Polygon Amoy (optional) / Hardhat (local)
                           │
                     SessionEscrow
                           │
Guest Phone(s) ──Wi‑Fi──► STRATA Pi Host ──┬── WAN NAT ──► Internet
      │                    │               │
   Flutter            Captive + nftables   └── WireGuard ──► VPS Exit ──► Internet
      │                    │                      (optional)
      │                 Metering
      │                 ChainListener
      │
Guest1 ──┐
         ├── LAN SOS chatroom (no WAN required)
Guest2 ──┘
```

| Node | Role |
|------|------|
| Pi hosts (3–5) | Each: AP + host_node; at least one primary demo Pi |
| VPS | Single shared WireGuard exit (typical FYP setup) |
| Phones (≥2) | Guests; SOS multi-client |
| Laptop | Deploy/monitor/Hardhat |
| Chain | Amoy public demo and/or Hardhat local |

**Defaults (lab):** gateway `192.168.50.1`, API `:8080`, SSID e.g. `STRATA-Pi-01`, guest DHCP `192.168.50.50–200`.

**What counts as a “node” in the 3–5 node test:** one Raspberry Pi running host software + AP. Guests are not counted as host nodes. Success = scripted sessions meeting SC-1–SC-11 (and SC-12–14 when WG/SOS exercised) on that set.

## 2.14 API and Interface Contracts

### Flutter → Host (implemented)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Captive portal HTML |
| GET | `/portal/client` | Client IP/MAC |
| POST | `/portal/handshake` | Signed onboarding helper |
| GET | `/host/info` | Host wallet, pricing, display name |
| POST | `/session/start` | Create session (sig verify + MAC) |
| GET | `/session/status` | Status, bytes, settlement fields |
| POST | `/session/stop` | Stop + receipt fields when chain configured |
| POST | `/session/{id}/payment` | Optional tx hash hint (non-authoritative) |
| GET | `/health`, `/version` | Health |
| GET | `/metering/{mac}` | Metering snapshot |
| WS | `/ws/chatroom` | SOS chat |
| POST | `/chatroom/sos` | SOS REST |
| GET | `/chatroom/messages` | History |
| POST | `/admin/reconcile` | Chain catch-up (token gated) |
| GET | `/admin/firewall/state` | Admitted MAC mirror |

### Host → Blockchain

`SessionOpened` subscribe/poll; `openSession` / `closeSession` / `disputeSession` from guest wallet; host EIP-191 receipt for close.

### Discovery

mDNS `_strata._tcp`; captive `strata://onboard`; `/host/info`.

## 2.15 Feature → Module → Owner → Iteration Matrix

| Feature | Module | Primary owner | Iteration | Deliverable |
|---------|--------|---------------|-----------|-------------|
| Pi AP (hostapd/DHCP) | Host | Abdul | 01–02 | `host_node/ap/` |
| Captive portal + MAC | Host | Abdul | 02 | portal routes + neigh |
| nftables isolation/rate/NAT | Host | Abdul | 02–03 | `strata.nft.j2` |
| Metering (bytes) + quota stop | Host | Abdul | 02–03 | `meter.py` / TrafficReader |
| Enforcement admit/disconnect | Host | Abdul | 02–03 | `enforcer.py` |
| WireGuard + VPS exit | Host | Abdul | 03–04 | WG manager + VPS peer |
| SOS chatroom (host) | Host | Abdul | 03 | `/ws/chatroom` |
| Flutter UI / wallet / UX | Guest | Laila | 02–03 | `lib/` |
| mDNS + captive discovery | Guest+Host | Laila (app) / Abdul (advertise) | 02–03 | discovery services |
| EIP-191 session auth | Both | Laila (sign) / Abdul (verify path) | 02 | session_crypto + Flutter sign |
| SessionEscrow + token | Settlement | Laila | 02–03 | `contracts/` |
| ChainListener + reconcile | Host/Settlement | Laila (integration) with Abdul (deploy env) | 03 | `chain_real.py` |
| Payment + settle UX | Guest | Laila | 03 | payment + dashboard settle |
| Multi-node field test | Shared | Shared | 04 | field log |
| Documentation / report | Shared | Shared | 01–04 | docs + final report |
| DNS filtering | — | — | — | **Out of scope** |
| L2 payment channels | — | — | — | **Out of scope** |
| Disaster auto-SOS | — | — | — | **Out of scope** |

---

# Appendix A — Glossary

| Term | Meaning |
|------|---------|
| SessionEscrow | FYP escrow contract: lock, settle by bytes/quota, refund remainder |
| EIP-191 | `personal_sign` message signing used for session start and receipts |
| `quota_bytes` / `bytes_used` | Authoritative metering units on the host |
| `strata_authed` | nftables set of admitted guest MACs |
| DEMO_MODE | When true, metering may use synthetic increments (lab only) |
| mDNS | Multicast DNS host discovery (`_strata._tcp`) |
| SOS chatroom | Always-on LAN WebSocket emergency chat |

---

# Appendix B — Bibliography

[1] Polygon Technology. *Polygon Documentation*. https://docs.polygon.technology/ (accessed 20 Feb 2026).

[2] Ethereum Foundation. *Ethereum Developer Documentation*. https://ethereum.org/en/developers/ (accessed 20 Feb 2026).

[3] J. A. Donenfeld, “WireGuard: Next Generation Kernel Network Tunnel,” NDSS, 2017; https://www.wireguard.com/ (accessed 20 Feb 2026).

[4] Flutter Team. *Flutter Documentation*. https://docs.flutter.dev/ (accessed 20 Feb 2026).

[5] Ethereum. *web3.py Documentation*. https://web3py.readthedocs.io/ (accessed 20 Feb 2026).

[6] Helium. *Helium Documentation*. https://docs.helium.com/ (accessed 20 Feb 2026).

[7] Netfilter Project. *nftables*. https://wiki.nftables.org/ (accessed 20 Feb 2026).

[8] P. Srisuresh and K. Egevang, “Traditional NAT,” *RFC 3022*, IETF, Jan. 2001. https://www.rfc-editor.org/rfc/rfc3022 (accessed 20 Feb 2026).

[9] OpenZeppelin. *Contracts Documentation*. https://docs.openzeppelin.com/contracts/ (accessed 20 Feb 2026).

[10] Hostapd / Linux wireless AP documentation (distribution manuals for `hostapd`).

*Note: Broad “70–80% idle bandwidth” statistics from the original draft are omitted as unsupported. DePIN competitor systems are cited via vendor documentation for context only.*

---

# Change Report

## Major Changes

Rewrote payment, firewall, SOS, discovery, tools, work division, timeline gap handling, and evaluation sections; added §§2.7–2.15, appendices, and feature matrix.

## Scope Changes

| From | To |
|------|-----|
| L2 streaming / payment channels | **Out of scope**; SessionEscrow in scope |
| per-second or per-MB | **Bytes** metering (`quota_bytes`) |
| IPS/Snort/adaptive firewall | **Out of scope**; nftables isolation/portal/rate/NAT in scope |
| Disaster auto-SOS | **Out of scope**; always-on LAN chat in scope |
| DNS filtering as FYP feature | **Out of scope** (not implemented) |
| Staking | **Out of scope** |
| SSID-primary discovery | **mDNS + captive pin** authoritative |
| Fabricated Iter 02b summer plan | **Neutral May–Aug calendar note** |

## Ownership Changes

Firewall/netfilter → Abdul only. Flutter + contracts + ChainListener integration → Laila. VPS exit → Abdul. Shared field test/docs.

## Timeline Changes

May–August 2026 labeled as a **calendar interval without a fabricated iteration**, consistent with the original April→September jump and without inventing unrecorded activities.

## New Sections

Success criteria; risks; ethics/privacy; testing; BoM; iteration DoD; topology; APIs; feature matrix; glossary; bibliography.

## Remaining Issues

| Issue | Why unresolved here |
|-------|---------------------|
| Live Amoy deploy addresses | Requires operator `DEPLOYER_PRIVATE_KEY` (not in repo) |
| Hardware field results (Pi/phone/VPS egress) | Require physical testbed; software complete ≠ hardware verified |
| Exact departmental ethics form | Depends on university process |
| Precise Flutter channel/build number used on demo phones | Pin at demo time in field log |

---

## Answers the Document Must Make Unambiguous

1. **Building:** Pi host + Flutter guest + SessionEscrow metered Wi‑Fi prototype with nftables, optional WG, LAN SOS.  
2. **Not building:** L2 channels, staking/DAO, IDS, DNS filter product, disaster auto-SOS, commercial mainnet.  
3. **Payment:** SessionEscrow lock → SessionOpened admit → bytes meter → receipt → closeSession.  
4. **Guest Wi‑Fi:** Join AP → portal/mDNS → pay/admit → browse.  
5. **Auth:** EIP-191 + host MAC resolve.  
6. **Usage:** Byte counters vs `quota_bytes`.  
7. **Settle:** Host-signed receipt + `closeSession`.  
8. **Firewall:** nftables isolation/redirect/rate/NAT/authed set.  
9. **SOS:** Always-on LAN WebSocket chat.  
10. **WireGuard:** Optional VPS egress + WAN rollback.  
11. **Owners:** §2.5 + §2.15.  
12. **When:** §2.6 + §2.12.  
13. **Tests:** §2.10.  
14. **Success:** §2.7.  
15. **Limits:** §2.1.2 + Remaining Issues.

---

*End of Scope Document v3.0 — aligned with the STRATA repository. Export this Markdown to PDF for submission.*
