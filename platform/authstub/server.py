"""Dev-auth stub — the README's "dev-mode identity stub that bypasses Google".

Answers Traefik's forward-auth probe (`GET /oauth2/auth`) with 202 and injects a
fixed dev identity, so the whole platform runs locally with no Google OAuth,
redirect URIs, or TLS/DNS ceremony. Selected by AUTH_MODE=dev.

This is a *dev* convenience only. The company-domain guarantee ("non-company
account is denied") is NOT weakened by using it: the kiosk enforces the domain
on every request in both modes, so pointing DEV_USER_EMAIL at a non-company
address exercises the denial path exactly as Google would trigger it.
"""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEV_EMAIL = os.environ.get("DEV_USER_EMAIL", "dev@wego.com")
DEV_USER = DEV_EMAIL.split("@", 1)[0]


class Handler(BaseHTTPRequestHandler):
    def _auth(self):
        self.send_response(202)
        self.send_header("X-Auth-Request-Email", DEV_EMAIL)
        self.send_header("X-Auth-Request-User", DEV_USER)
        self.send_header("X-Auth-Request-Preferred-Username", DEV_USER)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/oauth2/auth"):
            self._auth()
        elif self.path.startswith("/oauth2/"):
            # start / callback / sign-out are no-ops under the stub.
            self.send_response(204)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):  # keep the container log quiet
        pass


if __name__ == "__main__":
    print(f"[authstub] dev identity = {DEV_EMAIL}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 4180), Handler).serve_forever()
