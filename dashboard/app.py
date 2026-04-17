#!/usr/bin/env python3
"""Subterra fleet dashboard. LAN-only, stdlib-only.

Single-file Python service that shells out to the headscale CLI every
10 s, caches the state, and serves:
  - /            HTML dashboard (server-rendered)
  - /api/status  same state as JSON
  - /healthz     liveness probe

Runs on 0.0.0.0:8081 by default. Intended to be firewalled to LAN only
via iptables rule installed by setup.sh.
"""
from __future__ import annotations

import ipaddress
import json
import os
import shlex
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from html import escape

HEADSCALE_BIN = os.environ.get("SUBTERRA_HEADSCALE_BIN", "headscale")
HEADSCALE_CONFIG = os.environ.get("SUBTERRA_HEADSCALE_CONFIG", "/etc/headscale/config.yaml")
CACHE_TTL_SEC = int(os.environ.get("SUBTERRA_DASHBOARD_CACHE_SEC", "10"))

# Defense in depth: even if iptables fails, reject non-allowlisted source
# IPs at the app layer. Empty = permit all (dev mode).
_raw_allow = os.environ.get("SUBTERRA_DASHBOARD_ALLOW_CIDRS", "")
ALLOW_CIDRS: list = []
for _c in (x.strip() for x in _raw_allow.split(",")):
    if not _c:
        continue
    try:
        ALLOW_CIDRS.append(ipaddress.ip_network(_c, strict=False))
    except ValueError:
        print(f"dashboard: ignoring invalid CIDR '{_c}' in SUBTERRA_DASHBOARD_ALLOW_CIDRS",
              flush=True)

_lock = threading.Lock()
_cache: dict = {"ts": 0.0, "data": {}}


def _hs(*args: str) -> list | dict:
    cmd = shlex.split(HEADSCALE_BIN) + ["-c", HEADSCALE_CONFIG, "--output", "json", *args]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True)
        parsed = json.loads(r.stdout or "[]")
        # headscale returns null (not []) when a list is empty.
        return parsed if parsed is not None else []
    except subprocess.CalledProcessError as e:
        return {"_error": f"rc={e.returncode}: {e.stderr.strip()[:300]}"}
    except Exception as e:
        return {"_error": str(e)[:300]}


def fetch_state() -> dict:
    return {
        "users": _hs("users", "list"),
        "nodes": _hs("nodes", "list"),
        "keys": _hs("preauthkeys", "list"),
        "fetched_at": int(time.time()),
    }


def state() -> dict:
    now = time.time()
    with _lock:
        if now - _cache["ts"] > CACHE_TTL_SEC:
            _cache["data"] = fetch_state()
            _cache["ts"] = now
        return _cache["data"]


def _fmt_age(ts: int) -> str:
    if ts <= 0:
        return "never"
    delta = max(0, int(time.time()) - ts)
    if delta < 60:
        return f"{delta}s"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def _fmt_until(ts: int) -> str:
    delta = ts - int(time.time())
    if delta <= 0:
        return "expired"
    if delta < 3600:
        return f"{delta // 60}m"
    if delta < 86400:
        return f"{delta // 3600}h"
    return f"{delta // 86400}d"


