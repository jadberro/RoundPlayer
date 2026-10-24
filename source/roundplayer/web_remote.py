#!/usr/bin/env python3
"""
Round Media Player - Mobile Web Remote (port 8080, :80 via the iptables redirect).

Deliberately thin: serves the static single-page app in ./web and transparently proxies
/api/* and /media/* to the playback manager on :8000, plus a WebSocket that relays the daemon's
telemetry socket. No hand-written per-endpoint proxies, so the remote can never drift from the API.
"""
import asyncio
import os
from pathlib import Path

import httpx
from fastapi import FastAPI, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, StreamingResponse
import uvicorn

PLAYBACK_MANAGER_URL = os.environ.get("PLAYBACK_MANAGER_URL", "http://127.0.0.1:8000")
TELEMETRY_SOCK = os.environ.get("ROUNDPLAYER_TELEMETRY_SOCK", "/tmp/roundplayer_telemetry.sock")
WEB_DIR = Path(__file__).resolve().parent / "web"
TELEMETRY_WS_HZ = 10  # phones don't need 60 Hz; the daemon broadcasts at 60

app = FastAPI(title="Round Media Player - Web Remote")
client = httpx.AsyncClient(base_url=PLAYBACK_MANAGER_URL, timeout=httpx.Timeout(30.0, connect=3.0))

HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization",
              "proxy-authenticate", "content-length", "host"}


@app.get("/")
async def index():
    return FileResponse(WEB_DIR / "index.html", headers={"Cache-Control": "no-cache"})


@app.get("/manifest.json")
async def manifest():
    return FileResponse(WEB_DIR / "manifest.json")


@app.get("/sw.js")
async def service_worker():
    return FileResponse(WEB_DIR / "sw.js", media_type="application/javascript", headers={"Cache-Control": "no-cache"})


@app.get("/static/{path:path}")
async def static_files(path: str):
    target = (WEB_DIR / path).resolve()
    if WEB_DIR.resolve() not in target.parents or not target.is_file():
        return Response(status_code=404)
    return FileResponse(target, headers={"Cache-Control": "no-cache"})


@app.api_route("/api/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
@app.api_route("/media/{path:path}", methods=["GET"])
async def proxy(request: Request, path: str):
    """Transparent reverse proxy to the playback manager (streams large media)."""
    url = request.url.path + (f"?{request.url.query}" if request.url.query else "")
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}
    body = await request.body()
    try:
        upstream = client.build_request(request.method, url, headers=headers, content=body)
        resp = await client.send(upstream, stream=True)
    except httpx.HTTPError as e:
        return Response(content=f'{{"error":"playback manager unreachable: {e}"}}', status_code=502,
                        media_type="application/json")
    resp_headers = {k: v for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP}

    async def body_iter():
        try:
            async for chunk in resp.aiter_raw():
                yield chunk
        finally:
            await resp.aclose()

    return StreamingResponse(body_iter(), status_code=resp.status_code, headers=resp_headers,
                             media_type=resp.headers.get("content-type"))


@app.websocket("/ws/telemetry")
async def ws_telemetry(ws: WebSocket):
    """Relay the daemon's unix-socket telemetry, throttled, and accept control commands back."""
    await ws.accept()
    reader = writer = None
    try:
        reader, writer = await asyncio.open_unix_connection(TELEMETRY_SOCK)
    except Exception as e:
        await ws.send_text('{"error":"telemetry unavailable: %s"}' % str(e).replace('"', "'"))
        await ws.close()
        return

    async def pump_out():
        last = 0.0
        interval = 1.0 / TELEMETRY_WS_HZ
        loop = asyncio.get_event_loop()
        while True:
            line = await reader.readline()
            if not line:
                break
            now = loop.time()
            if now - last < interval:
                continue
            last = now
            await ws.send_text(line.decode("utf-8", "replace").strip())

    async def pump_in():
        while True:
            msg = await ws.receive_text()  # {"action": "...", "value": ...}
            writer.write((msg.strip() + "\n").encode())
            await writer.drain()

    try:
        await asyncio.gather(pump_out(), pump_in())
    except (WebSocketDisconnect, asyncio.CancelledError, ConnectionError):
        pass
    except Exception as e:
        print(f"[WS] {e}")
    finally:
        if writer:
            writer.close()


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("ROUNDPLAYER_WEB_PORT", "8080")), log_level="warning")
