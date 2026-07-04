"""Backups — nightly per-tenant pg_dump + a platform-state dump.

v1's honest backup story (README): a cron job, not WAL shipping — RPO of a day,
adequate for internal tools. Each tenant database and the kiosk metadata DB
(the platform state: apps, access, secrets, cron, audit) are dumped to the
`backups` volume, one timestamped directory per run.

pg_dump / psql run in one-shot `postgres` containers over the backplane, so the
kiosk image needs no postgres client. A restore drill (restore_drill) proves a
dump is usable — the v1 done-when "a restore-from-backup drill passes".
"""

from __future__ import annotations

import threading
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit

from . import audit, db, dockercli
from .config import config

PG_IMAGE = "postgres:16-alpine"
BACKUPS_VOLUME = "platform_backups"
BACKPLANE = "platform_backplane"


def _admin_password() -> str:
    return urlsplit(config.PG_ADMIN_URL).password or ""


def admin_url(dbname: str | None = None) -> str:
    """Admin connection URL with the password STRIPPED (it is passed separately
    via PGPASSWORD, never interpolated into a shell string — a `$`/quote/backtick
    in the operator's admin password must not break or inject into `sh -c`)."""
    u = urlsplit(config.PG_ADMIN_URL)
    host = u.hostname or "postgres"
    port = f":{u.port}" if u.port else ""
    userinfo = f"{u.username}@" if u.username else ""
    path = f"/{dbname}" if dbname else (u.path or "")
    return f"{u.scheme}://{userinfo}{host}{port}{path}"


def _pg(cmd: str, *, extra_args: list[str] | None = None, timeout: int = 600):
    """Run a shell command inside a one-shot postgres container with the backups
    volume mounted, PG* client tools available, and PGPASSWORD supplied via the
    container env (argv, not shell — so it can't break the `sh -c` string)."""
    args = ["run", "--rm", "--network", BACKPLANE,
            "-v", f"{BACKUPS_VOLUME}:/backups",
            "-e", f"PGPASSWORD={_admin_password()}", *(extra_args or []),
            PG_IMAGE, "sh", "-c", cmd]
    return dockercli.run(args, timeout=timeout)


def backup_all(log=lambda *_: None) -> dict:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    outdir = f"/backups/{stamp}"
    targets: list[tuple[str, str]] = [("_platform_state", admin_url())]
    for row in db.list_apps():
        t = db.get_tenant_db(row["slug"])
        if t:
            targets.append((t["dbname"], admin_url(t["dbname"])))

    done, failed = [], []
    mk = _pg(f"mkdir -p {outdir}")
    if not mk.ok:
        log(f"[backup] cannot create {outdir}: {mk.out[-200:]}")
        return {"ok": False, "stamp": stamp, "error": "mkdir failed"}

    for label, url in targets:
        res = _pg(f'pg_dump --no-owner --format=plain "{url}" > {outdir}/{label}.sql')
        (done if res.ok else failed).append(label)
        log(f"[backup] {label}: {'ok' if res.ok else 'FAILED'}")

    mirrored = _mirror_to_s3(log)
    audit.record("backup", "backup.run", detail={"stamp": stamp, "done": done,
                                                  "failed": failed, "mirrored": mirrored})
    return {"ok": not failed, "stamp": stamp, "done": done, "failed": failed,
            "dir": outdir, "mirrored_to_s3": mirrored}


def _mirror_to_s3(log) -> bool:
    """Best-effort copy of the backups tree to MinIO/S3 (off-box durability)."""
    if not (config.MINIO_ACCESS_KEY and config.MINIO_SECRET_KEY):
        return False
    script = (
        f'mc alias set m {config.MINIO_ENDPOINT} '
        f'{config.MINIO_ACCESS_KEY} {config.MINIO_SECRET_KEY} && '
        f'mc mb -p m/{config.MINIO_BUCKET} >/dev/null 2>&1; '
        f'mc mirror --overwrite --quiet /backups m/{config.MINIO_BUCKET}'
    )
    res = dockercli.run(
        ["run", "--rm", "--network", BACKPLANE,
         "-v", f"{BACKUPS_VOLUME}:/backups",
         "--entrypoint", "sh", "minio/mc:latest", "-c", script],
        timeout=180)
    log(f"[backup] S3 mirror {'ok' if res.ok else 'skipped'}")
    return res.ok


def latest_stamp() -> str | None:
    res = _pg("ls -1 /backups 2>/dev/null | sort | tail -1")
    out = res.out.strip()
    return out or None


def restore_drill(stamp: str | None = None, log=lambda *_: None) -> dict:
    """Restore the platform-state dump into a throwaway DB and assert it's
    queryable. Proves the backup is usable without touching live data."""
    stamp = stamp or latest_stamp()
    if not stamp:
        return {"ok": False, "error": "no backups found"}
    dump = f"/backups/{stamp}/_platform_state.sql"
    tmpdb = f"restore_drill_{int(time.time())}"

    log(f"[drill] restoring {dump} into {tmpdb}")
    create = _pg(f'psql "{admin_url()}" -c "CREATE DATABASE {tmpdb}"')
    if not create.ok:
        return {"ok": False, "error": f"create failed: {create.out[-200:]}"}
    try:
        # ON_ERROR_STOP=1: a dump that fails to replay makes psql exit non-zero,
        # so a corrupt/partial backup fails the drill instead of silently passing.
        restore = _pg(f'psql "{admin_url(tmpdb)}" -v ON_ERROR_STOP=1 -f {dump}')
        check = _pg(f'psql "{admin_url(tmpdb)}" -tAc '
                    f'"SELECT count(*) FROM apps"')
        rows = check.out.strip()
        ok = restore.ok and check.ok and rows.isdigit()
        if not restore.ok:
            log(f"[drill] restore FAILED: {restore.out.strip()[-300:]}")
        log(f"[drill] restored; apps rows = {rows!r}; ok={ok}")
        audit.record("backup", "restore.drill", detail={"stamp": stamp, "ok": ok,
                                                         "apps_rows": rows})
        return {"ok": ok, "stamp": stamp, "apps_rows": rows}
    finally:
        _pg(f'psql "{admin_url()}" -c "DROP DATABASE IF EXISTS {tmpdb}"')


def start_nightly() -> None:
    def _loop():
        # Simple daily cadence; run ~10s after start once, then every 24h.
        first = True
        while True:
            time.sleep(10 if first else 24 * 3600)
            first = False
            try:
                backup_all()
            except Exception as e:  # noqa: BLE001
                print(f"[backup] nightly error: {e}", flush=True)
    threading.Thread(target=_loop, daemon=True).start()
    print("[backup] nightly backups scheduled", flush=True)
