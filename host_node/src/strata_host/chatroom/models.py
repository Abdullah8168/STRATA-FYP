"""Phase G chatroom envelopes."""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

FrameType = Literal["join", "msg", "sos", "location", "ping"]
ServerFrameType = Literal[
    "history", "msg", "sos", "system", "location", "presence", "error"
]


class JoinFrame(BaseModel):
    type: Literal["join"]
    display_name: str = Field(min_length=1, max_length=64)
    client_id: UUID
    lat: float | None = None
    lon: float | None = None


class TextFrame(BaseModel):
    type: Literal["msg"]
    text: str = Field(min_length=1, max_length=2000)


class SosFrame(BaseModel):
    type: Literal["sos"]
    text: str = Field(min_length=0, max_length=2000)
    lat: float | None = None
    lon: float | None = None


class LocationFrame(BaseModel):
    type: Literal["location"]
    lat: float
    lon: float


class ChatMessage(BaseModel):
    """The server-stamped envelope every connected client receives."""

    type: ServerFrameType
    id: UUID
    from_: str = Field(alias="from", default="system")
    client_id: UUID | None = None
    text: str | None = None
    ts: datetime
    lat: float | None = None
    lon: float | None = None

    model_config = {"populate_by_name": True}


class Presence(BaseModel):
    type: Literal["presence"] = "presence"
    users: list[dict]
    ts: datetime


# Discriminated alias for convenience.
ChatFrame = JoinFrame | TextFrame | SosFrame | LocationFrame
