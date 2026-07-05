"""EnzoBot / self-host — MINIMAL representative ("a blessed home").

Real needs: a governed home for an existing self-hosted bot; visibility.
v1 support exercised: a secret (BOT_TOKEN) from the encrypted store, an
allow-listed outbound call (egress via injected HTTPS_PROXY), and platform-provided
governance — it appears in the Kiosk catalog with an owner + append-only audit.
"""
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        tok = "configured" if os.environ.get("BOT_TOKEN") else "unset"
        proxy = os.environ.get("HTTPS_PROXY", "none (no egress allow-list yet)")
        body = (
            "EnzoBot (minimal self-host)\n"
            f"BOT_TOKEN secret: {tok}\n"
            f"egress via: {proxy}\n"
            "governance: Kiosk catalog + owner + append-only audit\n"
        ).encode()
        self.send_response(200)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8000))), H).serve_forever()
