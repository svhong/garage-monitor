#!/usr/bin/env python3
"""garage-monitor hub.

Receives reports from agents and serves the dashboard. Uses only the Python
standard library. Data is kept in memory: the last report from each machine
plus a few minutes of samples for the sparklines.

Settings (see /etc/garage-monitor/hub.env):
  GM_BIND                 address(es) to listen on, comma-separated
                          (the installer uses the Tailscale IP and 127.0.0.1)
  GM_PORT                 port (default 8787)
  GM_TOKEN                shared secret that agents must send
  GM_VIEW_PASSWORD_HASH   if set, viewers must log in with this password
                          (create with: python3 hub/hub.py --hash-password)
  GM_SESSION_HOURS        how long a login lasts (default 168 = 7 days)
  GM_ALLOW_ORIGINS        websites allowed to read the data, comma-separated,
                          e.g. https://example.com
"""
import getpass
import hashlib
import hmac
import json
import os
import secrets
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("GM_BIND", "127.0.0.1")
PORT = int(os.environ.get("GM_PORT", "8787"))
TOKEN = os.environ.get("GM_TOKEN", "")
PASSWORD_HASH = os.environ.get("GM_VIEW_PASSWORD_HASH", "").strip()
SESSION_S = float(os.environ.get("GM_SESSION_HOURS", "168")) * 3600
ALLOW_ORIGINS = {o.strip().rstrip("/") for o in os.environ.get("GM_ALLOW_ORIGINS", "").split(",") if o.strip()}

HISTORY_LEN = 150          # samples kept per machine for sparklines (~5 min at 2 s)
MAX_BODY = 256 * 1024      # largest report we accept
FORGET_AFTER_S = 7 * 86400  # drop machines silent for a week
PBKDF2_ROUNDS = 300_000
MAX_FAILURES = 5           # wrong passwords allowed before a lockout
LOCKOUT_S = 60

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

# Values tracked over time for each machine: name -> path into the report.
SPARK_FIELDS = {
    "cpu": ("cpu", "percent"),
    "temp": ("cpu", "temp"),
    "gpu": ("gpu", "busy"),
}

machines = {}
sessions = {}  # session token -> expiry time
failures = {"count": 0, "locked_until": 0.0}
lock = threading.Lock()


# ---- passwords & sessions -------------------------------------------------

def hash_password(password, salt=None, rounds=PBKDF2_ROUNDS):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), rounds).hex()
    return "pbkdf2_sha256:%d:%s:%s" % (rounds, salt, digest)


def check_password(password):
    try:
        algo, rounds, salt, _ = PASSWORD_HASH.split(":")
        if algo != "pbkdf2_sha256":
            return False
        return hmac.compare_digest(hash_password(password, salt, int(rounds)), PASSWORD_HASH)
    except ValueError:
        return False


def login(password):
    """Returns (session_token, error_message)."""
    now = time.time()
    with lock:
        if now < failures["locked_until"]:
            return None, "Too many wrong passwords. Try again in a minute."
    ok = check_password(password)
    with lock:
        if not ok:
            failures["count"] += 1
            if failures["count"] >= MAX_FAILURES:
                failures["count"] = 0
                failures["locked_until"] = now + LOCKOUT_S
            return None, "Wrong password."
        failures["count"] = 0
        for t in [t for t, exp in sessions.items() if exp < now]:
            del sessions[t]
        token = secrets.token_urlsafe(32)
        sessions[token] = now + SESSION_S
        return token, None


def session_valid(token):
    if not token:
        return False
    with lock:
        exp = sessions.get(token)
        if exp is None:
            return False
        if exp < time.time():
            del sessions[token]
            return False
        return True


# ---- machine data -------------------------------------------------------------

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


# ---- HTTP -----------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "garage-monitor"

    def log_message(self, fmt, *args):  # keep the journal quiet
        pass

    def _cors(self):
        origin = (self.headers.get("Origin") or "").rstrip("/")
        if origin and origin in ALLOW_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Max-Age", "600")
            # Chrome asks before a public website talks to a private-network
            # address (Tailscale IPs count as private).
            if self.headers.get("Access-Control-Request-Private-Network"):
                self.send_header("Access-Control-Allow-Private-Network", "true")

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj))

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            raise ValueError("bad size")
        obj = json.loads(self.rfile.read(length))
        if not isinstance(obj, dict):
            raise ValueError("expected an object")
        return obj

    def _bearer(self):
        auth = self.headers.get("Authorization", "")
        return auth[7:].strip() if auth.startswith("Bearer ") else ""

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(STATIC_DIR, "index.html"), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except OSError:
                self._json(500, {"error": "dashboard file missing"})
        elif path == "/api/machines":
            if PASSWORD_HASH and not session_valid(self._bearer()):
                return self._json(401, {"error": "login required"})
            self._json(200, snapshot())
        elif path == "/api/health":
            self._json(200, {"ok": True, "password": bool(PASSWORD_HASH)})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/logout":
            with lock:
                sessions.pop(self._bearer(), None)
            return self._json(200, {"ok": True})

        try:
            body = self._read_json()
        except ValueError:
            return self._json(400, {"error": "bad request"})

        if path == "/api/report":
            if not hmac.compare_digest(self.headers.get("X-GM-Token", ""), TOKEN):
                return self._json(401, {"error": "bad token"})
            record(body)
            return self._json(200, {"ok": True})

        if path == "/api/login":
            if not PASSWORD_HASH:
                return self._json(200, {"token": "", "password": False})
            token, err = login(str(body.get("password", "")))
            if err:
                time.sleep(0.5)  # slow down guessing
                return self._json(401, {"error": err})
            return self._json(200, {"token": token, "expires_in": int(SESSION_S)})

        self._json(404, {"error": "not found"})


def serve(address):
    server = ThreadingHTTPServer((address, PORT), Handler)
    server.daemon_threads = True
    print("garage-monitor hub listening on http://%s:%d" % (address, PORT), flush=True)
    server.serve_forever()


def main():
    if "--hash-password" in sys.argv:
        # Reads the password from stdin when piped, otherwise asks for it.
        pw = sys.stdin.readline().rstrip("\n") if not sys.stdin.isatty() else getpass.getpass("Viewer password: ")
        if len(pw) < 4:
            raise SystemExit("password must be at least 4 characters")
        print(hash_password(pw))
        return

    if not TOKEN:
        raise SystemExit("GM_TOKEN is not set; refusing to start without one")
    if not PASSWORD_HASH:
        print("warning: no viewer password set; anyone on your tailnet can view the dashboard", flush=True)
    if ALLOW_ORIGINS:
        print("allowing websites: %s" % ", ".join(sorted(ALLOW_ORIGINS)), flush=True)

    addresses = [a.strip() for a in BIND.split(",") if a.strip()]
    for addr in addresses[1:]:
        threading.Thread(target=serve, args=(addr,), daemon=True).start()
    try:
        serve(addresses[0])
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
