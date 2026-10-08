import asyncio


async def test_metering_returns_latest_known_stats(client, start_payload):
    await client.post("/session/start", json=start_payload)
    await asyncio.sleep(0.1)
    response = await client.get("/metering/aa:bb:cc:dd:ee:ff")
    assert response.status_code == 200
    payload = response.json()
    assert payload["mac_address"] == "aa:bb:cc:dd:ee:ff"
    assert payload["bytes_total"] >= 0
    assert payload["status"] in {"active", "stopped"}


async def test_metering_unknown_mac_returns_404(client):
    response = await client.get("/metering/11:22:33:44:55:66")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "MAC_NOT_FOUND"

