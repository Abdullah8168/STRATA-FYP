"""Phase A stub. Kept as the no-op fallback when CHAIN_ENABLED is false.

When CHAIN_ENABLED=true, ``main.create_app`` instantiates
``strata_host.chain_real.ChainListener`` instead and this stub is never
started.
"""

from strata_host.logging_setup import get_logger


class ChainService:
    """No-op chain service used when on-chain settlement is disabled.

    Logs a single ``chain.listener_disabled`` line on start so operators
    have an obvious signal in logs when reviewing why no sessions are
    being authorised.
    """

    def __init__(self) -> None:
        self._logger = get_logger("chain")
        self._running = False

    async def start(self) -> None:
        self._running = True
        self._logger.info("chain.listener_disabled")

    async def stop(self) -> None:
        self._running = False
        self._logger.info("chain.stop")

    async def on_session_opened(self, session_id: str, guest_wallet: str) -> None:
        self._logger.info(
            "chain.on_session_opened",
            session_id=session_id,
            guest_wallet=guest_wallet,
        )
