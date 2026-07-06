#!/usr/bin/env python3
"""Coolify API contract probe — Layer A of the parity gate.

Drives the *shipped* CoolifyClient (not a re-implementation) against a live
Coolify, exercising every endpoint the kiosk uses: create-from-image, env
replace+prune, update (labels/limits/domain), deploy trigger, status, logs, the
scheduled-task lifecycle (create → list → update → delete), and the per-tenant
database lifecycle (create Postgres → read internal_db_url → configure native
backup → delete). Each step is reported PASS/FAIL with the failing endpoint, so a
contract mismatch against the deployed Coolify version is pinpointed rather than
discovered app-by-app.

Creates a throwaway `parity-probe` app from a trivial public image and deletes it
at the end (PARITY_KEEP=1 leaves it up, e.g. for the Layer-B auth-chain 403 check).

Reads config from the environment (the same COOLIFY_* the kiosk uses); run it via
`coolify/parity-gate.sh`, which sources `.env` first. Exit 0 = all passed, 1 =
a check failed, 2 = not configured.
"""
from __future__ import annotations

import os
import pathlib
import sys
import time

# Import the kiosk's real client + label builder (client.py has no heavy deps).
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "kiosk"))
from app.backends.coolify.client import CoolifyClient, CoolifyError  # noqa: E402
from app.backends import labels  # noqa: E402

REQUIRED = ["COOLIFY_BASE_URL", "COOLIFY_API_TOKEN", "COOLIFY_PROJECT_UUID",
            "COOLIFY_SERVER_UUID", "COOLIFY_ENVIRONMENT_UUID"]


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


class Probe:
    def __init__(self) -> None:
        self.results: list[tuple[str, bool, str]] = []

    def step(self, name, fn):
        try:
            value = fn()
            self.results.append((name, True, ""))
            return value
        except Exception as e:  # noqa: BLE001 — any failure is a gate failure
            self.results.append((name, False, str(e)[:300]))
            return None

    def note(self, name, ok, detail=""):
        self.results.append((name, ok, detail))

    def report(self) -> int:
        print("\n── Coolify contract probe ─────────────────────────────")
        width = max((len(n) for n, _, _ in self.results), default=0)
        for name, ok, detail in self.results:
            mark = "PASS" if ok else "FAIL"
            line = f"  [{mark}] {name.ljust(width)}"
            if detail:
                line += f"  — {detail}"
            print(line)
        failed = [n for n, ok, _ in self.results if not ok]
        print("───────────────────────────────────────────────────────")
        if failed:
            print(f"  {len(failed)} FAILED: {', '.join(failed)}")
            print("  → adjust kiosk/app/backends/coolify/client.py to match this "
                  "Coolify version, then re-run.")
            return 1
        print(f"  all {len(self.results)} contract checks passed")
        return 0


def _assert(cond: bool, msg: str):
    if not cond:
        raise AssertionError(msg)
    return True


