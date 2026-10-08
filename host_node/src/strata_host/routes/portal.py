"""Captive portal landing + client identity + handshake completion."""

from __future__ import annotations

import base64
import html
import io
from urllib.parse import urlencode

import qrcode
from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from qrcode.image.svg import SvgPathImage

from strata_host.chain import ChainService
from strata_host.config import Settings
from strata_host.enforcer import EnforcerService
from strata_host.models import ClientIdentityResponse, StartSessionRequest
from strata_host.neighbour import client_ip_from_request, lookup_mac_for_ip
from strata_host.session_start import authenticate_and_create_session
from strata_host.store import SessionStore

router = APIRouter(tags=["portal"])


def _get_store() -> SessionStore:
    raise RuntimeError("Dependency override not configured.")


def _get_enforcer() -> EnforcerService:
    raise RuntimeError("Dependency override not configured.")


def _get_chain() -> ChainService:
    raise RuntimeError("Dependency override not configured.")


def _get_settings() -> Settings:
    raise RuntimeError("Dependency override not configured.")


def _deep_link(*, portal_ip: str, portal_port: int, host_address: str) -> str:
    q = urlencode(
        {
            "portal_ip": portal_ip,
            "portal_port": str(portal_port),
            "host_address": host_address,
        }
    )
    return f"strata://onboard?{q}"


