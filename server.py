"""
Multi-Account P&L Dashboard Backend
------------------------------------
Receives real-time account snapshots (balance/equity/floating P&L/positions)
from MT4/MT5 reporter EAs via HTTP POST, and pushes live updates to any
connected dashboard clients over WebSocket.

Run:
    pip install fastapi uvicorn --break-system-packages
    python3 server.py

Then point your browser (or iPhone Safari) at:
    http://<vps-ip>:8000/

EAs POST to:
    http://<vps-ip>:8000/api/report
"""

import json
import os
import time
from typing import Dict, List

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
API_KEY = os.environ.get("PNL_API_KEY", "changeme123")   # set a real key on your VPS
STALE_AFTER_SECONDS = 15                                  # dashboard marks account "offline" if no update in this long
HERE = os.path.dirname(os.path.abspath(__file__))

app = FastAPI(title="PnL Dashboard")

# In-memory store: account_id -> latest snapshot dict
accounts: Dict[str, dict] = {}


# ---------------------------------------------------------------------------
# WebSocket connection manager
# ---------------------------------------------------------------------------
class ConnectionManager:
    def __init__(self):
        self.active: List[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)
        # send full current state on connect
        await ws.send_text(json.dumps({"type": "full_state", "accounts": accounts}))

    def disconnect(self, ws: WebSocket):
        if ws in self.active:
            self.active.remove(ws)

    async def broadcast(self, message: dict):
        dead = []
        for ws in self.active:
            try:
                await ws.send_text(json.dumps(message))
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws)


manager = ConnectionManager()


# ---------------------------------------------------------------------------
# REST: EA -> server
# ---------------------------------------------------------------------------
@app.post("/api/report")
async def report(request: Request):
    try:
        payload = await request.json()
    except Exception as e:
        body = await request.body()
        print(f"PnL report: failed to parse JSON: {e} | raw body: {body[:500]!r}")
        raise HTTPException(status_code=400, detail="malformed JSON payload")

    if payload.get("api_key") != API_KEY:
        raise HTTPException(status_code=401, detail="invalid api_key")

    account_id = str(payload.get("account_id", "")).strip()
    if not account_id:
        raise HTTPException(status_code=400, detail="account_id required")

    snapshot = {
        "account_id": account_id,
        "label": payload.get("label", account_id),
        "platform": payload.get("platform", ""),        # "MT4" / "MT5"
        "broker": payload.get("broker", ""),
        "currency": payload.get("currency", ""),
        "balance": payload.get("balance", 0.0),
        "equity": payload.get("equity", 0.0),
        "floating_pnl": payload.get("floating_pnl", 0.0),
        "margin": payload.get("margin", 0.0),
        "margin_free": payload.get("margin_free", 0.0),
        "margin_level": payload.get("margin_level", 0.0),
        "margin_used_pct": payload.get("margin_used_pct", 0.0),
        "leverage": payload.get("leverage", 0),
        "day_pnl": payload.get("day_pnl", 0.0),
        "drawdown_pct": payload.get("drawdown_pct", 0.0),
        "open_positions": payload.get("open_positions", 0),
        "positions": payload.get("positions", []),
        "symbols": payload.get("symbols", []),
        "server_time": payload.get("server_time", ""),
        "last_update": time.time(),
    }
    accounts[account_id] = snapshot

    await manager.broadcast({"type": "update", "account": snapshot})
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# REST: dashboard polling fallback
# ---------------------------------------------------------------------------
@app.get("/api/accounts")
async def get_accounts():
    return JSONResponse(accounts)


# ---------------------------------------------------------------------------
# WebSocket: dashboard <- server
# ---------------------------------------------------------------------------
@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await manager.connect(ws)
    try:
        while True:
            # dashboard doesn't need to send anything; just keep the socket open
            await ws.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(ws)


# ---------------------------------------------------------------------------
# Serve the dashboard itself
# ---------------------------------------------------------------------------
@app.get("/")
async def serve_dashboard():
    return FileResponse(os.path.join(HERE, "dashboard.html"))


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
