# Chatroom software verification (no Pi / no WAN)

## Endpoint

- WebSocket: `ws://<host>:8080/ws/chatroom`
- REST SOS: `POST /chatroom/sos`
- History: `GET /chatroom/messages?since=...`

Designed for **guest LAN** operation — WAN is not required.

## Automated evidence

```bash
cd host_node && PYTHONPATH=src pytest -q tests/test_chatroom.py
```

Covers: join/history, two-client message delivery, bidirectional exchange,
SOS broadcast, reconnect+history, rate limits.

## Manual two-client software demo

With host_node running (`just host-run`):

```bash
# Client A
websocat ws://127.0.0.1:8080/ws/chatroom
# send: {"type":"join","display_name":"alice","client_id":"a1"}

# Client B (second terminal)
websocat ws://127.0.0.1:8080/ws/chatroom
# send: {"type":"join","display_name":"bob","client_id":"b1"}
# then msg frames: {"type":"msg","text":"hello"}
```

## Requires two phones on Pi AP

WAN-down emergency demo with physical devices — **hardware verification remaining**.
