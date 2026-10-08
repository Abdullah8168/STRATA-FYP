"""Phase G — LAN-only emergency chatroom.

Submodules:
- ``models``: pydantic envelopes for inbound/outbound frames.
- ``store``:  in-memory + optional SQLite history store.
- ``server``: FastAPI router + ChatroomManager that owns the connected
  websockets and the broadcast fanout.

The chatroom intentionally does not require authentication — the design
goal is "any guest already on the AP can reach it, even before they've
paid for internet, and even when the WAN uplink is dead." That's what
makes it useful for emergencies.
"""

from strata_host.chatroom.models import ChatFrame, ChatMessage, Presence
from strata_host.chatroom.server import ChatroomManager, router
from strata_host.chatroom.store import ChatroomStore

__all__ = [
    "ChatFrame",
    "ChatMessage",
    "ChatroomManager",
    "ChatroomStore",
    "Presence",
    "router",
]
