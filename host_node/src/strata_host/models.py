from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


MAC_REGEX = r"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"
WALLET_REGEX = r"^0x[a-fA-F0-9]{40}$"
SESSION_REF_REGEX = r"^0x[0-9a-fA-F]{64}$"
TX_HASH_REGEX = r"^0x[0-9a-fA-F]{64}$"


SessionStatus = Literal["pending_payment", "active", "stopped"]


class StartSessionRequest(BaseModel):
    """Body of POST /session/start.

    Field names are the JSON contract shared with the Flutter app's
    SessionStartRequest model. Renaming any of these is a breaking change
    that requires a coordinated client release.
    """

    guest_wallet_address: str = Field(pattern=WALLET_REGEX)
    host_wallet_address: str = Field(pattern=WALLET_REGEX)
    # Optional hint. Authoritative MAC is resolved from ARP on the Pi;
    # empty string is allowed so Flutter can omit it until /portal/client.
    mac_address: str = Field(
        default="",
        pattern=r"^$|^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$",
    )
    quota_bytes: int = Field(gt=0)
    price_per_gb_wei: str = Field(pattern=r"^[0-9]+$")
    nonce: UUID
    guest_signature: str = Field(pattern=r"^0x[0-9a-fA-F]+$")
    # Phase E — optional client-supplied hint that lets us record a tx hash
    # when the on-chain openSession call has already been broadcast.
    tx_hash: str | None = Field(default=None, pattern=TX_HASH_REGEX)
    # Optional display-only access key from the Flutter app (not validated).
    access_key: str | None = Field(default=None, max_length=64)

    @field_validator("mac_address")
    @classmethod
    def normalize_mac(cls, value: str) -> str:
        return value.lower().strip()


class StopSessionRequest(BaseModel):
    session_id: UUID
    reason: Literal["client_disconnect", "quota_exhausted", "host_stop", "admin_stop"]


class PaymentNotifyRequest(BaseModel):
    """Body of POST /session/{session_id}/payment.

    Pure observability. The on-chain SessionOpened event is the only path
    that promotes a session to "active".
    """

    tx_hash: str = Field(pattern=TX_HASH_REGEX)


class SessionResponse(BaseModel):
    session_id: UUID
    status: SessionStatus
    mac_address: str
    guest_wallet_address: str
    host_wallet_address: str
    started_at: datetime
    expires_at: datetime
    bytes_used: int
    quota_bytes: int
    metering_ws_url: str
    # Phase E — guest needs this to call openSession on-chain. Always set.
    session_ref: str = Field(pattern=SESSION_REF_REGEX)
    tx_hash: str | None = None
    chain_session_id: int | None = None
    stop_reason: str | None = None
    stopped_at: datetime | None = None
    host_settlement_sig: str | None = None
    settlement_bytes_consumed: int | None = None
    settlement_quota_bytes: int | None = None
    receipt_hash: str | None = None
    # Iteration 3 — periodic micropayment view for the guest. accrued is a
    # decimal string (wei can exceed JS/Dart int range).
    accrued_payment_wei: str | None = None
    checkpoint_bytes: int | None = None
    checkpoint_at: datetime | None = None
    # None | "settled" | "closed_by_guest" | "failed" — the router's own
    # closeSession. If "settled", the guest must not call closeSession.
    settlement_status: str | None = None
    settlement_tx_hash: str | None = None
    # Download (reply direction) / upload split of bytes_used, for the
    # guest dashboard's live speed display.
    bytes_in: int | None = None
    bytes_out: int | None = None


class WireGuardHealth(BaseModel):
    mode: Literal["real", "fake"]
    tunnel_up: bool
    rule_installed: bool
    tunnel_route_installed: bool
    kill_switch: bool
    latest_handshake_age_seconds: int | None


class HealthResponse(BaseModel):
    status: Literal["ok"]
    service: Literal["strata-host-node"]
    version: str
    uptime_seconds: int
    demo_mode: bool
    # Present only when WG_ENABLED=true.
    wireguard: WireGuardHealth | None = None


class VersionResponse(BaseModel):
    service: Literal["strata-host-node"]
    version: str
    python: str


class MeteringResponse(BaseModel):
    mac_address: str
    session_id: UUID | None
    bytes_in: int
    bytes_out: int
    bytes_total: int
    quota_bytes: int
    status: SessionStatus
    last_updated: datetime


class ClientIdentityResponse(BaseModel):
    """GET /portal/client — identity the guest should sign over."""

    client_ip: str | None
    mac_address: str | None
    mac_source: Literal["arp", "unknown"]
    guest_iface: str
    host_wallet_address: str | None
    host_display_name: str
    host_ssid: str
    portal_port: int
    demo_mode: bool
    allow_client_mac: bool
    message: str


class HostInfoResponse(BaseModel):
    """GET /host/info — Flutter LAN host card metadata."""

    name: str
    display_name: str
    ssid: str
    wallet_address: str
    host_wallet_address: str
    price_per_gb_wei: str
    price_per_gb: float
    guest_iface: str
    wan_iface: str
    portal_port: int
    demo_mode: bool
    chain_enabled: bool
    version: str
    ap_gateway: str = "192.168.50.1"
