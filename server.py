"""
Multi-Account P&L Dashboard Backend
------------------------------------
Receives real-time account snapshots from MT4/MT5 reporter EAs via HTTP POST,
pushes live updates to connected dashboards over WebSocket, and logs a
throttled history to SQLite for persistent equity curves / daily digests.

NOTE on persistence: if deployed on Render's free tier, the local disk
(and therefore pnl_history.db) is not guaranteed to survive every redeploy
or platform-level restart. Fine for day-to-day use; if you need guaranteed
long-term history, add a persistent disk or an external database later.

Run:
    pip install -r requirements.txt
    python3 server.py

EAs POST to:            https://<your-domain>/api/report
Dashboard lives at:     https://<your-domain>/   (password-protected)
"""

import hashlib
import io
import json
import os
import sqlite3
import time
from datetime import datetime, timezone, date
from threading import Lock
from typing import Dict, List

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request, HTTPException, Form
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
API_KEY = os.environ.get("PNL_API_KEY", "changeme123")             # EAs authenticate with this
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "changeme")  # humans authenticate with this
print(f"[startup] DASHBOARD_PASSWORD loaded, length={len(DASHBOARD_PASSWORD)}, from_env={'DASHBOARD_PASSWORD' in os.environ}, repr={DASHBOARD_PASSWORD!r}")
STALE_AFTER_SECONDS = 15
HISTORY_INTERVAL_SECONDS = 60   # throttle: log at most one history row per account per this interval
DB_PATH = os.environ.get("PNL_DB_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pnl_history.db"))
HERE = os.path.dirname(os.path.abspath(__file__))
AUTH_COOKIE_NAME = "pnl_auth"

app = FastAPI(title="PnL Dashboard")

accounts: Dict[str, dict] = {}          # account_id -> latest snapshot (in-memory, unthrottled)
_last_history_write: Dict[str, float] = {}  # account_id -> last time we wrote a history row

db_lock = Lock()
db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.execute("""
CREATE TABLE IF NOT EXISTS account_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    ts REAL NOT NULL,
    balance REAL, equity REAL, floating_pnl REAL, day_pnl REAL, margin_level REAL
)
""")
db.execute("""
CREATE TABLE IF NOT EXISTS symbol_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    ts REAL NOT NULL,
    symbol TEXT NOT NULL,
    leg_count INTEGER, avg_entry REAL,
    open_profit REAL, open_swap REAL,
    closed_profit REAL, closed_swap REAL, closed_commission REAL,
    net_total REAL
)
""")
db.execute("CREATE INDEX IF NOT EXISTS idx_acct_hist ON account_history(account_id, ts)")
db.execute("CREATE INDEX IF NOT EXISTS idx_sym_hist ON symbol_history(account_id, symbol, ts)")
db.commit()


def auth_token() -> str:
    return hashlib.sha256(("pnldash-" + DASHBOARD_PASSWORD).encode()).hexdigest()


def is_authed(request_or_ws) -> bool:
    cookie = request_or_ws.cookies.get(AUTH_COOKIE_NAME)
    return cookie is not None and cookie == auth_token()


# ---------------------------------------------------------------------------
# WebSocket connection manager
# ---------------------------------------------------------------------------
class ConnectionManager:
    def __init__(self):
        self.active: List[WebSocket] = []

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self.active.append(ws)
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
# Login (cookie-based; simple by design — this is a personal-use gate,
# not a multi-user auth system)
# ---------------------------------------------------------------------------
@app.get("/login")
async def login_page():
    return FileResponse(os.path.join(HERE, "login.html"))


@app.post("/login")
async def login_submit(password: str = Form(...)):
    match = (password == DASHBOARD_PASSWORD)
    print(f"[login] received_len={len(password)} expected_len={len(DASHBOARD_PASSWORD)} match={match} received_repr={password!r} expected_repr={DASHBOARD_PASSWORD!r}")
    if not match:
        return RedirectResponse(url="/login?error=1", status_code=303)
    resp = RedirectResponse(url="/", status_code=303)
    resp.set_cookie(AUTH_COOKIE_NAME, auth_token(), max_age=60 * 60 * 24 * 90, httponly=True, samesite="lax")
    print(f"[login] success, cookie set")
    return resp


@app.get("/logout")
async def logout():
    resp = RedirectResponse(url="/login", status_code=303)
    resp.delete_cookie(AUTH_COOKIE_NAME)
    return resp


