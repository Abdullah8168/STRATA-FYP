"""Walled-garden JSON-RPC relay (POST /rpc) for unpaid guests."""

from __future__ import annotations

import json

import aiohttp
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from strata_host.config import Settings
from strata_host.main import create_app
from strata_host.routes import rpc

UPSTREAM = "http://chain.example:8545"


class Upstream:
    def __init__(self) -> None:
        self.calls: list[tuple[str, bytes]] = []
        self.fail = False

    async def __call__(self, url: str, body: bytes) -> tuple[int, bytes]:
        if self.fail:
            raise aiohttp.ClientConnectionError("down")
        self.calls.append((url, body))
        req = json.loads(body)
        reply = (
            [{"jsonrpc": "2.0", "id": r["id"], "result": "0x7a69"} for r in req]
            if isinstance(req, list)
            else {"jsonrpc": "2.0", "id": req["id"], "result": "0x7a69"}
        )
        return 200, json.dumps(reply).encode()


async def _client(settings: Settings):
    app = create_app(settings, validate=False)
    ctx = app.router.lifespan_context(app)
    await ctx.__aenter__()
    client = AsyncClient(transport=ASGITransport(app=app), base_url="http://pi")
    return app, ctx, client


@pytest_asyncio.fixture
async def relay(test_settings, monkeypatch):
    upstream = Upstream()
    monkeypatch.setattr(rpc, "_forward", upstream)
    settings = test_settings.model_copy(
        update={"CHAIN_ENABLED": True, "CHAIN_RPC_URL": UPSTREAM}
    )
    _, ctx, client = await _client(settings)
    try:
        yield client, upstream
    finally:
        await client.aclose()
        await ctx.__aexit__(None, None, None)


def _req(method: str, rid: int = 1, params: list | None = None) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "method": method, "params": params or []}


async def test_allowed_call_is_forwarded_verbatim(relay):
    client, upstream = relay
    body = _req("eth_sendRawTransaction", 7, ["0xdeadbeef"])
    r = await client.post("/rpc", json=body)
    assert r.status_code == 200
    assert r.json() == {"jsonrpc": "2.0", "id": 7, "result": "0x7a69"}
    assert upstream.calls[0][0] == UPSTREAM
    assert json.loads(upstream.calls[0][1]) == body


async def test_payment_flow_methods_are_all_allowed(relay):
    client, upstream = relay
    for m in ("eth_chainId", "eth_getBalance", "eth_call", "eth_estimateGas", "eth_gasPrice",
              "eth_getTransactionCount", "eth_sendRawTransaction", "eth_getTransactionReceipt",
              "eth_getLogs", "eth_blockNumber"):
        assert (await client.post("/rpc", json=_req(m))).json()["result"] == "0x7a69", m
    assert len(upstream.calls) == 10


async def test_other_methods_are_refused_without_reaching_the_node(relay):
    client, upstream = relay
    for m in ("eth_accounts", "eth_sendTransaction", "personal_unlockAccount",
              "hardhat_setBalance", "debug_traceTransaction", "admin_peers", None):
        r = await client.post("/rpc", json=_req(m, 3))
        err = r.json()["error"]
        assert err["code"] == -32601 and r.json()["id"] == 3, m
    assert upstream.calls == []


async def test_batch_with_one_forbidden_method_is_refused_entirely(relay):
    client, upstream = relay
    r = await client.post("/rpc", json=[_req("eth_chainId", 1), _req("eth_sendTransaction", 2)])
    assert r.json()["error"]["code"] == -32601
    assert upstream.calls == []


async def test_allowed_batch_is_forwarded(relay):
    client, upstream = relay
    r = await client.post("/rpc", json=[_req("eth_chainId", 1), _req("eth_blockNumber", 2)])
    assert [x["id"] for x in r.json()] == [1, 2]


async def test_malformed_and_oversized_requests(relay):
    client, upstream = relay
    r = await client.post("/rpc", content=b"{not json", headers={"Content-Type": "application/json"})
    assert r.json()["error"]["code"] == -32700
    r = await client.post("/rpc", json=[_req("eth_chainId", i) for i in range(rpc.MAX_BATCH + 1)])
    assert r.json()["error"]["code"] == -32600
    r = await client.post("/rpc", content=b" " * (rpc.MAX_BODY_BYTES + 1))
    assert r.status_code == 413
    assert upstream.calls == []


async def test_node_down_gives_json_rpc_error(relay):
    client, upstream = relay
    upstream.fail = True
    r = await client.post("/rpc", json=_req("eth_chainId", 9))
    assert r.status_code == 502
    assert r.json()["id"] == 9 and r.json()["error"]["code"] == -32000


async def test_relay_off_when_chain_disabled(test_settings, monkeypatch):
    upstream = Upstream()
    monkeypatch.setattr(rpc, "_forward", upstream)
    _, ctx, client = await _client(test_settings)  # CHAIN_ENABLED=False
    try:
        r = await client.post("/rpc", json=_req("eth_chainId"))
    finally:
        await client.aclose()
        await ctx.__aexit__(None, None, None)
    assert r.status_code == 404
    assert upstream.calls == []
