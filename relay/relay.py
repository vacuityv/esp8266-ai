#!/usr/bin/env python3
"""AI-Clock relay: bridges the Mac (behind one WiFi) and the ESP8266 clock
(behind another) when they are NOT on the same LAN.

Data flow:

    Mac  --POST /ingest/<key>-->  [relay, keeps latest blob in RAM]  <--GET /r/<secret>/...--  clock

The clock's `bridgeHost` is set to  <host>:<port>/r/<secret>  so its existing
polls (GET .../status, .../net, .../music, .../music/cover.raw, .../music/text.raw)
hit us and get back the exact bytes the Mac last pushed. No firmware change.

Zero third-party deps (Python stdlib only). Config via env:
    RELAY_PORT     listen port                 (default 8080)
    PUSH_TOKEN     Bearer token the Mac must send on /ingest/*   (required)
    PULL_SECRET    path segment the clock must include on /r/*   (required)
"""
import hmac
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("RELAY_PORT", "8080"))
PUSH_TOKEN = os.environ.get("PUSH_TOKEN", "")
PULL_SECRET = os.environ.get("PULL_SECRET", "")
if not PUSH_TOKEN or not PULL_SECRET:
    raise SystemExit("PUSH_TOKEN and PULL_SECRET must be set in the environment")

# key -> (content_type). These mirror the Mac bridge's own routes 1:1.
JSON = "application/json"
BIN = "application/octet-stream"
KEYS = {
    "status": JSON,
    "net": JSON,
    "music": JSON,
    "cover": BIN,
    "text": BIN,
}
# clock pull path (after the /r/<secret>/ prefix) -> internal key
PULL_MAP = {
    "status": "status",
    "net": "net",
    "music": "music",
    "music/cover.raw": "cover",
    "music/text.raw": "text",
}
# Mac push path (after /ingest/) -> internal key
PUSH_MAP = {
    "status": "status",
    "net": "net",
    "music": "music",
    "cover.raw": "cover",
    "text.raw": "text",
}

_lock = threading.Lock()
_store = {}  # key -> (bytes, updated_epoch)


def eq(a: str, b: str) -> bool:
    return hmac.compare_digest(a or "", b or "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "aiclock-relay"

    # Quieter logs: one line per request is enough, and skip the noisy poll spam.
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        # Health / debug page — no secret required, exposes no payloads.
        if path in ("/", "/health"):
            now = time.time()
            with _lock:
                lines = []
                for k in KEYS:
                    if k in _store:
                        b, ts = _store[k]
                        lines.append(f"{k:7} {len(b):>7} bytes  {now - ts:6.1f}s ago")
                    else:
                        lines.append(f"{k:7} (none)")
            return self._send(200, "aiclock-relay ok\n\n" + "\n".join(lines) + "\n")

        # Clock pull: /r/<secret>/<pull-path>
        if path.startswith("/r/"):
            rest = path[len("/r/"):]
            secret, _, sub = rest.partition("/")
            if not eq(secret, PULL_SECRET):
                return self._send(403, "forbidden")
            key = PULL_MAP.get(sub)
            if key is None:
                return self._send(404, "no such route")
            with _lock:
                entry = _store.get(key)
            if entry is None:
                # Nothing pushed yet — clock treats non-200 as "skip this poll".
                return self._send(404, "no data yet")
            body, _ = entry
            return self._send(200, body, KEYS[key])

        return self._send(404, "not found")

    do_HEAD = do_GET

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith("/ingest/"):
            return self._send(404, "not found")

        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        if not eq(token, PUSH_TOKEN):
            return self._send(403, "forbidden")

        key = PUSH_MAP.get(path[len("/ingest/"):])
        if key is None:
            return self._send(404, "no such ingest route")

        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        with _lock:
            _store[key] = (body, time.time())
        return self._send(200, "ok")


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    print(f"[relay] listening on 0.0.0.0:{PORT}  pull=/r/<secret>/...  push=/ingest/...", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
