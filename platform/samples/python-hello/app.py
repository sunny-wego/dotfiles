"""Trivial Flask app for the M1 walking-skeleton smoke test.

Binds 0.0.0.0:$PORT. The platform injects PORT; the generated Dockerfile is
expected to serve on it (gunicorn in prod, or `flask run` — the LLM decides).
"""

import os

from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    return "hello from python-hello\n"


@app.route("/healthz")
def healthz():
    return {"ok": True}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
