"""Cron command for the leaderboard — decays stale points nightly.

Registered in the Kiosk as a scheduled task (e.g. `0 9 * * *` running
`python recompute.py`). Runs in a one-shot container of the app image with the
same injected DATABASE_URL, then exits.
"""

import os

import psycopg

with psycopg.connect(os.environ["DATABASE_URL"]) as c:
    c.execute("UPDATE scores SET points = GREATEST(points - 1, 0)")
    total = c.execute("SELECT count(*) FROM scores").fetchone()[0]
print(f"recomputed leaderboard: {total} entries")