def main() -> int:
    missing = [k for k in REQUIRED if not _env(k)]
    if missing:
        print(f"not configured — set: {', '.join(missing)}", file=sys.stderr)
        return 2

    client = CoolifyClient(_env("COOLIFY_BASE_URL"), _env("COOLIFY_API_TOKEN"),
                           timeout=float(_env("COOLIFY_TIMEOUT_S", "30")))
    domain = _env("PLATFORM_DOMAIN", "apps.localhost")
    slug = "parity-probe"
    host = f"{slug}.{domain}"
    image = _env("PARITY_IMAGE", "traefik/whoami")
    tag = _env("PARITY_IMAGE_TAG", "latest")
    port = int(_env("PARITY_PORT", "80"))
    net = _env("COOLIFY_TENANT_NETWORK", "platform_tenant")

    p = Probe()
    uuid = None
    try:
        uuid = p.step("create_image_app", lambda: client.create_image_app(
            project_uuid=_env("COOLIFY_PROJECT_UUID"),
            server_uuid=_env("COOLIFY_SERVER_UUID"),
            environment_name=_env("COOLIFY_ENVIRONMENT", "production"),
            environment_uuid=_env("COOLIFY_ENVIRONMENT_UUID"),
            destination_uuid=_env("COOLIFY_DESTINATION_UUID"),
            name=slug, image=image, tag=tag, port=port, domain=host))

        if not uuid:
            p.note("remaining checks", False, "skipped — create failed")
            return p.report()

        label_map = labels.tenant_label_map(slug, host, port, net)
        p.step("update_app (labels/limits/domain)", lambda: client.update_app(uuid, {
            "docker_registry_image_name": image,
            "docker_registry_image_tag": tag,
            "domains": f"https://{host}",
            "ports_exposes": str(port),
            "custom_labels": CoolifyClient.encode_custom_labels(label_map),
        }))
        p.step("replace_envs (upsert)",
               lambda: client.replace_envs(uuid, {"PARITY": "1", "PORT": str(port)}))
        p.step("list_envs contains upserted key", lambda: _assert(
            any(e.get("key") == "PARITY" for e in client.list_envs(uuid)),
            "PARITY not present after upsert"))
        p.step("replace_envs (prune removed key)",
               lambda: client.replace_envs(uuid, {"PORT": str(port)}))
        p.step("list_envs pruned removed key", lambda: _assert(
            not any(e.get("key") == "PARITY" for e in client.list_envs(uuid)),
            "PARITY still present after prune"))
        p.step("deploy trigger", lambda: client.deploy(uuid, True))
        p.step("app_status reachable", lambda: client.app_status(uuid))
        _poll_running(client, uuid, p)
        p.step("logs", lambda: client.logs(uuid, lines=20))

        p.step("create_scheduled_task", lambda: client.create_scheduled_task(
            uuid, name="parity-cron", command="echo ok", frequency="0 0 * * *"))
        task = p.step("list_scheduled_tasks has it", lambda: _find_task(client, uuid))
        if task:
            tid = task.get("uuid") or task.get("id")
            p.step("update_scheduled_task", lambda: client.update_scheduled_task(
                uuid, tid, name="parity-cron", command="echo updated",
                frequency="0 1 * * *"))
            p.step("delete_scheduled_task",
                   lambda: client.delete_scheduled_task(uuid, tid))
            p.step("scheduled task gone", lambda: _assert(
                _find_task(client, uuid) is None, "task still listed after delete"))

        # ── per-tenant database lifecycle (the DB move) ──────────────────────
        _probe_database(client, p)
    finally:
        if uuid and _env("PARITY_KEEP") != "1":
            p.step("delete_app (cleanup)", lambda: client.delete_app(uuid))
        elif uuid:
            print(f"  (PARITY_KEEP=1 — left app up at https://{host} for the "
                  "auth-chain 403 check)")

    return p.report()


def _probe_database(client, p):
    """Create a throwaway Coolify Postgres, read its connection URL back, attach
    a native scheduled backup, then delete it — the exact path provision_db uses.
    Pins the response shapes (internal_db_url, backup uuid) the kiosk depends on."""
    db_uuid = p.step("create_postgres", lambda: client.create_postgres(
        project_uuid=_env("COOLIFY_PROJECT_UUID"),
        server_uuid=_env("COOLIFY_SERVER_UUID"),
        environment_name=_env("COOLIFY_ENVIRONMENT", "production"),
        environment_uuid=_env("COOLIFY_ENVIRONMENT_UUID"),
        destination_uuid=_env("COOLIFY_DESTINATION_UUID"),
        name="parity-probe-db", db_name="d_parity", db_user="t_parity",
        db_password="parity-probe-pw"))
    if not db_uuid:
        p.note("database checks", False, "skipped — create_postgres failed")
        return
    try:
        p.step("database_url exposes internal_db_url", lambda: _assert(
            client.database_url(db_uuid).startswith("postgresql://"),
            "internal_db_url missing or wrong scheme"))
        p.step("create_backup (native scheduled backup)",
               lambda: client.create_backup(db_uuid, frequency="daily"))
        p.step("list_backups has it", lambda: _assert(
            len(client.list_backups(db_uuid)) >= 1, "no scheduled backup listed"))
    finally:
        p.step("delete_database (cleanup)",
               lambda: client.delete_database(db_uuid))


def _find_task(client, uuid, name="parity-cron"):
    for task in client.list_scheduled_tasks(uuid):
        if task.get("name") == name:
            return task
    raise AssertionError(f"scheduled task {name!r} not found")


def _poll_running(client, uuid, p, timeout=120, interval=6):
    """Best-effort: wait for the container to report a status containing
    'running'. Reported as its own check but with a soft note — a slow image
    pull shouldn't fail the *contract* probe, only signal it didn't come up."""
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            last = client.app_status(uuid)
        except CoolifyError as e:
            last = f"error: {e}"
        if "running" in last.lower() or "healthy" in last.lower():
            p.note("app became running", True, last)
            return
        if any(m in last.lower() for m in ("exited", "error", "failed")):
            p.note("app became running", False, f"status={last}")
            return
        time.sleep(interval)
    p.note("app became running", False, f"still '{last}' after {timeout}s "
           "(soft — check image pull / registry trust)")


if __name__ == "__main__":
    raise SystemExit(main())
