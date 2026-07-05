"""ADM Tracker — MINIMAL representative (Pilot 2 shape) on v1 capabilities.

Real needs: DB, per-user RBAC, email reports, ⚠️ PNR/booking data.
What v1 supports and this app exercises:
  * DB      — per-tenant DATABASE_URL is injected; we prove reachability.
  * Access  — set the app INVITE-ONLY in the Kiosk (whole-app allow-list).
  * Secret  — REPORT_WEBHOOK injected from the encrypted secrets store.
  * Cron    — report.py runs on a schedule to send the report.
  * Egress  — the webhook host is added to the app's egress allow-list.
NOT in v1 (needs M3): per-route Viewer/Editor/Admin. Whole-app invite-only is the
closest supported control; PNR data would set the classification / hardened gate.
"""
import os, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def db_reachable():
    url = os.environ.get("DATABASE_URL", "")
    if "@" not in url:
        return False, "no DATABASE_URL"
    host, _, port = url.split("@", 1)[1].split("/", 1)[0].partition(":")
    try:
        socket.create_connection((host, int(port or 5432)), timeout=3).close()
        return True, f"{host}:{port or 5432}"
    except OSError as e:
        return False, str(e)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        ok, detail = db_reachable()
        secret = "set" if os.environ.get("REPORT_WEBHOOK") else "unset"
        body = (
            "ADM Tracker (minimal) — Pilot 2 shape on v1\n"
            f"DB reachable: {ok} ({detail})\n"
            f"report webhook secret: {secret}\n"
            "access: whole-app invite-only (set in Kiosk) | RBAC roles: deferred to M3\n"
            "classification: PNR/booking -> hardened-tier gate (flag)\n"
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8000))), H).serve_forever()
