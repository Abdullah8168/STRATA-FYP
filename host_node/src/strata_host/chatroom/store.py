"""Phase G — chatroom message log.

Memory-only by default. When ``CHATROOM_PERSIST`` is true, mirrors writes
to a SQLite file (so the message history survives a Pi reboot) but reads
are still served from RAM for latency.
"""

from __future__ import annotations

import asyncio
import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from strata_host.chatroom.models import ChatMessage


class ChatroomStore:
    def __init__(
        self,
        *,
        history_limit: int = 500,
        history_ttl_hours: int = 24,
        persist: bool = False,
        db_path: str | None = None,
    ) -> None:
        self._lock = asyncio.Lock()
        self._messages: list[ChatMessage] = []
        self._history_limit = history_limit
        self._history_ttl = timedelta(hours=history_ttl_hours)
        self._persist = persist
        self._db_path = Path(db_path) if db_path else None
        self._db: sqlite3.Connection | None = None
        if self._persist and self._db_path:
            self._init_sqlite()

    def _init_sqlite(self) -> None:
        assert self._db_path is not None
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(self._db_path), check_same_thread=False)
        self._db.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                from_name TEXT NOT NULL,
                client_id TEXT,
                text TEXT,
                ts_iso TEXT NOT NULL,
                lat REAL,
                lon REAL
            )
            """
        )
        self._db.commit()
        self._hydrate_from_sqlite()

    def _hydrate_from_sqlite(self) -> None:
        if self._db is None:
            return
        from strata_host.chatroom.models import ChatMessage  # avoid cycle

        cutoff = datetime.now(UTC) - self._history_ttl
        rows = self._db.execute(
            """
            SELECT id, type, from_name, client_id, text, ts_iso, lat, lon
              FROM messages
             WHERE ts_iso >= ?
             ORDER BY ts_iso ASC
             LIMIT ?
            """,
            (cutoff.isoformat(), self._history_limit),
        ).fetchall()
        for row in rows:
            self._messages.append(
                ChatMessage(
                    id=row[0],
                    type=row[1],
                    **{"from": row[2]},  # alias workaround
                    client_id=row[3],
                    text=row[4],
                    ts=datetime.fromisoformat(row[5]),
                    lat=row[6],
                    lon=row[7],
                )
            )

    async def append(self, msg: "ChatMessage") -> None:
        async with self._lock:
            self._messages.append(msg)
            now = datetime.now(UTC)
            cutoff = now - self._history_ttl
            self._messages = [
                m for m in self._messages
                if (m.ts.tzinfo and m.ts > cutoff) or m.ts.replace(tzinfo=UTC) > cutoff
            ][-self._history_limit:]
            if self._db is not None:
                self._db.execute(
                    "INSERT OR REPLACE INTO messages "
                    "(id, type, from_name, client_id, text, ts_iso, lat, lon) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        str(msg.id),
                        msg.type,
                        msg.from_,
                        str(msg.client_id) if msg.client_id else None,
                        msg.text,
                        msg.ts.isoformat(),
                        msg.lat,
                        msg.lon,
                    ),
                )
                self._db.commit()

    async def history(self, since: datetime | None = None) -> list["ChatMessage"]:
        async with self._lock:
            if since is None:
                return list(self._messages)
            since_aware = since if since.tzinfo else since.replace(tzinfo=UTC)
            return [
                m for m in self._messages
                if (m.ts if m.ts.tzinfo else m.ts.replace(tzinfo=UTC)) >= since_aware
            ]

    async def close(self) -> None:
        if self._db is not None:
            self._db.close()
            self._db = None