def _qr_data_uri(data: str) -> str:
    qr = qrcode.QRCode(version=None, box_size=4, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(image_factory=SvgPathImage)
    buf = io.BytesIO()
    img.save(buf)
    raw = buf.getvalue()
    b64 = base64.b64encode(raw).decode("ascii")
    return f"data:image/svg+xml;base64,{b64}"


def _identity_for_request(request: Request, settings: Settings) -> ClientIdentityResponse:
    client_ip = client_ip_from_request(request)
    mac = None
    source: str = "unknown"
    if client_ip:
        mac = lookup_mac_for_ip(client_ip, settings.GUEST_IFACE)
        if mac:
            source = "arp"
    host_wallet = (settings.HOST_WALLET_ADDRESS or "").strip() or None
    if mac:
        message = (
            "MAC resolved from ARP. Sign the STRATA-SESSION-START message "
            "including this MAC, then POST /session/start or /portal/handshake."
        )
    else:
        message = (
            "MAC not yet in the neighbour table. Stay on the STRATA Wi-Fi, "
            "generate some traffic (reload this page), then retry. "
            "Lab/tests may set ALLOW_CLIENT_MAC=true."
        )
    return ClientIdentityResponse(
        client_ip=client_ip,
        mac_address=mac,
        mac_source=source,  # type: ignore[arg-type]
        guest_iface=settings.GUEST_IFACE,
        host_wallet_address=host_wallet,
        host_display_name=settings.HOST_DISPLAY_NAME,
        host_ssid=settings.HOST_SSID,
        portal_port=settings.PORTAL_PORT,
        demo_mode=settings.DEMO_MODE,
        allow_client_mac=settings.ALLOW_CLIENT_MAC,
        message=message,
    )


@router.get("/portal/client", response_model=ClientIdentityResponse)
async def portal_client_identity(
    request: Request,
    settings: Settings = Depends(_get_settings),
) -> ClientIdentityResponse:
    """Return the guest IP/MAC the client must use when signing session-start."""
    return _identity_for_request(request, settings)


@router.post("/portal/handshake")
async def portal_handshake(
    request: Request,
    payload: StartSessionRequest,
    store: SessionStore = Depends(_get_store),
    enforcer: EnforcerService = Depends(_get_enforcer),
    chain: ChainService = Depends(_get_chain),
    settings: Settings = Depends(_get_settings),
) -> dict:
    """Complete captive-portal onboarding: verify signature, create session, admit.

    Same cryptographic contract as ``POST /session/start``. Prefer the app
    deep-link flow; this endpoint supports HTML/JS or curl demos on the AP.
    """
    record = await authenticate_and_create_session(
        request=request,
        payload=payload,
        store=store,
        settings=settings,
    )
    if record.status == "active":
        await enforcer.admit(record.mac_address, origin="portal")
    await chain.on_session_opened(str(record.session_id), record.guest_wallet_address)
    body = record.to_response().model_dump(mode="json")
    body["handshake"] = "ok"
    body["admitted"] = record.status == "active"
    return body


@router.get("/", response_class=HTMLResponse)
async def captive_portal_landing(request: Request) -> HTMLResponse:
    settings = request.app.state.settings
    identity = _identity_for_request(request, settings)
    host_wallet = identity.host_wallet_address or ""
    wallet_display = host_wallet if host_wallet else "Not configured yet"

    portal_ip = request.url.hostname or "127.0.0.1"
    portal_port = settings.PORTAL_PORT
    host_for_link = host_wallet or "0x0000000000000000000000000000000000000000"
    deep_link = _deep_link(
        portal_ip=portal_ip,
        portal_port=portal_port,
        host_address=host_for_link,
    )
    qr_src = _qr_data_uri(deep_link)

    escaped_wallet = html.escape(wallet_display)
    escaped_link = html.escape(deep_link)
    escaped_qr_src = html.escape(qr_src, quote=True)
    escaped_ssid = html.escape(settings.HOST_SSID)
    mac_line = identity.mac_address or "(not resolved yet — reload after joining Wi-Fi)"
    escaped_mac = html.escape(mac_line)
    escaped_ip = html.escape(identity.client_ip or "unknown")
    escaped_msg = html.escape(identity.message)
    demo_badge = "DEMO_MODE=on" if settings.DEMO_MODE else "DEMO_MODE=off (real metering)"

    body = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>STRATA — Wi-Fi access</title>
  <style>
    body {{
      font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      margin: 0; padding: 1.5rem; background: #0f1419; color: #e6edf3;
      line-height: 1.5;
    }}
    main {{ max-width: 36rem; margin: 0 auto; }}
    h1 {{ font-size: 1.5rem; margin-top: 0; }}
    .card {{
      background: #161b22; border: 1px solid #30363d; border-radius: 10px;
      padding: 1rem 1.25rem; margin: 1rem 0;
    }}
    code {{
      display: block; word-break: break-all; font-size: 0.85rem;
      background: #0d1117; padding: 0.75rem; border-radius: 6px;
      border: 1px solid #21262d;
    }}
    .qr-wrap {{ text-align: center; margin: 1rem 0; }}
    .qr-wrap img {{ max-width: 220px; height: auto; }}
    a.app-link {{ color: #58a6ff; }}
    .muted {{ color: #8b949e; font-size: 0.9rem; }}
    ol {{ padding-left: 1.2rem; }}
  </style>
</head>
<body>
  <main>
    <h1>STRATA</h1>
    <p class="muted">{html.escape(demo_badge)} · SSID {escaped_ssid}</p>
    <p>
      STRATA is a peer-to-peer marketplace for Wi-Fi bandwidth. You are on the
      STRATA guest network. Open the STRATA app to sign a session (EIP-191) and
      get internet access. HTTP was redirected here by the host firewall until
      you are admitted.
    </p>
    <div class="card">
      <strong>Your device (from this host)</strong>
      <p style="margin: 0.5rem 0 0;">IP: {escaped_ip}</p>
      <p style="margin: 0.5rem 0 0;">MAC: {escaped_mac}</p>
      <p class="muted" style="margin: 0.5rem 0 0;">{escaped_msg}</p>
      <p class="muted">API: <code style="display:inline;padding:0.2rem 0.4rem;">GET /portal/client</code></p>
    </div>
    <div class="card">
      <strong>Host wallet</strong>
      <p style="margin: 0.5rem 0 0;">{escaped_wallet}</p>
    </div>
    <div class="card">
      <strong>How to connect</strong>
      <ol>
        <li>Install / open the STRATA app.</li>
        <li>Scan the QR or tap the deep link (pins this host).</li>
        <li>Create or unlock your wallet, choose a quota, pay / start session.</li>
        <li>App calls <code style="display:inline;">POST /session/start</code> with a signature over your MAC.</li>
      </ol>
      <div class="qr-wrap">
        <img src="{escaped_qr_src}" width="200" height="200" alt="STRATA onboarding QR"/>
      </div>
      <p><a class="app-link" href="{escaped_link}">{escaped_link}</a></p>
    </div>
  </main>
</body>
</html>"""
    return HTMLResponse(content=body, media_type="text/html; charset=utf-8")
