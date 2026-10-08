import asyncio
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING, Any
from uuid import UUID, uuid4

from strata_host.config import Settings

from strata_host.errors import (
    MacAlreadyActive,
    NonceReplay,
    SessionNotActive,
    SessionNotFound,
)
from strata_host.models import SessionResponse, StartSessionRequest

if TYPE_CHECKING:
    from strata_host.persistence import SessionPersistence


def session_id_to_ref(session_id: UUID) -> str:
    """Deterministic 32-byte ref derived from a uuid v4.

    The uuid is 16 bytes; we left-pad with 16 zero bytes so the result
    fits Solidity's bytes32. The Flutter app passes this directly into
    SessionEscrow.openSession(...) and the contract emits it back in the
    SessionOpened event so the host node can match.
    """
    return "0x" + ("00" * 16) + session_id.hex


@dataclass
class SessionRecord:
    session_id: UUID
    status: str  # "pending_payment" | "active" | "stopped"
    mac_address: str
    guest_wallet_address: str
    host_wallet_address: str
    session_ref: str
    started_at: datetime
    expires_at: datetime
    quota_bytes: int
    bytes_in: int
    bytes_out: int
    stop_reason: str | None = None
    stopped_at: datetime | None = None
    tx_hash: str | None = None
    chain_session_id: int | None = None
    price_per_gb_wei: str = "0"
    escrow_amount_wei: int | None = None
    meter_nf_baseline_in: int = 0
    meter_nf_baseline_out: int = 0
    meter_baseline_ready: bool = False
    host_settlement_sig: str | None = None
    settlement_bytes_consumed: int | None = None
    settlement_quota_bytes: int | None = None
    receipt_hash: str | None = None
    # Iteration 3 — periodic micropayment checkpoints. The signature is a
    # valid closeSession receipt for checkpoint_bytes and stays host-side:
    # the contract has no receipt nonce, so handing guests a stream of
    # receipts would let them settle with the oldest (cheapest) one.
    checkpoint_bytes: int | None = None
    checkpoint_sig: str | None = None
    checkpoint_at: datetime | None = None
    checkpoint_count: int = 0
    # Host-side on-chain settlement:
    #   None → "settled" (router's closeSession mined)
    #        → "closed_by_guest" (guest settled or disputed first)
    #        → "failed" (gave up after SETTLE_MAX_ATTEMPTS)
    settlement_status: str | None = None
    settlement_tx_hash: str | None = None
    settlement_attempts: int = 0
    settlement_error: str | None = None
    host_payment_wei: int | None = None

    @property
    def bytes_used(self) -> int:
        return self.bytes_in + self.bytes_out

    def accrued_payment_wei(self) -> int | None:
        """What the guest owes the host so far, using closeSession's math
        (amount * min(bytes, quota) / quota). None until the escrow amount
        is known."""
        if self.escrow_amount_wei is None or self.quota_bytes <= 0:
            return None
        capped = min(self.bytes_used, self.quota_bytes)
        return (int(self.escrow_amount_wei) * capped) // self.quota_bytes

    def to_response(self) -> SessionResponse:
        return SessionResponse(
            session_id=self.session_id,
            status=self.status,  # type: ignore[arg-type]
            mac_address=self.mac_address,
            guest_wallet_address=self.guest_wallet_address,
            host_wallet_address=self.host_wallet_address,
            started_at=self.started_at,
            expires_at=self.expires_at,
            bytes_used=self.bytes_used,
            quota_bytes=self.quota_bytes,
            metering_ws_url=f"/ws/metering/{self.session_id}",
            session_ref=self.session_ref,
            tx_hash=self.tx_hash,
            chain_session_id=self.chain_session_id,
            stop_reason=self.stop_reason,
            stopped_at=self.stopped_at,
            host_settlement_sig=self.host_settlement_sig,
            settlement_bytes_consumed=self.settlement_bytes_consumed,
            settlement_quota_bytes=self.settlement_quota_bytes,
            receipt_hash=self.receipt_hash,
            accrued_payment_wei=(
                str(accrued) if (accrued := self.accrued_payment_wei()) is not None else None
            ),
            checkpoint_bytes=self.checkpoint_bytes,
            checkpoint_at=self.checkpoint_at,
            settlement_status=self.settlement_status,
            settlement_tx_hash=self.settlement_tx_hash,
            bytes_in=self.bytes_in,
            bytes_out=self.bytes_out,
        )

    def to_persist_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["session_id"] = str(self.session_id)
        d["started_at"] = self.started_at.isoformat()
        d["expires_at"] = self.expires_at.isoformat()
        d["stopped_at"] = self.stopped_at.isoformat() if self.stopped_at else None
        d["checkpoint_at"] = self.checkpoint_at.isoformat() if self.checkpoint_at else None
        return d

    @staticmethod
    def from_persist_dict(d: dict[str, Any]) -> "SessionRecord":
        def _parse_dt(s: str | None) -> datetime | None:
            if not s:
                return None
            if s.endswith("Z"):
                s = s[:-1] + "+00:00"
            return datetime.fromisoformat(s)

        sid = UUID(d["session_id"])
        started = _parse_dt(d["started_at"]) or datetime.now(UTC)
        expires = _parse_dt(d["expires_at"]) or started
        stopped = _parse_dt(d.get("stopped_at"))
        return SessionRecord(
            session_id=sid,
            status=str(d["status"]),
            mac_address=str(d["mac_address"]).lower(),
            guest_wallet_address=str(d["guest_wallet_address"]),
            host_wallet_address=str(d["host_wallet_address"]),
            session_ref=str(d["session_ref"]),
            started_at=started,
            expires_at=expires,
            quota_bytes=int(d["quota_bytes"]),
            bytes_in=int(d.get("bytes_in") or 0),
            bytes_out=int(d.get("bytes_out") or 0),
            stop_reason=d.get("stop_reason"),
            stopped_at=stopped,
            tx_hash=d.get("tx_hash"),
            chain_session_id=d.get("chain_session_id"),
            price_per_gb_wei=str(d.get("price_per_gb_wei") or "0"),
            escrow_amount_wei=d.get("escrow_amount_wei"),
            meter_nf_baseline_in=int(d.get("meter_nf_baseline_in") or 0),
            meter_nf_baseline_out=int(d.get("meter_nf_baseline_out") or 0),
            meter_baseline_ready=bool(d.get("meter_baseline_ready")),
            host_settlement_sig=d.get("host_settlement_sig"),
            settlement_bytes_consumed=d.get("settlement_bytes_consumed"),
            settlement_quota_bytes=d.get("settlement_quota_bytes"),
            receipt_hash=d.get("receipt_hash"),
            checkpoint_bytes=d.get("checkpoint_bytes"),
            checkpoint_sig=d.get("checkpoint_sig"),
            checkpoint_at=_parse_dt(d.get("checkpoint_at")),
            checkpoint_count=int(d.get("checkpoint_count") or 0),
            settlement_status=d.get("settlement_status"),
            settlement_tx_hash=d.get("settlement_tx_hash"),
            settlement_attempts=int(d.get("settlement_attempts") or 0),
            settlement_error=d.get("settlement_error"),
            host_payment_wei=d.get("host_payment_wei"),
        )


