import asyncio
import time
from contextlib import asynccontextmanager, suppress
from datetime import UTC, datetime
from typing import Protocol
from uuid import uuid4

import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from strata_host.chain import ChainService
from strata_host.chatroom import ChatroomManager, ChatroomStore
from strata_host.chatroom import server as chatroom_server
from strata_host.config import Settings, get_settings
from strata_host.config_validate import ConfigurationError, validate_settings
from strata_host.discovery import DiscoveryAdvertiser
from strata_host.enforcer import EnforcerService
from strata_host.errors import register_exception_handlers
from strata_host.firewall.wg_routing import GuestRouting, RoutingError
from strata_host.host_config import HostConfigStore, Hotspot, apply_listing
from strata_host.firewall.wireguard import WireGuardError, WireGuardManager
from strata_host.logging_setup import get_logger, setup_logging
from strata_host.meter import MeterService
from strata_host.payments import PaymentService, Web3EscrowSettler
from strata_host.routes import admin as admin_routes
from strata_host.routes import health, host as host_routes, metering, portal, sessions
from strata_host.routes import rpc as rpc_routes
from strata_host.persistence import SessionPersistence
from strata_host.nft_bootstrap import (
    apply_strata_ruleset,
    delete_strata_table,
    enable_kernel_prereqs,
    host_owns_kernel,
    verify_nft_environment,
)
from strata_host.traffic import TrafficReader
from strata_host.store import SessionStore

APP_VERSION = "0.1.0"


class _ChainLifecycle(Protocol):
    async def start(self) -> None: ...
    async def stop(self) -> None: ...
    async def on_session_opened(self, session_id: str, guest_wallet: str) -> None: ...


async def _wg_route_watchdog(routing: GuestRouting, interval: float, logger) -> None:
    """Re-install guest routing if wg0 was bounced outside the host node."""
    while True:
        await asyncio.sleep(interval)
        try:
            await asyncio.to_thread(routing.ensure)
        except RoutingError as exc:
            logger.warning("wg_routing.repair_failed", error=str(exc))


def _build_payment_service(
    settings: Settings, store: SessionStore, enforcer: EnforcerService, logger
) -> PaymentService | None:
    """Checkpoints need the escrow address + host signing key; without them
    there is nothing on-chain to pay into."""
    if not (
        settings.CHAIN_ENABLED
        and settings.SESSION_ESCROW_ADDRESS
        and settings.HOST_SIGNING_PRIVATE_KEY
    ):
        if settings.CHAIN_ENABLED:
            logger.warning(
                "payments.disabled",
                reason="SESSION_ESCROW_ADDRESS and HOST_SIGNING_PRIVATE_KEY are both required",
            )
        return None
    settler = Web3EscrowSettler(settings) if settings.HOST_AUTO_SETTLE else None
    return PaymentService(settings, store, enforcer, settler)


def _build_chain_service(settings: Settings, store: SessionStore, enforcer: EnforcerService) -> _ChainLifecycle:
    """Pick the real listener when CHAIN_ENABLED + addresses are set,
    otherwise fall back to the no-op stub."""
    if (
        settings.CHAIN_ENABLED
        and settings.SESSION_ESCROW_ADDRESS
        and settings.HOST_WALLET_ADDRESS
    ):
        # Local import — the heavy web3 dependency only loads when the
        # listener is actually wanted. Tests that use the stub never pay
        # for it.
        from strata_host.chain_real import ChainListener  # noqa: WPS433

        # DEMO_MODE forces 0 confirmations so pay-and-connect feels snappy.
        confs = 0 if settings.DEMO_MODE else settings.CHAIN_CONFIRMATIONS
        return ChainListener(
            wss_url=settings.chain_rpc_url(),
            session_escrow_address=settings.SESSION_ESCROW_ADDRESS,
            host_address=settings.HOST_WALLET_ADDRESS,
            store=store,
            enforcer=enforcer,
            confirmations=confs,
        )
    return ChainService()


