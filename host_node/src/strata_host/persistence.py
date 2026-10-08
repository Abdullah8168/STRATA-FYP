"""SQLite persistence for session rows (JSON blobs)."""

from __future__ import annotations

import json
from typing import Any


class SessionPersistence:
    def __init__(self, db_path: str) -> None:
        self._db_path = db_path

    async def _connect(self) -> Any:
        import aiosqlite

        conn = await aiosqlite.connect(self._db_path)
        conn.row_factory = aiosqlite.Row
        return conn

    async def init_schema(self) -> None:
        async with await self._connect() as db:
            await db.execute(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                    session_id TEXT PRIMARY KEY,
                    payload TEXT NOT NULL
                )
                """
            )
            await db.commit()

    async def save_payload(self, session_id: str, payload: dict[str, Any]) -> None:
        await self.init_schema()
        async with await self._connect() as db:
            await db.execute(
                "INSERT OR REPLACE INTO sessions (session_id, payload) VALUES (?, ?)",
                (session_id, json.dumps(payload)),
            )
            await db.commit()

    async def load_all_payloads(self) -> list[dict[str, Any]]:
        await self.init_schema()
        async with await self._connect() as db:
            cur = await db.execute("SELECT payload FROM sessions")
            rows = await cur.fetchall()
        out: list[dict[str, Any]] = []
        for row in rows:
            try:
                out.append(json.loads(row["payload"]))
            except json.JSONDecodeError:
                continue
        return out
