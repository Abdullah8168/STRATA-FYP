"""Walled-garden JSON-RPC relay for guests who have not paid yet.

A guest must send ``approve`` + ``openSession`` transactions *before* the
firewall admits them, but unpaid guests have no internet. The portal port
(``PORTAL_PORT`` on the AP address) is reachable without paying, so the
host node relays blockchain JSON-RPC from there to ``CHAIN_RPC_URL``.

Only the methods a wallet needs to pay and to read results are relayed, so
the relay can't be used as a general proxy. Point the app at it with
``--dart-define=RPC_URL=http://192.168.50.1:8080/rpc``.
"""

from __future__ import annotations

import json
from typing import Any

import aiohttp
from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response

from strata_host.config import Settings
from strata_host.logging_setup import get_logger

router = APIRouter(tags=["rpc"])
_logger = get_logger("rpc_relay")

ALLOWED_METHODS = frozenset({
    "eth_chainId",
    "net_version",
    "eth_blockNumber",
    "eth_getBalance",
    "eth_getCode",
    "eth_call",
    "eth_estimateGas",
    "eth_gasPrice",
    "eth_maxPriorityFeePerGas",
    "eth_feeHistory",
    "eth_getTransactionCount",
    "eth_sendRawTransaction",
    "eth_getTransactionByHash",
    "eth_getTransactionReceipt",
    "eth_getBlockByNumber",
    "eth_getLogs",
})
MAX_BODY_BYTES = 128 * 1024
MAX_BATCH = 20
UPSTREAM_TIMEOUT_SECONDS = 15


def _get_settings() -> Settings:
    raise RuntimeError("Dependency override not configured.")


def _error(code: int, message: str, request_id: Any = None, status: int = 200) -> JSONResponse:
    return JSONResponse(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}},
        status_code=status,
    )


async def _forward(upstream: str, body: bytes) -> tuple[int, bytes]:
    timeout = aiohttp.ClientTimeout(total=UPSTREAM_TIMEOUT_SECONDS)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.post(
            upstream, data=body, headers={"Content-Type": "application/json"}
        ) as resp:
            return resp.status, await resp.read()


@router.post("/rpc")
async def relay(request: Request, settings: Settings = Depends(_get_settings)) -> Response:
    if not (settings.CHAIN_ENABLED and settings.RPC_RELAY_ENABLED):
        return _error(-32000, "RPC relay is disabled on this host", status=404)
    upstream = settings.chain_rpc_url()
    if not upstream.startswith(("http://", "https://")):
        return _error(-32000, "RPC relay needs an http(s) CHAIN_RPC_URL", status=503)

    body = await request.body()
    if len(body) > MAX_BODY_BYTES:
        return _error(-32600, "request too large", status=413)
    try:
        payload = json.loads(body)
    except ValueError:
        return _error(-32700, "parse error")

    calls = payload if isinstance(payload, list) else [payload]
    if not calls or len(calls) > MAX_BATCH or not all(isinstance(c, dict) for c in calls):
        return _error(-32600, "invalid request")
    for call in calls:
        method = call.get("method")
        if method not in ALLOWED_METHODS:
            _logger.warning("rpc_relay.method_blocked", method=str(method)[:64])
            return _error(-32601, f"method not allowed by STRATA relay: {method}", call.get("id"))

    try:
        status, content = await _forward(upstream, body)
    except (aiohttp.ClientError, TimeoutError) as exc:
        _logger.warning("rpc_relay.upstream_failed", error=type(exc).__name__)
        first_id = calls[0].get("id") if len(calls) == 1 else None
        return _error(-32000, "blockchain node unreachable", first_id, status=502)
    _log_forwarded(calls, status, content)
    return Response(content=content, status_code=status, media_type="application/json")


def _log_forwarded(calls: list[dict], status: int, content: bytes) -> None:
    """One line per relayed call: method + the node's error, if any."""
    try:
        replies = json.loads(content)
    except ValueError:
        replies = None
    if not isinstance(replies, list):
        replies = [replies] * len(calls)
    for call, reply in zip(calls, replies):
        err = reply.get("error") if isinstance(reply, dict) else None
        _logger.info(
            "rpc_relay.forwarded",
            method=call.get("method"),
            upstream_status=status,
            error=(err.get("message", "")[:160] if isinstance(err, dict) else None),
        )
