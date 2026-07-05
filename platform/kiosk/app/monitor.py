"""Lightweight monitor — disk alert + per-tenant DB size quota.

v1's observability floor (README): "Kiosk-surfaced logs + Uptime-Kuma + a disk
alert." Uptime-Kuma is a separate service; this thread covers the disk alert and
enforces the per-database size quota the shared cluster needs (Postgres has no
native per-db quota). Both escalate via Slack + audit; neither is destructive.
"""

from __future__ import annotations

import shutil
import threading
import time

from . import db, deployer, provision_db, slack
from .config import config

DISK_ALERT_PCT = 85
# Coolify deploys are async; poll their real state often enough that the UI's
# "deploying" badge advances promptly, but not so often it hammers the API.
RECONCILE_INTERVAL = 15


def start() -> None:
    threading.Thread(target=_loop, daemon=True).start()
    threading.Thread(target=_reconcile_loop, daemon=True).start()
    print("[monitor] started", flush=True)


def _loop() -> None:
    while True:
        try:
            _check_disk()
            _check_quotas()
        except Exception as e:  # noqa: BLE001
            print(f"[monitor] error: {e}", flush=True)
        time.sleep(300)


def _reconcile_loop() -> None:
    """Advance apps left in 'deploying' by the async Coolify trigger to their
    real running/failed state, so a failed async deploy never shows a false
    green (and a slow one flips to running once healthy)."""
    while True:
        try:
            _reconcile_deploys()
        except Exception as e:  # noqa: BLE001
            print(f"[monitor] reconcile error: {e}", flush=True)
        time.sleep(RECONCILE_INTERVAL)


def _reconcile_deploys() -> None:
    for row in db.list_apps():
        if row.get("status") != "deploying":
            continue
        slug = row["slug"]
        state = deployer.deploy_status(slug)
        if state == "deploying":
            continue
        db.set_app_status(slug, state)
        if state == "failed":
            slack.escalate("monitor", slug,
                           "Coolify deploy did not become healthy")


def _check_disk() -> None:
    total, used, free = shutil.disk_usage("/")
    pct = round(used / total * 100)
    if pct >= DISK_ALERT_PCT:
        slack.escalate("monitor", "-",
                       f"Disk usage at {pct}% (free {free // (1024**3)} GiB) — "
                       "prune images/volumes before the box fills")


def _check_quotas() -> None:
    limit = config.TENANT_DB_QUOTA_MB
    for row in db.list_apps():
        slug = row["slug"]
        size = provision_db.db_size_mb(slug)
        if size is not None and size > limit:
            slack.escalate("monitor", slug,
                           f"Database is {size} MB, over the {limit} MB quota")
