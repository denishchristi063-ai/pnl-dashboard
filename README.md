# Multi-Account P&L Dashboard

Real-time P&L dashboard for all your MT4/MT5 accounts, viewable on iPhone via Safari
(add to home screen for an app-like experience). No App Store, no Apple Developer account needed.

## How it works
```
MT4/MT5 terminals (EA)  --WebRequest POST-->  FastAPI server on your VPS  --WebSocket-->  iPhone Safari dashboard
```
Each terminal runs `PnLReporter_MT4.mq4` or `PnLReporter_MT5.mq5`, which sends a JSON snapshot
(balance, equity, floating P&L, positions) every few seconds. The server keeps the latest state
per account and pushes it live to any open dashboard.

---

## 1. Deploy the backend on your VPS

```bash
# On the VPS
mkdir -p ~/pnl-dashboard && cd ~/pnl-dashboard
# copy server.py, dashboard.html, requirements.txt here

python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# set your own API key (don't leave the default!)
export PNL_API_KEY="pick-a-long-random-string-here"
export DASHBOARD_PASSWORD="pick-a-different-password-for-viewing-the-dashboard"

python3 server.py
```

The server listens on port `443`. Open `http://YOUR_VPS_IP:443` in a browser to confirm the
dashboard loads (it'll say "Waiting for accounts to report in…" until an EA reports).

### Keep it running permanently (systemd)
Create `/etc/systemd/system/pnl-dashboard.service`:
```ini
[Unit]
Description=PnL Dashboard
After=network.target

[Service]
WorkingDirectory=/root/pnl-dashboard
Environment="PNL_API_KEY=pick-a-long-random-string-here"
ExecStart=/root/pnl-dashboard/venv/bin/python3 server.py
Restart=always

[Install]
WantedBy=multi-user.target
```
Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pnl-dashboard
```

### Open the port
If the VPS has a firewall (ufw, security group, etc.), allow inbound TCP on port 443.

### Optional but recommended: HTTPS
Plain HTTP works fine for MT4/MT5 `WebRequest()` and for Safari, but if you want a padlock
and to avoid "insecure" browser warnings, put nginx in front with a free Let's Encrypt cert
and reverse-proxy to `127.0.0.1:443`. Not required to get this working — and already handled
for you if you're hosting on Render.

---

## New features

### Password login
The dashboard now requires a password before showing any account data — set via
`DASHBOARD_PASSWORD` (separate from `PNL_API_KEY`, which is only used by the EAs, not humans).
Visiting `/` without a valid session redirects to `/login`. A "log out" icon in the header clears
your session. Note: since the session token is generated fresh each time the server process
restarts, everyone gets logged out after a redeploy — that's expected, just log back in.

### Persistent history + daily digest
Every account snapshot is now throttled and logged to a local SQLite database
(`pnl_history.db`), roughly one row per account per minute. This powers:
- **Sparklines that survive page reloads** — on first load, each account's chart is seeded from
  the last 6 hours of stored history, then continues live from there.
- **Daily Digest** (button in the toolbar) — aggregates live + closed P&L per currency pair
  across all your accounts for the day.
- **CSV export** — download the day's full breakdown (per account, per symbol) as a `.csv` file.

**Important caveat if hosted on Render's free tier:** the filesystem is ephemeral, meaning
`pnl_history.db` gets wiped whenever the service redeploys or restarts after inactivity. History
persists fine during normal day-to-day use, but isn't guaranteed to survive indefinitely on the
free tier. If you need guaranteed long-term history, the fix is either a Render persistent disk
(paid) or an external database (e.g. a free Neon/Supabase Postgres instance) — let me know if you
want that wired up later.

### Symbol filter
Chips appear automatically for every currency pair currently reporting activity across any
account. Tap one (or several) to narrow every account card — and the Daily Digest — down to just
those symbols. Tap "All" to reset.

### Light/dark theme
Toggle via the icon in the header — preference is remembered per device (stored in the browser,
not the server), so each device you view the dashboard from keeps its own choice.

---

## 2. Set up each MT4/MT5 terminal

1. Copy `PnLReporter_MT5.mq5` into `MQL5/Experts/` (or `PnLReporter_MT4.mq4` into `MQL4/Experts/`), compile it.
2. In the terminal: **Tools → Options → Expert Advisors** → check "Allow WebRequest for listed URL"
   → add `http://YOUR_VPS_IP:443` (exact scheme+host+port, no path, no trailing slash).
3. Attach the EA to any chart (it doesn't matter which symbol — it reports account-level data).
4. Set inputs:
   - `InpApiUrl` → `http://YOUR_VPS_IP:443/api/report`
   - `InpApiKey` → same value as `PNL_API_KEY` on the server
   - `InpAccountId` → leave blank to auto-use the account login number, or set something readable
   - `InpAccountLabel` → e.g. `"Gold Martingale - IC Markets"` (shown on the dashboard)
   - `InpReportIntervalSeconds` → 3 is a good default; lower = more real-time, more load

Repeat for all 6–15 terminals. Each one just needs a unique `InpAccountId`.

**Note:** if a terminal already runs other EAs (e.g. your DualCycle or basket monitor EAs) on
other charts, that's fine — attach this reporter EA on a separate chart/symbol in the same terminal.
It only reads account-level and position-level data; it doesn't interfere with your trading EAs.

---

## 3. Use it on iPhone

1. Open Safari → go to `http://YOUR_VPS_IP:443`
2. Tap the Share icon → **Add to Home Screen**
3. Launch it from the home screen — it opens full-screen like a native app, and updates live
   over WebSocket as long as you have connectivity.

If a terminal stops reporting (VPS down, EA removed, terminal crashed), its card dims and shows
an "⚠ No update in over 15s" warning after 15 seconds of silence, so you'll spot outages immediately.

---

## Notes / next steps you might want later
- **History/equity curve**: currently only the latest snapshot is kept in memory. If you want
  historical charts, the server can log each report to SQLite — say the word and I'll add it.
- **Push notifications** (e.g. alert if any account drawdown exceeds X%): possible via a service
  worker + Web Push, works in Safari on iOS 16.4+.
- **Auth on the dashboard itself**: right now anyone with the URL can view it. Easy to add a
  simple password gate if this will be exposed beyond your own devices.