# ---------------------------------------------------------------------------
# REST: EA -> server  (unaffected by password auth — EAs use api_key)
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

    now = time.time()
    snapshot = {
        "account_id": account_id,
        "label": payload.get("label", account_id),
        "platform": payload.get("platform", ""),
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
        "last_update": now,
    }
    accounts[account_id] = snapshot

    # throttled persistent history write
    last = _last_history_write.get(account_id, 0)
    if now - last >= HISTORY_INTERVAL_SECONDS:
        _last_history_write[account_id] = now
        with db_lock:
            db.execute(
                "INSERT INTO account_history (account_id, ts, balance, equity, floating_pnl, day_pnl, margin_level) "
                "VALUES (?,?,?,?,?,?,?)",
                (account_id, now, snapshot["balance"], snapshot["equity"],
                 snapshot["floating_pnl"], snapshot["day_pnl"], snapshot["margin_level"])
            )
            for s in snapshot["symbols"]:
                db.execute(
                    "INSERT INTO symbol_history (account_id, ts, symbol, leg_count, avg_entry, "
                    "open_profit, open_swap, closed_profit, closed_swap, closed_commission, net_total) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                    (account_id, now, s.get("symbol", ""), s.get("leg_count", 0), s.get("avg_entry", 0.0),
                     s.get("open_profit", 0.0), s.get("open_swap", 0.0), s.get("closed_profit", 0.0),
                     s.get("closed_swap", 0.0), s.get("closed_commission", 0.0), s.get("net_total", 0.0))
                )
            db.commit()

    await manager.broadcast({"type": "update", "account": snapshot})
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# REST: dashboard-facing (password protected)
# ---------------------------------------------------------------------------
@app.get("/api/accounts")
async def get_accounts(request: Request):
    if not is_authed(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    return JSONResponse(accounts)


@app.get("/api/history")
async def get_history(request: Request, account_id: str, hours: float = 24):
    if not is_authed(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    since = time.time() - hours * 3600
    with db_lock:
        rows = db.execute(
            "SELECT ts, balance, equity, floating_pnl, day_pnl, margin_level FROM account_history "
            "WHERE account_id=? AND ts>=? ORDER BY ts ASC",
            (account_id, since)
        ).fetchall()
    return JSONResponse([
        {"ts": r[0], "balance": r[1], "equity": r[2], "floating_pnl": r[3], "day_pnl": r[4], "margin_level": r[5]}
        for r in rows
    ])


def _day_bounds(day_str: str):
    d = datetime.strptime(day_str, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    start = d.timestamp()
    end = start + 86400
    return start, end


def _build_digest(day_str: str):
    start, end = _day_bounds(day_str)
    digest = {}
    with db_lock:
        # latest account_history row per account within that day
        acct_rows = db.execute(
            "SELECT account_id, balance, equity, floating_pnl, day_pnl, margin_level, MAX(ts) "
            "FROM account_history WHERE ts>=? AND ts<? GROUP BY account_id",
            (start, end)
        ).fetchall()
        for account_id, balance, equity, floating_pnl, day_pnl, margin_level, ts in acct_rows:
            label = accounts.get(account_id, {}).get("label", account_id)
            digest[account_id] = {
                "account_id": account_id, "label": label,
                "balance": balance, "equity": equity, "floating_pnl": floating_pnl,
                "day_pnl": day_pnl, "margin_level": margin_level, "symbols": []
            }

        sym_rows = db.execute(
            "SELECT account_id, symbol, leg_count, avg_entry, open_profit, open_swap, "
            "closed_profit, closed_swap, closed_commission, net_total, MAX(ts) "
            "FROM symbol_history WHERE ts>=? AND ts<? GROUP BY account_id, symbol",
            (start, end)
        ).fetchall()
        for row in sym_rows:
            (account_id, symbol, leg_count, avg_entry, open_profit, open_swap,
             closed_profit, closed_swap, closed_commission, net_total, ts) = row
            if account_id not in digest:
                label = accounts.get(account_id, {}).get("label", account_id)
                digest[account_id] = {
                    "account_id": account_id, "label": label,
                    "balance": None, "equity": None, "floating_pnl": None,
                    "day_pnl": None, "margin_level": None, "symbols": []
                }
            digest[account_id]["symbols"].append({
                "symbol": symbol, "leg_count": leg_count, "avg_entry": avg_entry,
                "open_profit": open_profit, "open_swap": open_swap,
                "closed_profit": closed_profit, "closed_swap": closed_swap,
                "closed_commission": closed_commission, "net_total": net_total
            })
    return list(digest.values())


@app.get("/api/digest")
async def get_digest(request: Request, day: str = None):
    if not is_authed(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    day_str = day or date.today().isoformat()
    return JSONResponse({"day": day_str, "accounts": _build_digest(day_str)})


@app.get("/api/export.csv")
async def export_csv(request: Request, day: str = None):
    if not is_authed(request):
        raise HTTPException(status_code=401, detail="not authenticated")
    day_str = day or date.today().isoformat()
    rows = _build_digest(day_str)

    buf = io.StringIO()
    buf.write("account_id,label,symbol,leg_count,avg_entry,open_profit,open_swap,"
               "closed_profit,closed_swap,closed_commission,net_total,"
               "account_balance,account_equity,account_floating_pnl,account_day_pnl\n")
    for acc in rows:
        if acc["symbols"]:
            for s in acc["symbols"]:
                buf.write(f'{acc["account_id"]},{acc["label"]},{s["symbol"]},{s["leg_count"]},'
                          f'{s["avg_entry"]},{s["open_profit"]},{s["open_swap"]},{s["closed_profit"]},'
                          f'{s["closed_swap"]},{s["closed_commission"]},{s["net_total"]},'
                          f'{acc["balance"]},{acc["equity"]},{acc["floating_pnl"]},{acc["day_pnl"]}\n')
        else:
            buf.write(f'{acc["account_id"]},{acc["label"]},,,,,,,,,,{acc["balance"]},'
                      f'{acc["equity"]},{acc["floating_pnl"]},{acc["day_pnl"]}\n')

    buf.seek(0)
    return StreamingResponse(
        iter([buf.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="pnl-{day_str}.csv"'}
    )


# ---------------------------------------------------------------------------
# WebSocket: dashboard <- server
# ---------------------------------------------------------------------------
@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    if not is_authed(ws):
        await ws.close(code=4401)
        return
    await manager.connect(ws)
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(ws)


# ---------------------------------------------------------------------------
# Serve the dashboard (password protected)
# ---------------------------------------------------------------------------
@app.get("/")
async def serve_dashboard(request: Request):
    cookie_val = request.cookies.get(AUTH_COOKIE_NAME)
    print(f"[serve_dashboard] cookie_present={cookie_val is not None} authed={is_authed(request)}")
    if not is_authed(request):
        return RedirectResponse(url="/login")
    return FileResponse(os.path.join(HERE, "dashboard.html"))


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
