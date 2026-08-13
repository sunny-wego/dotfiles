"""Lightweight monitor — disk alert + async-deploy reconciler.

v1's observability floor (README): "Kiosk-surfaced logs + Uptime-Kuma + a disk
alert." Uptime-Kuma is a separate service; this thread covers the host disk
alert. Per-tenant database size + resource limits are now owned by Coolify (each
tenant DB is its own Coolify-managed resource with limits + native backups), so
the kiosk no longer runs a size-quota loop — that's observed in the Coolify
dashboard. The disk alert escalates via Slack + audit; it is not destructive.
"""

from __future__ import annotations

import shutil
import threading
import time
from datetime import datetime, timezone

from . import db, deployer, slack
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
            # Still pending — give up only if it has been stuck past the timeout,
            # so an unmapped status or an unreachable Coolify can't hang forever.
            if _deploying_too_long(row):
                db.set_app_status(slug, "failed")
                slack.escalate("monitor", slug,
                               f"Deploy stuck 'deploying' for over "
                               f"{config.DEPLOY_TIMEOUT_S}s — marking failed")
            continue
        db.set_app_status(slug, state)
        if state == "failed":
            slack.escalate("monitor", slug,
                           "Coolify deploy did not become healthy")


def _deploying_too_long(row: dict) -> bool:
    updated = row.get("updated_at")
    if not isinstance(updated, datetime):
        return False
    if updated.tzinfo is None:
        updated = updated.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - updated).total_seconds() > config.DEPLOY_TIMEOUT_S


def _check_disk() -> None:
    total, used, free = shutil.disk_usage("/")
    pct = round(used / total * 100)
    if pct >= DISK_ALERT_PCT:
        slack.escalate("monitor", "-",
                       f"Disk usage at {pct}% (free {free // (1024**3)} GiB) — "
                       "prune images/volumes before the box fills")
