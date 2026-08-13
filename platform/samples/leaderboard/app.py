"""Pilot 1 — AI Engineering Leaderboard.

Leaderboard-shaped internal app exercising the v1 add-ons:
  * DB      — reads/writes scores in the injected per-tenant Postgres (DATABASE_URL)
  * Cron    — recompute.py runs on a schedule to refresh ranks
  * internal-network — no external egress needed (default-deny is fine)

Binds 0.0.0.0:$PORT. The platform injects PORT + DATABASE_URL; nothing is
hand-configured. This mirrors what the app did on Vercel, now self-served.
"""

import html
import os

import psycopg
from flask import Flask, redirect, request

app = Flask(__name__)
DB = os.environ["DATABASE_URL"]


def init_db():
    with psycopg.connect(DB) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS scores (
            id SERIAL PRIMARY KEY, name TEXT NOT NULL, points INT NOT NULL DEFAULT 0)""")


@app.route("/")
def index():
    with psycopg.connect(DB) as c:
        rows = c.execute(
            "SELECT name, points FROM scores ORDER BY points DESC, name LIMIT 20"
        ).fetchall()
    # Escape names at render time — they're user-submitted (stored XSS otherwise).
    items = "".join(f"<li>{html.escape(n)} — <b>{p}</b></li>" for n, p in rows) \
        or "<li>no scores yet</li>"
    return f"""<h1>🏆 AI Engineering Leaderboard</h1><ol>{items}</ol>
      <form method=post action=/add>
        <input name=name placeholder=name>
        <input name=points type=number value=1>
        <button>add points</button>
      </form>"""


@app.route("/add", methods=["POST"])
def add():
    # Cap length and drop control chars on ingest (defense in depth).
    name = "".join(c for c in request.form.get("name", "").strip()
                   if c.isprintable())[:80]
    points = int(request.form.get("points", "0") or 0)
    if name:
        with psycopg.connect(DB) as c:
            c.execute(
                "INSERT INTO scores (name, points) VALUES (%s, %s) "
                "ON CONFLICT (id) DO NOTHING", (name, points))
    return redirect("/")


@app.route("/healthz")
def healthz():
    return {"ok": True}


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
