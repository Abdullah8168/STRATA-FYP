from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    HOST: str = "0.0.0.0"
    PORT: int = 8080
    LOG_LEVEL: str = "INFO"
    DEMO_MODE: bool = True
    SESSION_DEFAULT_TTL_SECONDS: int = 3600
    METER_TICK_SECONDS: float = 2.0
    ALLOWED_ORIGINS: list[str] = ["*"]

    # When true, /session/start may accept a client-supplied MAC if ARP
    # cannot resolve the guest (ASGI tests, laptop against localhost).
    # On a production Pi keep this false so MAC always comes from neigh.
    ALLOW_CLIENT_MAC: bool = False

    # Published via GET /host/info for Flutter LAN discovery cards.
    HOST_DISPLAY_NAME: str = "STRATA Host"
    HOST_SSID: str = "STRATA-Pi-01"
    DEFAULT_PRICE_PER_GB_WEI: str = "1000000000000000"
    DEFAULT_PRICE_PER_GB: float = 0.5

    # Phase E — on-chain settlement.
    #
    # When CHAIN_ENABLED is true AND the addresses below are set, the host
    # node spawns a ChainListener that subscribes to SessionOpened events on
    # SessionEscrow filtered by HOST_WALLET_ADDRESS. New sessions start in
    # status "pending_payment" and are not metered until the listener marks
    # them paid.
    #
    # When CHAIN_ENABLED is false the host node keeps Phase A behaviour:
    # sessions start in "active" immediately and the chain stub logs
    # "chain.listener_disabled".
    CHAIN_ENABLED: bool = False
    # JSON-RPC endpoint for ChainListener. Accepts wss:// (Amoy) or
    # http://127.0.0.1:8545 (Hardhat node). AMOY_WSS_URL is the legacy name.
    CHAIN_RPC_URL: str | None = None
    AMOY_WSS_URL: str = "wss://polygon-amoy-bor-rpc.publicnode.com"
    SESSION_ESCROW_ADDRESS: str | None = None
    STRATA_TOKEN_ADDRESS: str | None = None
    HOST_WALLET_ADDRESS: str | None = None
    # EIP-191 signing key for ``closeSession`` receipts (hex, optional ``0x``).
    # Must correspond to ``HOST_WALLET_ADDRESS`` or on-chain settlement fails.
    HOST_SIGNING_PRIVATE_KEY: str | None = None
    CHAIN_ID: int = 80002

    # Iteration 3 — periodic micropayment, host side (strata_host.payments).
    #
    # Every SETTLEMENT_CHECKPOINT_SECONDS the host signs a closeSession
    # receipt for each active on-chain session's usage so far (kept on the
    # host, see SessionRecord.checkpoint_sig). Guests see the running cost
    # as accrued_payment_wei.
    #
    # HOST_AUTO_SETTLE: once a session stops, give the guest
    # SETTLE_GRACE_SECONDS to call closeSession from the app; if they
    # haven't, the host submits it itself (pays gas from HOST_WALLET_ADDRESS).
    # SESSION_MAX_AGE_SECONDS stops still-running sessions early enough that
    # the host can settle before the guest may dispute (escrow: 24 h).
    SETTLEMENT_CHECKPOINT_SECONDS: float = 60.0
    HOST_AUTO_SETTLE: bool = True
    SETTLE_GRACE_SECONDS: float = 120.0
    SETTLE_POLL_SECONDS: float = 15.0
    SETTLE_MAX_ATTEMPTS: int = 8
    SETTLE_TX_TIMEOUT_SECONDS: float = 120.0
    SESSION_MAX_AGE_SECONDS: int = 23 * 3600

    # Walled-garden JSON-RPC relay at POST /rpc on the portal port, so
    # guests can pay (approve + openSession) before they are admitted.
    # Only active when CHAIN_ENABLED; see routes/rpc.py.
    RPC_RELAY_ENABLED: bool = True

    def chain_rpc_url(self) -> str:
        """Effective RPC URL for the chain listener (HTTP or WS)."""
        if self.CHAIN_RPC_URL and self.CHAIN_RPC_URL.strip():
            return self.CHAIN_RPC_URL.strip()
        return (self.AMOY_WSS_URL or "").strip()

    # Phase F — firewall + WireGuard egress.
    #
    # The nftables template uses GUEST_IFACE / WAN_IFACE / PORTAL_PORT to
    # build the forward + nat chains. Defaults match a standard Pi setup
    # (wlan0 for the AP, eth0 for the uplink).
    GUEST_IFACE: str = "wlan0"
    WAN_IFACE: str = "eth0"
    PORTAL_PORT: int = 8080
    SSH_PORT: int = 22

    # WireGuard exit-tunnel stub. WG_ENABLED flips the postrouting chain to
    # masquerade through wg0. The team VPS endpoint and pubkey come from
    # the operator out-of-band — see .env.example.
    WG_ENABLED: bool = False
    WG_PRIVATE_KEY_PATH: str = "/etc/strata/wg0.key"
    WG_LISTEN_PORT: int = 51820
    WG_PEER_PUBLIC_KEY: str | None = None
    WG_PEER_ENDPOINT: str | None = None
    WG_PEER_ALLOWED_IPS: str = "0.0.0.0/0,::/0"
    WG_ADDRESS: str = "10.66.66.1/24"

    # Iteration 3 — guest-only policy routing through the tunnel.
    #
    # wg-quick runs with ``Table = off`` so the Pi's own traffic (SSH, RPC,
    # the WireGuard handshake itself) keeps using WAN_IFACE. Only packets
    # sourced from GUEST_SUBNET are steered into WG_ROUTE_TABLE, whose
    # default route is wg0.
    #
    # WG_FALLBACK_TO_WAN=false is the kill switch: if wg0 is down, guest
    # traffic is dropped instead of leaking out of the host's residential
    # IP. Set it to true to prefer availability over privacy.
    GUEST_SUBNET: str = "192.168.50.0/24"
    WG_ROUTE_TABLE: int = 51820
    WG_RULE_PRIORITY: int = 10000
    WG_FALLBACK_TO_WAN: bool = False
    # How often the host node re-checks that the guest route is still
    # installed (it disappears if wg0 is bounced outside the host node).
    WG_ROUTE_CHECK_SECONDS: float = 15.0

    # Phase G — integration pass.
    #
    # ADMIN_TOKEN gates the admin endpoints (/admin/reconcile, /admin/firewall/state).
    # When unset, those endpoints return 503 — they're not enabled by accident.
    # CHAIN_CONFIRMATIONS is the number of blocks the listener waits before
    # admitting a MAC. 3 is the default; DEMO_MODE forces it to 0 so pay-and-
    # connect feels snappy when you're showing the project to a panel.
    # CHATROOM_PERSIST flips the SOS chatroom store from RAM-only to a SQLite
    # file at CHATROOM_DB_PATH so messages survive a Pi reboot.
    # MDNS_ENABLED toggles the zeroconf advertiser.
    ADMIN_TOKEN: str | None = None
    CHAIN_CONFIRMATIONS: int = 3
    CHATROOM_PERSIST: bool = False
    CHATROOM_DB_PATH: str = "/var/lib/strata/chatroom.sqlite"
    CHATROOM_HISTORY_LIMIT: int = 500
    CHATROOM_HISTORY_TTL_HOURS: int = 24
    MDNS_ENABLED: bool = True
    MDNS_SERVICE_TYPE: str = "_strata._tcp.local."
    SERVICE_VERSION: str = "1.0"

    # Iteration 3 — host controls from the app (routes/admin.py /admin/host,
    # needs ADMIN_TOKEN). Changes made there are saved to HOST_CONFIG_PATH
    # and override the values above on the next start; .env is not edited.
    # MAX_GUESTS=None means no limit (the previous behaviour).
    MAX_GUESTS: int | None = None
    HOST_CONFIG_PATH: str = "/var/lib/strata/host_config.json"
    # Hotspot files the Wi-Fi name/password change rewrites (written by
    # ap/scripts/setup_ap.sh). AP_ENV_PATH is relative to the working dir.
    AP_ENV_PATH: str = "ap/.env"
    HOSTAPD_CONF_PATH: str = "/etc/strata/ap/hostapd.conf"

    # Optional SQLite persistence for ``SessionStore`` (Pi reboot survival).
    PERSIST_SESSIONS: bool = False
    SESSION_DB_PATH: str = "/var/lib/strata/sessions.db"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