class SessionStore:
    def __init__(
        self,
        nonce_ttl_seconds: int = 3600,
        *,
        require_payment: bool = False,
        persistence: "SessionPersistence | None" = None,
    ) -> None:
        self._lock = asyncio.Lock()
        self._nonce_ttl = timedelta(seconds=nonce_ttl_seconds)
        self._require_payment = require_payment
        self._persistence = persistence
        self._sessions: dict[UUID, SessionRecord] = {}
        self._active_mac_index: dict[str, UUID] = {}
        self._mac_history: dict[str, list[UUID]] = {}
        self._nonce_index: dict[tuple[str, str], datetime] = {}
        self._ref_index: dict[str, UUID] = {}

    async def _maybe_persist(self, record: SessionRecord) -> None:
        if self._persistence is None:
            return
        await self._persistence.save_payload(
            str(record.session_id),
            record.to_persist_dict(),
        )

    async def hydrate_from_persistence(self) -> None:
        if self._persistence is None:
            return
        rows = await self._persistence.load_all_payloads()
        async with self._lock:
            for d in rows:
                try:
                    rec = SessionRecord.from_persist_dict(d)
                except (KeyError, ValueError, TypeError):
                    continue
                self._sessions[rec.session_id] = rec
                self._ref_index[rec.session_ref.lower()] = rec.session_id
                self._mac_history.setdefault(rec.mac_address, []).append(rec.session_id)
                if rec.status == "active":
                    self._active_mac_index[rec.mac_address] = rec.session_id

    async def create_session(
        self,
        payload: StartSessionRequest,
        ttl_seconds: int,
    ) -> SessionRecord:
        now = datetime.now(UTC)
        key = (payload.guest_wallet_address.lower(), str(payload.nonce))
        async with self._lock:
            self._prune_nonce_index(now)
            if key in self._nonce_index:
                raise NonceReplay("Nonce was already used recently.")
            if payload.mac_address in self._active_mac_index:
                raise MacAlreadyActive("MAC address already has an active session.")

            session_id = uuid4()
            initial_status = "pending_payment" if self._require_payment else "active"
            record = SessionRecord(
                session_id=session_id,
                status=initial_status,
                mac_address=payload.mac_address,
                guest_wallet_address=payload.guest_wallet_address,
                host_wallet_address=payload.host_wallet_address,
                session_ref=session_id_to_ref(session_id),
                started_at=now,
                expires_at=now + timedelta(seconds=ttl_seconds),
                quota_bytes=payload.quota_bytes,
                bytes_in=0,
                bytes_out=0,
                tx_hash=payload.tx_hash,
                price_per_gb_wei=payload.price_per_gb_wei,
            )
            self._sessions[session_id] = record
            self._mac_history.setdefault(payload.mac_address, []).append(session_id)
            self._ref_index[record.session_ref.lower()] = session_id
            self._nonce_index[key] = now
            if initial_status == "active":
                self._active_mac_index[payload.mac_address] = session_id
            await self._maybe_persist(record)
            return record

    async def get_by_session_id(self, session_id: UUID) -> SessionRecord | None:
        async with self._lock:
            return self._sessions.get(session_id)

    async def get_by_mac_address(self, mac_address: str) -> SessionRecord | None:
        async with self._lock:
            active_id = self._active_mac_index.get(mac_address)
            if active_id is not None:
                return self._sessions.get(active_id)

            history = self._mac_history.get(mac_address, [])
            if not history:
                return None
            return self._sessions.get(history[-1])

    async def get_by_ref(self, session_ref: str) -> SessionRecord | None:
        normalized = session_ref.lower()
        async with self._lock:
            sid = self._ref_index.get(normalized)
            if sid is None:
                return None
            return self._sessions.get(sid)

    async def mark_paid(
        self,
        session_id: UUID,
        chain_session_id: int,
        tx_hash: str,
        escrow_amount_wei: int | None = None,
    ) -> SessionRecord:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                raise SessionNotFound("Session does not exist.")
            if record.status == "stopped":
                raise SessionNotActive("Session is already stopped; cannot mark paid.")
            record.chain_session_id = chain_session_id
            record.tx_hash = tx_hash
            if escrow_amount_wei is not None:
                record.escrow_amount_wei = int(escrow_amount_wei)
            if record.status == "pending_payment":
                record.status = "active"
                record.started_at = datetime.now(UTC)
                record.meter_baseline_ready = False
                record.meter_nf_baseline_in = 0
                record.meter_nf_baseline_out = 0
                self._active_mac_index[record.mac_address] = session_id
            out = record
            await self._maybe_persist(out)
            return out

    async def record_payment_hint(self, session_id: UUID, tx_hash: str) -> SessionRecord:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                raise SessionNotFound("Session does not exist.")
            record.tx_hash = tx_hash
            await self._maybe_persist(record)
            return record

    async def stop_session(self, session_id: UUID, reason: str) -> SessionRecord:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                raise SessionNotFound("Session does not exist.")
            if record.status == "stopped":
                raise SessionNotActive("Session is not active.")

            record.status = "stopped"
            record.stop_reason = reason
            record.stopped_at = datetime.now(UTC)
            if self._active_mac_index.get(record.mac_address) == session_id:
                self._active_mac_index.pop(record.mac_address, None)
            await self._maybe_persist(record)
            return record

    async def apply_settlement_fields(self, session_id: UUID, settings: Settings) -> None:
        from strata_host.settlement import maybe_sign_stop

        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None or record.status != "stopped":
                return
            rh, sig, sb, sq = maybe_sign_stop(
                settings,
                chain_session_id=record.chain_session_id,
                bytes_used=record.bytes_used,
                quota_bytes=record.quota_bytes,
            )
            if sig is not None:
                record.host_settlement_sig = sig
            if sb is not None:
                record.settlement_bytes_consumed = sb
            if sq is not None:
                record.settlement_quota_bytes = sq
            if rh is not None:
                record.receipt_hash = rh
            await self._maybe_persist(record)

    async def increment_usage(
        self, session_id: UUID, bytes_in: int, bytes_out: int
    ) -> SessionRecord | None:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None or record.status != "active":
                return None
            record.bytes_in += max(0, bytes_in)
            record.bytes_out += max(0, bytes_out)
            await self._maybe_persist(record)
            return record

    async def set_meter_nf_baseline(
        self,
        session_id: UUID,
        abs_in: int,
        abs_out: int,
    ) -> SessionRecord | None:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None or record.status != "active":
                return None
            if not record.meter_baseline_ready:
                record.meter_nf_baseline_in = abs_in
                record.meter_nf_baseline_out = abs_out
                record.meter_baseline_ready = True
                await self._maybe_persist(record)
            return record

    async def record_checkpoint(
        self, session_id: UUID, *, bytes_consumed: int, signature: str, at: datetime
    ) -> SessionRecord | None:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                return None
            record.checkpoint_bytes = bytes_consumed
            record.checkpoint_sig = signature
            record.checkpoint_at = at
            record.checkpoint_count += 1
            await self._maybe_persist(record)
            return record

    async def list_unsettled_chain_sessions(self) -> list[SessionRecord]:
        """Stopped, on-chain sessions the router has not finished settling."""
        async with self._lock:
            return [
                r
                for r in self._sessions.values()
                if r.status == "stopped"
                and r.chain_session_id is not None
                and r.settlement_status is None
            ]

    async def update_settlement(
        self,
        session_id: UUID,
        *,
        status: str | None = None,
        tx_hash: str | None = None,
        error: str | None = None,
        host_payment_wei: int | None = None,
        count_attempt: bool = False,
    ) -> SessionRecord | None:
        async with self._lock:
            record = self._sessions.get(session_id)
            if record is None:
                return None
            if status is not None:
                record.settlement_status = status
            if tx_hash is not None:
                record.settlement_tx_hash = tx_hash
            if host_payment_wei is not None:
                record.host_payment_wei = host_payment_wei
            record.settlement_error = error
            if count_attempt:
                record.settlement_attempts += 1
            await self._maybe_persist(record)
            return record

    async def list_active_sessions(self) -> list[SessionRecord]:
        async with self._lock:
            return [
                self._sessions[sid]
                for sid in self._active_mac_index.values()
                if self._sessions[sid].status == "active"
            ]

    async def list_recent_sessions(self, limit: int = 200) -> list[SessionRecord]:
        async with self._lock:
            rows = list(self._sessions.values())
        rows.sort(key=lambda r: r.started_at, reverse=True)
        return rows[:limit]

    def _prune_nonce_index(self, now: datetime) -> None:
        stale = [k for k, seen_at in self._nonce_index.items() if now - seen_at > self._nonce_ttl]
        for key in stale:
            self._nonce_index.pop(key, None)