CSS = """
body { font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif;
       background: #0e1116; color: #e6edf3; margin: 0; padding: 24px;
       font-size: 14px; line-height: 1.5; }
h1 { font-size: 22px; margin: 0 0 4px 0; color: #f5f7fa; }
h2 { font-size: 15px; text-transform: uppercase; letter-spacing: 0.06em;
     color: #7d8590; margin: 24px 0 8px 0; font-weight: 600; }
.subtitle { color: #7d8590; font-size: 12px; margin-bottom: 20px; }
.summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
           gap: 12px; margin-bottom: 8px; }
.stat { background: #161b22; border: 1px solid #30363d; border-radius: 6px;
        padding: 12px 14px; }
.stat .label { color: #7d8590; font-size: 11px; text-transform: uppercase;
               letter-spacing: 0.05em; }
.stat .value { font-size: 26px; font-weight: 600; margin-top: 4px; }
table { width: 100%; border-collapse: collapse; background: #161b22;
        border: 1px solid #30363d; border-radius: 6px; overflow: hidden; }
th, td { text-align: left; padding: 8px 14px; border-bottom: 1px solid #30363d; }
th { background: #1c232b; color: #7d8590; font-size: 11px; text-transform: uppercase;
     letter-spacing: 0.05em; font-weight: 600; }
tr:last-child td { border-bottom: none; }
.dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
       vertical-align: middle; margin-right: 6px; }
.dot.online  { background: #3fb950; }
.dot.offline { background: #f85149; }
.dot.unknown { background: #7d8590; }
.tag { display: inline-block; padding: 1px 8px; margin-right: 4px;
       background: #1f2937; color: #a0aec0; font-size: 11px; border-radius: 3px; }
.warn { color: #d29922; }
.error { color: #f85149; }
.muted { color: #7d8590; }
footer { margin-top: 32px; color: #7d8590; font-size: 12px; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
       background: #1c232b; padding: 1px 4px; border-radius: 3px; font-size: 12px; }
"""


