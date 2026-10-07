#!/usr/bin/env python3
"""Minimal webhook receiver: verifies SurfScore signatures and prints session events.

1. Run it somewhere reachable over HTTPS (behind a tunnel such as `cloudflared tunnel --url http://localhost:8080`
   while developing).
2. Register the endpoint once (scope manage:webhooks); keep the `whsec_` secret it returns — it is shown once:

       curl -s -X POST https://api.surfscore.live/v1/webhooks \
         -H "Authorization: Bearer $SS_KEY" -H 'Content-Type: application/json' \
         -d '{"url":"https://your-host.example/surfscore","events":["session.completed"]}'

3. Start the listener:   WEBHOOK_SECRET=whsec_... python3 webhook_listener.py 8080

Headers you receive: X-Surfscore-Event, X-Surfscore-Delivery (dedupe key; deliveries are at-least-once),
X-Surfscore-Signature "t=<unix>,v1=<hex HMAC-SHA256 of '<t>.<raw body>'>".
Reply 2xx within 10 s or the delivery is retried (1m, 5m, 30m, 2h, 8h).
"""
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = os.environ.get("WEBHOOK_SECRET", "").encode()
SEEN = set()  # replace with a durable store in production


def verify(sig_header: str, raw: bytes) -> bool:
    # A missing or malformed header is a failed check (401), not a crash.
    parts = dict(p.split("=", 1) for p in sig_header.split(",") if "=" in p)
    t, their = parts.get("t"), parts.get("v1")
    if not t or not their or not t.isdigit() or abs(time.time() - int(t)) > 300:
        return False
    expected = hmac.new(SECRET, f"{t}.".encode() + raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, their)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if not verify(self.headers.get("X-Surfscore-Signature", ""), raw):
            self.send_response(401); self.end_headers(); return
        delivery = self.headers.get("X-Surfscore-Delivery")
        self.send_response(204); self.end_headers()        # ack first, work after
        if delivery in SEEN:
            return
        SEEN.add(delivery)
        payload = json.loads(raw)
        s = payload["session"]
        print(f"{payload['event']}  session={s['id']} mode={s['session_mode']} started={s['started_at']} ended={s.get('ended_at')}")
        # e.g. on session.completed: subprocess.run(["./export_session.sh", s["id"]], stdout=open(f"{s['id']}.csv","w"))

    def log_message(self, *_):  # quieter default log
        pass


if __name__ == "__main__":
    if not SECRET:
        sys.exit("set WEBHOOK_SECRET to the whsec_... value returned when you registered the endpoint")
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"listening on :{port}", file=sys.stderr)
    HTTPServer(("", port), Handler).serve_forever()