def create_app(
    settings: Settings | None = None,
    *,
    validate: bool = True,
) -> FastAPI:
    settings = settings or get_settings()
    # Fail loudly before accepting pending_payment sessions with no listener.
    # Tests that intentionally exercise the stub + pending_payment path may
    # pass validate=False (see conftest chain_enabled_settings).
    if validate:
        validate_settings(settings)
    setup_logging(settings.LOG_LEVEL)
    logger = get_logger("app")

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.settings = settings
        app.state.started_at = datetime.now(UTC)
        # Iteration 3 — settings the host changed from the app override .env.
        app.state.host_config_store = HostConfigStore(settings.HOST_CONFIG_PATH)
        saved = app.state.host_config_store.load()
        if saved:
            apply_listing(settings, saved)
            logger.info("host_config.applied", keys=sorted(saved))
        app.state.hotspot = Hotspot(settings)
        persistence: SessionPersistence | None = None
        if settings.PERSIST_SESSIONS:
            persistence = SessionPersistence(settings.SESSION_DB_PATH)
        app.state.store = SessionStore(
            nonce_ttl_seconds=3600,
            require_payment=settings.CHAIN_ENABLED,
            persistence=persistence,
        )
        if persistence is not None:
            await app.state.store.hydrate_from_persistence()
        app.state.enforcer = EnforcerService()
        await app.state.enforcer.start()
        verify_nft_environment(logger)
        apply_strata_ruleset(settings, logger)
        enable_kernel_prereqs(logger)
        app.state.chain = _build_chain_service(settings, app.state.store, app.state.enforcer)
        traffic_reader: TrafficReader | None = None
        # Real metering only where the host node really owns the kernel
        # (Linux + root + nft, not STRATA_NFT_FAKE) — the same condition as
        # the firewall. Anywhere else is a laptop-style demo run.
        if host_owns_kernel():
            traffic_reader = TrafficReader(settings.GUEST_IFACE)
        app.state.meter = MeterService(
            store=app.state.store,
            enforcer=app.state.enforcer,
            settings=settings,
            traffic_reader=traffic_reader,
        )

        # Phase F — bring the WireGuard exit tunnel up if requested.
        # The manager auto-falls into "fake mode" off-Linux / off-root, so
        # constructing it on a developer laptop is harmless.
        app.state.wg = WireGuardManager(settings)
        app.state.wg_routing = GuestRouting(settings)
        wg_route_watchdog: asyncio.Task | None = None
        if settings.WG_ENABLED:
            try:
                app.state.wg.bring_up()
            except WireGuardError as exc:
                # Don't crash the host node on a broken VPN. Routing below is
                # still installed: with the kill switch guests are blocked
                # until the tunnel comes up; with WG_FALLBACK_TO_WAN=true
                # they use the residential IP.
                logger.warning("wg.bring_up_failed", error=str(exc))
            try:
                app.state.wg_routing.apply()
            except RoutingError as exc:
                logger.error("wg_routing.apply_failed", error=str(exc))
            wg_route_watchdog = asyncio.create_task(
                _wg_route_watchdog(
                    app.state.wg_routing, settings.WG_ROUTE_CHECK_SECONDS, logger
                )
            )

        # Phase G — chatroom store + manager.
        app.state.chatroom_store = ChatroomStore(
            history_limit=settings.CHATROOM_HISTORY_LIMIT,
            history_ttl_hours=settings.CHATROOM_HISTORY_TTL_HOURS,
            persist=settings.CHATROOM_PERSIST,
            db_path=settings.CHATROOM_DB_PATH,
        )
        app.state.chatroom = ChatroomManager(app.state.chatroom_store)
        await app.state.chatroom.start()

        # Phase G — mDNS advertiser. Off by default off-Linux operators can
        # set MDNS_ENABLED=false to silence the bonjour traffic.
        app.state.discovery = DiscoveryAdvertiser(settings)
        try:
            await app.state.discovery.start()
        except Exception as exc:  # noqa: BLE001
            logger.warning("discovery.start_failed", error=type(exc).__name__)

        await app.state.chain.start()
        # Phase G — reconciliation pass before the live subscription
        # catches anything live. Survives the case where the Pi rebooted
        # mid-payment.
        if hasattr(app.state.chain, "reconcile"):
            try:
                await app.state.chain.reconcile()
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "chain.reconcile_unhandled",
                    error=type(exc).__name__,
                )
        await app.state.meter.start_loop()

        # Iteration 3 — periodic checkpoints + host-driven settlement.
        app.state.payments = _build_payment_service(
            settings, app.state.store, app.state.enforcer, logger
        )
        if app.state.payments is not None:
            await app.state.payments.start()

        metering_mode = (
            "real_conntrack"
            if traffic_reader is not None
            else ("demo_random" if settings.DEMO_MODE else "real_idle")
        )
        logger.info(
            "app.startup",
            demo_mode=settings.DEMO_MODE,
            metering_mode=metering_mode,
            allow_client_mac=settings.ALLOW_CLIENT_MAC,
            port=settings.PORT,
            chain_enabled=settings.CHAIN_ENABLED,
            wg_enabled=settings.WG_ENABLED,
            guest_iface=settings.GUEST_IFACE,
        )
        try:
            yield
        finally:
            if app.state.payments is not None:
                await app.state.payments.stop()
            await app.state.meter.stop_loop()
            await app.state.chain.stop()
            await app.state.chatroom.stop()
            await app.state.discovery.stop()
            await app.state.enforcer.stop()
            if wg_route_watchdog is not None:
                wg_route_watchdog.cancel()
                with suppress(asyncio.CancelledError):
                    await wg_route_watchdog
                app.state.wg_routing.remove()
            delete_strata_table(logger)
            try:
                app.state.wg.bring_down()
            except WireGuardError as exc:
                logger.warning("wg.bring_down_failed", error=str(exc))
            logger.info("app.shutdown")

    app = FastAPI(
        title="STRATA Host Node",
        version=APP_VERSION,
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.ALLOWED_ORIGINS,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def request_id_and_log(request: Request, call_next):
        request_id = str(uuid4())
        request.state.request_id = request_id
        started = time.perf_counter()
        response = await call_next(request)
        duration_ms = round((time.perf_counter() - started) * 1000, 2)
        response.headers["X-Request-Id"] = request_id
        logger.info(
            "http.request",
            request_id=request_id,
            method=request.method,
            path=request.url.path,
            status_code=response.status_code,
            duration_ms=duration_ms,
        )
        return response

    def get_store(request: Request) -> SessionStore:
        return request.app.state.store

    def get_enforcer(request: Request) -> EnforcerService:
        return request.app.state.enforcer

    def get_chain(request: Request) -> _ChainLifecycle:
        return request.app.state.chain

    def get_app_settings(_: Request) -> Settings:
        return settings

    def get_hotspot(request: Request) -> Hotspot:
        return request.app.state.hotspot

    def get_host_config_store(request: Request) -> HostConfigStore:
        return request.app.state.host_config_store

    def get_chatroom_store(request: Request) -> ChatroomStore:
        return request.app.state.chatroom_store

    def get_chatroom_manager(request: Request) -> ChatroomManager:
        return request.app.state.chatroom

    app.dependency_overrides[sessions._get_store] = get_store
    app.dependency_overrides[sessions._get_enforcer] = get_enforcer
    app.dependency_overrides[sessions._get_chain] = get_chain
    app.dependency_overrides[sessions._get_settings] = get_app_settings
    app.dependency_overrides[metering._get_store] = get_store
    app.dependency_overrides[chatroom_server._get_store] = get_chatroom_store
    app.dependency_overrides[chatroom_server._get_manager] = get_chatroom_manager
    app.dependency_overrides[admin_routes._get_settings] = get_app_settings
    app.dependency_overrides[admin_routes._get_chain] = get_chain
    app.dependency_overrides[admin_routes._get_enforcer] = get_enforcer
    app.dependency_overrides[admin_routes._get_store] = get_store
    app.dependency_overrides[admin_routes._get_hotspot] = get_hotspot
    app.dependency_overrides[admin_routes._get_host_config_store] = get_host_config_store
    app.dependency_overrides[host_routes._get_store] = get_store
    app.dependency_overrides[host_routes._get_settings] = get_app_settings
    app.dependency_overrides[portal._get_store] = get_store
    app.dependency_overrides[portal._get_enforcer] = get_enforcer
    app.dependency_overrides[portal._get_chain] = get_chain
    app.dependency_overrides[portal._get_settings] = get_app_settings
    app.dependency_overrides[rpc_routes._get_settings] = get_app_settings

    app.include_router(portal.router)
    app.include_router(host_routes.router)
    app.include_router(health.router)
    app.include_router(sessions.router)
    app.include_router(metering.router)
    app.include_router(chatroom_server.router)
    app.include_router(admin_routes.router)
    app.include_router(rpc_routes.router)
    register_exception_handlers(app)
    return app


app = create_app()


def run() -> None:
    settings = get_settings()
    uvicorn.run(
        "strata_host.main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=False,
    )


if __name__ == "__main__":
    run()
