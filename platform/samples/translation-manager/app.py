"""Translation Manager — MINIMAL representative (DB + SSO + scaling).

v1 support exercised: per-tenant DB (DATABASE_URL reachability) and company-Google
SSO via the platform. Scaling/HA is target-arch (v1 is one box). Minimal store to
represent the shape.
"""
import os, socket, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STORE = {"hello": {"fr": "bonjour", "es": "hola"}, "bye": {"fr": "au revoir"}}


def db_reachable():
    u = os.environ.get("DATABASE_URL", "")
    if "@" not in u:
        return False
    h, _, p = u.split("@", 1)[1].split("/", 1)[0].partition(":")
    try:
        socket.create_connection((h, int(p or 5432)), timeout=3).close()
        return True
    except OSError:
        return False


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "db_reachable": db_reachable(),
            "keys": list(STORE),
            "sso": "company Google (platform)",
            "scaling": "single box (v1); HA is target-arch",
        }).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8000))), H).serve_forever()
