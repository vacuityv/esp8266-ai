#!/usr/bin/env python3
"""AI-Clock relay: bridges the Mac (behind one WiFi) and the ESP8266 clock
(behind another) when they are NOT on the same LAN.

Two channels, both through this one relay:

  Telemetry (Mac -> clock):
    Mac  --POST /ingest/<key>-->  [latest blob]  <--GET /r/<secret>/...--  clock

  Control (v2, clock <-> Mac, reverse direction):
    clock --POST /r/<secret>/deviceinfo--> [device info] <--GET /control/deviceinfo-- Mac
    Mac   --POST /control/command--------> [cmd queue]   <--GET /r/<secret>/commands-- clock
    Mac   --POST /control/gif/<slot>-----> [gif blob]    <--GET /r/<secret>/gif/<slot>- clock

The clock authenticates with the capability path /r/<PULL_SECRET>/... (so the
firmware just appends paths to its bridgeHost). The Mac authenticates control
requests with `Authorization: Bearer <PUSH_TOKEN>`.

Zero third-party deps (Python stdlib only). Config via env:
    RELAY_PORT   listen port                 (default 8080)
    PUSH_TOKEN   Bearer token for the Mac    (required)
    PULL_SECRET  path segment for the clock  (required)
"""
import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("RELAY_PORT", "8080"))
PUSH_TOKEN = os.environ.get("PUSH_TOKEN", "")
PULL_SECRET = os.environ.get("PULL_SECRET", "")
if not PUSH_TOKEN or not PULL_SECRET:
    raise SystemExit("PUSH_TOKEN and PULL_SECRET must be set in the environment")

JSON = "application/json"
BIN = "application/octet-stream"
# telemetry key -> content type (mirror the Mac bridge's own routes 1:1)
KEYS = {"status": JSON, "net": JSON, "music": JSON, "cover": BIN, "text": BIN}
PULL_MAP = {"status": "status", "net": "net", "music": "music",
            "music/cover.raw": "cover", "music/text.raw": "text"}
PUSH_MAP = {"status": "status", "net": "net", "music": "music",
            "cover.raw": "cover", "text.raw": "text"}

MAX_COMMANDS = 50  # cap the queue so a spamming Mac + offline clock can't grow it unbounded

_lock = threading.Lock()
_store = {}          # telemetry key -> (bytes, ts)
_deviceinfo = None   # (bytes, ts) reported by the clock
_commands = []       # list of command dicts, Mac -> clock
_gifs = {}           # slot -> bytes, Mac -> clock


def eq(a: str, b: str) -> bool:
    return hmac.compare_digest(a or "", b or "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "aiclock-relay"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _bearer_ok(self):
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        return eq(token, PUSH_TOKEN)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(n) if n else b""

    # ---- GET ----
    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path in ("/", "/health"):
            now = time.time()
            with _lock:
                lines = []
                for k in KEYS:
                    if k in _store:
                        b, ts = _store[k]
                        lines.append(f"{k:9} {len(b):>7} bytes  {now - ts:6.1f}s ago")
                    else:
                        lines.append(f"{k:9} (none)")
                di = f"{now - _deviceinfo[1]:.1f}s ago" if _deviceinfo else "(none)"
                lines.append(f"deviceinfo {di}")
                lines.append(f"commands  {len(_commands)} pending")
                lines.append(f"gifs      {sorted(_gifs)}")
            return self._send(200, "aiclock-relay ok\n\n" + "\n".join(lines) + "\n")

        # Mac reads device info (Bearer)
        if path == "/control/deviceinfo":
            if not self._bearer_ok():
                return self._send(403, "forbidden")
            with _lock:
                di = _deviceinfo
            if di is None:
                return self._send(404, "no device info yet")
            body, ts = di
            return self._send(200, body, JSON, {"X-Relay-Age": str(int(time.time() - ts))})

        # Clock pulls (capability path /r/<secret>/...)
        if path.startswith("/r/"):
            secret, _, sub = path[len("/r/"):].partition("/")
            if not eq(secret, PULL_SECRET):
                return self._send(403, "forbidden")
            key = PULL_MAP.get(sub)
            if key is not None:                      # telemetry
                with _lock:
                    entry = _store.get(key)
                if entry is None:
                    return self._send(404, "no data yet")
                return self._send(200, entry[0], KEYS[key])
            if sub == "commands":                    # drain pending commands
                with _lock:
                    cmds = _commands[:]
                    _commands.clear()
                return self._send(200, json.dumps(cmds).encode(), JSON)
            if sub.startswith("gif/"):               # fetch a pending gif blob
                with _lock:
                    blob = _gifs.get(sub[len("gif/"):])
                if blob is None:
                    return self._send(404, "no gif")
                return self._send(200, blob, BIN)
            return self._send(404, "no such route")

        return self._send(404, "not found")

    do_HEAD = do_GET

    # ---- POST ----
    def do_POST(self):
        global _deviceinfo
        path = self.path.split("?", 1)[0]

        # Mac telemetry push (Bearer)
        if path.startswith("/ingest/"):
            if not self._bearer_ok():
                return self._send(403, "forbidden")
            key = PUSH_MAP.get(path[len("/ingest/"):])
            if key is None:
                return self._send(404, "no such ingest route")
            body = self._read_body()
            with _lock:
                _store[key] = (body, time.time())
            return self._send(200, "ok")

        # Mac enqueues a control command (Bearer)
        if path == "/control/command":
            if not self._bearer_ok():
                return self._send(403, "forbidden")
            try:
                cmd = json.loads(self._read_body())
            except Exception:
                return self._send(400, "bad json")
            if not isinstance(cmd, dict) or "type" not in cmd:
                return self._send(400, "command needs a type")
            with _lock:
                _commands.append(cmd)
                del _commands[:-MAX_COMMANDS]  # keep only the newest MAX_COMMANDS
            return self._send(200, "ok")

        # Mac uploads a gif blob for a slot (Bearer)
        if path.startswith("/control/gif/"):
            if not self._bearer_ok():
                return self._send(403, "forbidden")
            slot = path[len("/control/gif/"):]
            body = self._read_body()
            with _lock:
                _gifs[slot] = body
            return self._send(200, "ok")

        # Clock reports its /api/info (capability path)
        if path.startswith("/r/"):
            secret, _, sub = path[len("/r/"):].partition("/")
            if not eq(secret, PULL_SECRET):
                return self._send(403, "forbidden")
            if sub == "deviceinfo":
                body = self._read_body()
                with _lock:
                    _deviceinfo = (body, time.time())
                return self._send(200, "ok")
            return self._send(404, "no such route")

        return self._send(404, "not found")


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"[relay] listening on 0.0.0.0:{PORT}  telemetry + control channel", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
