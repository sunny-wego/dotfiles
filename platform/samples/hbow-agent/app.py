"""hbow agent — MINIMAL representative (long-running agent/container).

Real needs: a long-running agent that forks work.
v1 support exercised: a container that runs indefinitely doing background work;
the platform keeps it up (restart=unless-stopped) and Uptime-Kuma watches it. It
serves a status page so the deploy verify probe can confirm it's alive.
"""
import os, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"ticks": 0, "started": time.time()}


def agent_loop():
    while True:
        STATE["ticks"] += 1          # stand-in for real agent work
        time.sleep(2)


threading.Thread(target=agent_loop, daemon=True).start()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        up = int(time.time() - STATE["started"])
        body = f"hbow agent alive — uptime {up}s, {STATE['ticks']} work-ticks\n".encode()
        self.send_response(200)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8000))), H).serve_forever()
