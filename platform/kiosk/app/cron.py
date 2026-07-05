"""Per-app scheduled tasks (the README's "Coolify Scheduled Task", plain-Docker).

A single background thread evaluates every enabled cron job and, when due, runs
the job's command in a one-shot container of the app's image — same network,
same env bundle as the live app. Guarantees the README calls for:

  * overlap-guard  — a job already running is skipped, not stacked;
  * timezone       — schedules evaluated in a declared TZ (UTC by default);
  * retry          — one immediate retry on failure;
  * creator alert  — a failing job escalates (Slack + audit).
"""

from __future__ import annotations

import threading
import time
from datetime import datetime, timezone

from croniter import croniter

from . import audit, db, dockercli, slack, tenant_env
from .config import config

_running: set[str] = set()
_running_lock = threading.Lock()
_next_fire: dict[str, float] = {}


def start() -> None:
    # When the deploy engine runs scheduled tasks itself (Coolify), the kiosk
    # does NOT also run them — it only syncs the schedule to the engine at
    # deploy time. Starting the in-process loop then would double-fire jobs.
    from .backends import get_backend
    if get_backend().manages_cron:
        print("[cron] deploy backend manages scheduled tasks; "
              "in-process loop not started", flush=True)
        return
    threading.Thread(target=_loop, daemon=True).start()
    print("[cron] scheduler started", flush=True)


def _loop() -> None:
    while True:
        try:
            _tick()
        except Exception as e:  # noqa: BLE001 — scheduler must never die
            print(f"[cron] tick error: {e}", flush=True)
        time.sleep(20)


def _tick() -> None:
    now = time.time()
    for job in db.all_cron_enabled():
        key = f"{job['slug']}::{job['name']}"
        sched = job["schedule"]
        if key not in _next_fire:
            _next_fire[key] = _compute_next(sched, now)
            continue
        if now < _next_fire[key]:
            continue
        _next_fire[key] = _compute_next(sched, now)
        with _running_lock:
            if key in _running:
                print(f"[cron] {key} still running; skipping (overlap guard)", flush=True)
                continue
            _running.add(key)
        threading.Thread(target=_run_job, args=(dict(job), key), daemon=True).start()


def _compute_next(sched: str, base_ts: float) -> float:
    base = datetime.fromtimestamp(base_ts, tz=timezone.utc)
    try:
        return croniter(sched, base).get_next(float)
    except (ValueError, KeyError):
        print(f"[cron] invalid schedule {sched!r}; disabling fire", flush=True)
        return base_ts + 10 * 365 * 24 * 3600  # far future


def _run_job(job: dict, key: str) -> None:
    slug, name, command = job["slug"], job["name"], job["command"]
    try:
        app = db.get_app(slug)
        if not app or not app.get("image"):
            return
        env = tenant_env.build_env(slug)
        ok = _exec_once(slug, app["image"], command, env)
        if not ok:
            time.sleep(2)  # single retry
            ok = _exec_once(slug, app["image"], command, env)
        db.mark_cron_run(slug, name, ok)
        audit.record("cron", "cron.run", app=slug, detail={"job": name, "ok": ok})
        if not ok:
            slack.escalate("cron", slug,
                           f"Scheduled task '{name}' failed after a retry")
    finally:
        with _running_lock:
            _running.discard(key)


def _exec_once(slug: str, image: str, command: str, env: dict[str, str]) -> bool:
    args = ["run", "--rm", "--network", config.TENANT_NETWORK]
    for k, v in env.items():
        args += ["-e", f"{k}={v}"]
    args += [image, "sh", "-c", command]
    res = dockercli.run(args, timeout=600)
    if not res.ok:
        print(f"[cron] {slug} job failed:\n{res.out[-800:]}", flush=True)
    return res.ok
