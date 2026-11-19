#!/usr/bin/env python3
"""garage-monitor hub.

Receives reports from agents and serves the dashboard. Uses only the Python
standard library. Data is kept in memory: the last report from each machine
plus a few minutes of samples for the sparklines.

Settings (see /etc/garage-monitor/hub.env):
  GM_BIND   address to listen on (the install script uses the Tailscale IP)
  GM_PORT   port (default 8787)
  GM_TOKEN  shared secret that agents must send
"""
import hmac
import json
import os
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("GM_BIND", "127.0.0.1")
PORT = int(os.environ.get("GM_PORT", "8787"))
TOKEN = os.environ.get("GM_TOKEN", "")
HISTORY_LEN = 150          # samples kept per machine for sparklines (~5 min at 2 s)
MAX_BODY = 256 * 1024      # largest report we accept
FORGET_AFTER_S = 7 * 86400  # drop machines silent for a week

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# Values tracked over time for each machine: name -> path into the report.
SPARK_FIELDS = {
    "cpu": ("cpu", "percent"),
    "temp": ("cpu", "temp"),
    "gpu": ("gpu", "busy"),
}

machines = {}
lock = threading.Lock()


def dig(obj, path):
    for key in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(key)
    return obj if isinstance(obj, (int, float)) else None


def record(report):
    name = str(report.get("name") or "unknown")[:64]
    now = time.time()
    with lock:
        entry = machines.get(name)
        if entry is None:
            entry = {"history": {k: deque(maxlen=HISTORY_LEN) for k in SPARK_FIELDS}}
            machines[name] = entry
        entry["report"] = report
        entry["received"] = now
        for key, path in SPARK_FIELDS.items():
            entry["history"][key].append(dig(report, path))


def snapshot():
    now = time.time()
    with lock:
        for name in [n for n, e in machines.items() if now - e["received"] > FORGET_AFTER_S]:
            del machines[name]
        items = [
            {
                "name": name,
                "age_s": round(now - e["received"], 1),
                "report": e["report"],
                "history": {k: list(v) for k, v in e["history"].items()},
            }
            for name, e in sorted(machines.items())
        ]
    return {"now": now, "machines": items}


class Handler(BaseHTTPRequestHandler):
    server_version = "garage-monitor"

    def log_message(self, fmt, *args):  # keep the journal quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(STATIC_DIR, "index.html"), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError:
                self._send(500, '{"error":"dashboard file missing"}')
        elif path == "/api/machines":
            self._send(200, json.dumps(snapshot()))
        elif path == "/api/health":
            self._send(200, '{"ok":true}')
        else:
            self._send(404, '{"error":"not found"}')

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/report":
            return self._send(404, '{"error":"not found"}')
        if not hmac.compare_digest(self.headers.get("X-GM-Token", ""), TOKEN):
            return self._send(401, '{"error":"bad token"}')
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self._send(413, '{"error":"bad size"}')
        try:
            report = json.loads(self.rfile.read(length))
            if not isinstance(report, dict):
                raise ValueError("report must be an object")
        except ValueError:
            return self._send(400, '{"error":"bad json"}')
        record(report)
        self._send(200, '{"ok":true}')


def main():
    if not TOKEN:
        raise SystemExit("GM_TOKEN is not set; refusing to start without one")
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    print("garage-monitor hub listening on http://%s:%d" % (BIND, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
