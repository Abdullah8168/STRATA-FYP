# Testing the Iteration 3 router work on the Raspberry Pi

You need: a Pi on Raspberry Pi OS Bookworm, plugged into your router by
**Ethernet** (`eth0`), SSH enabled, and its IP address (check your router's
device list, or run `hostname -I` on the Pi).

## 1. Copy the code to the Pi (from Windows PowerShell)

```powershell
cd "C:\Users\Hp\Downloads\lilyassignment-1 2\lilyassignment-1 2"
tar --exclude=host_node/.venv --exclude=__pycache__ -czf host_node.tgz host_node
scp host_node.tgz pi@<PI_IP>:~
ssh pi@<PI_IP>
```

(Replace `pi` with your Pi username.) Everything below runs **on the Pi**.

## 2. Install (once)

```bash
mkdir -p ~/strata && tar -xzf ~/host_node.tgz -C ~/strata && cd ~/strata/host_node
sudo apt update
sudo apt install -y python3-venv nftables iperf3 netcat-openbsd wireguard-tools conntrack
python3 -m venv .venv
.venv/bin/pip install -e . pytest pytest-asyncio pytest-mock httpx
```

## 3. Unit tests (≈ 1 min, safe)

```bash
.venv/bin/python -m pytest -q -m "not integration and not e2e"
```

Expect: all passed (some skipped). Send me the output if anything fails.

## 4. WireGuard routing — real kernel, no VPS (≈ 2 min)

⚠ These tests temporarily replace the Pi's firewall. Your current SSH session
keeps working, but **new** SSH logins are blocked until the test ends. Don't
run the host node at the same time. If anything gets stuck:
`sudo nft delete table inet strata` (or reboot).

```bash
sudo .venv/bin/python -m pytest -v tests/firewall/test_strata_nft_syntax.py
# run in the background: the first test firewall can cut an SSH session
# that is connected over Wi-Fi (seen on a real Pi 4, 2026-10-03)
sudo nohup .venv/bin/python -m pytest -v -m integration tests/firewall/integration > ~/it.log 2>&1 &
# reconnect if needed, then:
tail -3 ~/it.log
```

Expect `3 passed` and `13 passed` (≈ 1 min). Already passing on a real
Linux kernel (WSL); this confirms the Pi's kernel behaves the same.

| File | Proves |
|------|--------|
| `test_guest_firewall.py` | unpaid guest has no internet; admitted guest can't reach the home LAN; removing a guest blocks new **and running** transfers; the internet can't connect into a guest; 50 Mbit/s cap on upload and download |
| `test_conntrack_metering.py` | usage counted from real traffic, and kept after connections close |
| `test_wg_guest_routing.py` | guest → tunnel, Pi → WAN, kill switch, fallback, self-repair, cleanup (see [WIREGUARD_VPS.md](WIREGUARD_VPS.md#test-1--pi-only-no-vps--5-min)) |

Full WireGuard with a real VPS: Test 2 in WIREGUARD_VPS.md.

## 5. Usage counting with a real phone (≈ 10 min)

Needs the STRATA Wi-Fi access point from Iteration 1 running on the Pi
(`sudo bash ap/scripts/verify_ap.sh`; set it up with `ap/README.md` if not).

**a. Configure** — `nano .env` and set these lines (add any that are missing):

```text
DEMO_MODE=false
CHAIN_ENABLED=false
ALLOW_CLIENT_MAC=true
WG_ENABLED=false
GUEST_IFACE=wlan0
WAN_IFACE=eth0
```

**b. Start the host node as root** (terminal 1):

```bash
cd ~/strata/host_node && sudo .venv/bin/strata-host
```

In the startup log look for `kernel.prereq_ok` twice (ip_forward and
nf_conntrack_acct) and `"metering_mode": "real_conntrack"`.

**c. Admit the phone** (terminal 2 — a second `ssh pi@<PI_IP>`):

```bash
cd ~/strata/host_node
sysctl net.ipv4.ip_forward net.netfilter.nf_conntrack_acct    # both = 1
# connect the phone to the STRATA Wi-Fi, then find its MAC:
ip neigh show dev wlan0
.venv/bin/python scripts/pi_start_test_session.py --mac <PHONE_MAC>
```

It prints the session id and a `watch:` command.

**d. Measure**

| # | Do | Expect |
|---|----|--------|
| 1 | Phone: open any website | it loads (forwarding works) |
| 2 | run the `watch:` command a few times while idle | `bytes_used` barely changes |
| 3 | Phone: download a file of known size, e.g. `https://ash-speed.hetzner.com/100MB.bin` (any test file works) | `bytes_used` rises by ≈ 100 MB (a few % more for headers) |
| 4 | after the download finishes, run `watch:` again | `bytes_used` stays at that value — it must **not** drop |
| 5 | `.venv/bin/python scripts/pi_start_test_session.py --stop <SESSION_ID>`, then reload a page on the phone | the phone loses internet |

Stop the host node with Ctrl+C in terminal 1. Put `.env` back afterwards if
you use it for the chain demo.

## What to send back

The last lines of steps 3 and 4, and the numbers from 5d (bytes_used before /
after the download and after it finished).