def render_html(s: dict) -> str:
    users = s.get("users") or []
    nodes = s.get("nodes") or []
    keys = s.get("keys") or []
    fetched = s.get("fetched_at", 0)

    err = None
    for k, v in s.items():
        if isinstance(v, dict) and v.get("_error"):
            err = f"{k}: {v['_error']}"
            break

    if not isinstance(users, list): users = []
    if not isinstance(nodes, list): nodes = []
    if not isinstance(keys, list):  keys  = []

    def _district_of(n: dict) -> str:
        # Headscale moves tagged nodes to the synthetic 'tagged-devices'
        # user. The original district is preserved on the preauth key.
        user_name = (n.get("user") or {}).get("name") or ""
        if user_name and user_name != "tagged-devices":
            return user_name
        pk_user = ((n.get("pre_auth_key") or {}).get("user") or {}).get("name")
        return pk_user or user_name or "?"

    per_user: dict[str, list] = {u.get("name", "?"): [] for u in users}
    for n in nodes:
        per_user.setdefault(_district_of(n), []).append(n)

    n_online = sum(1 for n in nodes if n.get("online"))
    n_offline = len(nodes) - n_online
    now_epoch = int(time.time())
    n_keys_outstanding = sum(
        1 for k in keys
        if not k.get("used")
        and ((k.get("expiration") or {}).get("seconds", 0) or 0) > now_epoch
    )

    rows_districts = []
    for uname, u_nodes in sorted(per_user.items()):
        if not u_nodes:
            rows_districts.append(
                f"<tr><td>{escape(uname)}</td><td class=muted>no nodes yet</td>"
                f"<td class=muted>—</td><td class=muted>—</td></tr>"
            )
            continue
        for n in u_nodes:
            tags = n.get("tags") or n.get("forced_tags") or n.get("valid_tags") or []
            tag_html = " ".join(f"<span class=tag>{escape(t)}</span>" for t in tags) or \
                       "<span class=muted>no tag</span>"
            online = n.get("online")
            dot_class = "online" if online else ("offline" if online is False else "unknown")
            last_seen_epoch = (n.get("last_seen") or {}).get("seconds", 0) or 0
            approved = n.get("approved_routes") or []
            available = n.get("available_routes") or []
            routes = list(approved) + [r for r in available if r not in approved]
            routes_html = (
                ", ".join(f"<code>{escape(r)}</code>" for r in routes) if routes
                else "<span class=muted>—</span>"
            )
            name = n.get("given_name") or n.get("name") or "?"
            rows_districts.append(
                f"<tr>"
                f"<td>{escape(uname)}</td>"
                f"<td><span class='dot {dot_class}'></span>{escape(name)} {tag_html}</td>"
                f"<td>{_fmt_age(last_seen_epoch)}</td>"
                f"<td>{routes_html}</td>"
                f"</tr>"
            )

    rows_keys = []
    for k in sorted(keys, key=lambda k: (k.get("expiration") or {}).get("seconds", 0) or 0):
        if k.get("used"):
            continue
        exp = (k.get("expiration") or {}).get("seconds", 0) or 0
        if exp <= now_epoch:
            continue
        uname = (k.get("user") or {}).get("name", "?")
        tags = " ".join(f"<span class=tag>{escape(t)}</span>"
                        for t in (k.get("acl_tags") or []))
        cls = "warn" if (exp - now_epoch) < 3600 else ""
        rows_keys.append(
            f"<tr>"
            f"<td>{escape(uname)}</td>"
            f"<td>{tags}</td>"
            f"<td class='{cls}'>{_fmt_until(exp)}</td>"
            f"<td><code>{escape((k.get('key') or '')[:16] + '...')}</code></td>"
            f"</tr>"
        )

    err_banner = (
        f"<div class=error style='background:#2d1418;padding:10px 14px;"
        f"border-radius:6px;margin-bottom:16px'>{escape(err)}</div>" if err else ""
    )

    return f"""<!doctype html>
<html><head>
<meta charset=utf-8>
<title>Subterra Fleet</title>
<meta http-equiv=refresh content=30>
<style>{CSS}</style>
</head><body>
<h1>Subterra Fleet</h1>
<div class=subtitle>Headscale coordinator · {len(users)} districts · fetched {_fmt_age(fetched)} ago</div>
{err_banner}
<div class=summary>
  <div class=stat><div class=label>Districts</div><div class=value>{len(users)}</div></div>
  <div class=stat><div class=label>Nodes online</div><div class=value>{n_online}</div></div>
  <div class=stat><div class=label>Nodes offline</div><div class='value {"error" if n_offline else ""}'>{n_offline}</div></div>
  <div class=stat><div class=label>Keys outstanding</div><div class=value>{n_keys_outstanding}</div></div>
</div>

<h2>Districts</h2>
<table><thead><tr><th>District</th><th>Node</th><th>Last seen</th><th>Routes</th></tr></thead>
<tbody>{''.join(rows_districts) or '<tr><td colspan=4 class=muted>no districts yet</td></tr>'}</tbody>
</table>

<h2>Outstanding pre-auth keys</h2>
<table><thead><tr><th>District</th><th>Tags</th><th>Expires in</th><th>Key prefix</th></tr></thead>
<tbody>{''.join(rows_keys) or '<tr><td colspan=4 class=muted>none outstanding</td></tr>'}</tbody>
</table>

<footer>
  Auto-refreshes every 30s. JSON at <code>/api/status</code>.
  Last fetch: <code>{fetched or 0}</code>.
</footer>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def _client_allowed(self) -> bool:
        if not ALLOW_CIDRS:
            return True
        try:
            addr = ipaddress.ip_address(self.client_address[0])
        except (ValueError, IndexError):
            return False
        return any(addr in net for net in ALLOW_CIDRS)

    def do_GET(self):
        if not self._client_allowed():
            self._respond(403, b"forbidden: source not in SUBTERRA_DASHBOARD_ALLOW_CIDRS",
                          "text/plain")
            return
        if self.path == "/healthz":
            self._respond(200, b'{"status":"ok"}', "application/json")
            return
        if self.path.startswith("/api/status"):
            body = json.dumps(state(), default=str).encode()
            self._respond(200, body, "application/json")
            return
        if self.path == "/" or self.path.startswith("/?"):
            body = render_html(state()).encode()
            self._respond(200, body, "text/html; charset=utf-8")
            return
        self._respond(404, b"not found", "text/plain")

    def _respond(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args):
        # Suppress default stdout access logs; journald will still get
        # our explicit logging if we add any. Keeps journal quiet.
        return


def main() -> None:
    host = os.environ.get("SUBTERRA_DASHBOARD_HOST", "0.0.0.0")
    port = int(os.environ.get("SUBTERRA_DASHBOARD_PORT", "8081"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"subterra-dashboard listening on {host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
