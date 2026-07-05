"""Coolify deploy backend — drives Coolify's REST API on the creator's behalf.

Maps the platform's deploy contract onto Coolify resources:

  * deploy-from-image  → create/update a Docker-image application, push the env
                         bundle into Coolify's encrypted env store, set the FQDN
                         (Coolify-managed Traefik does TLS), set CPU/mem limits,
                         attach the auth-chain via custom Traefik labels, trigger
                         an (async) deploy.
  * cron               → Coolify Scheduled Tasks (the kiosk has no in-process
                         scheduler; it only syncs each app's schedule to Coolify).
  * admin plane        → the Coolify dashboard (operators), at COOLIFY_BASE_URL.

The auth chain (strip-auth-in → slug → forwardauth → appauthz) is applied via the
`labels` builder as Coolify application custom labels. The `@file` middlewares it
references must exist in Coolify's proxy — see `platform/coolify/traefik-dynamic.yml`
and the runbook.

Deploys on Coolify are asynchronous: `deploy` returns once the deploy is
*accepted*, not once the container is live. The caller therefore leaves the app
in `deploying`, and `deploy_status` (polled by the monitor reconciler) advances
it to `running`/`failed` from Coolify's real state — so a failed async deploy
never shows a false green.
"""

from __future__ import annotations

from ... import db, dockercli, tenant_env
from ...config import config
from .. import labels
from .client import CoolifyClient, CoolifyError

# Coolify status substrings → the kiosk's app status. Checked in order.
_FAILED_MARKERS = ("exited", "error", "failed", "degraded", "unhealthy", "stopped")


class CoolifyBackend:
    """Drives Coolify for all deploy/cron/rollback/logs operations. Cron runs as
    Coolify Scheduled Tasks (no kiosk-side scheduler); per-tenant pg_dump backups
    stay in the kiosk (README §3)."""

    name = "coolify"

    def __init__(self) -> None:
        self._client = CoolifyClient(
            config.COOLIFY_BASE_URL, config.COOLIFY_API_TOKEN,
            timeout=config.COOLIFY_TIMEOUT_S)

    # ── deploy ─────────────────────────────────────────────────────────────────
    def deploy(self, slug: str, image: str, port: int,
               env: dict[str, str] | None = None) -> tuple[bool, str, str]:
        host = config.app_host(slug)
        name, tag = dockercli.split_image_ref(image)
        full_env = {"PORT": str(port), **(env or {})}
        try:
            uuid = self._ensure_app(slug, name, tag, port, host)
            # replace_envs (not a bare upsert) so a removed/rotated secret is
            # actually deleted from Coolify's env store, not just left behind.
            self._client.replace_envs(uuid, full_env)
            # One PATCH carries the whole desired state — image, FQDN, port,
            # limits and the auth-chain labels — then we trigger the deploy.
            self._client.update_app(uuid, self._app_fields(slug, name, tag, port, host))
            self._client.deploy(uuid, force=True)
        except CoolifyError as e:
            return False, "", f"Coolify deploy failed: {e}"
        # Best-effort: sync scheduled tasks (reuse the uuid we already resolved).
        self.sync_cron(slug, uuid=uuid)
        return (True, f"https://{host}",
                "deploy triggered on Coolify (async) behind Google login + allow-list")

    def _ensure_app(self, slug: str, name: str, tag: str, port: int,
                    host: str) -> str:
        """Return the Coolify app UUID for this slug, creating the record on
        first deploy and reusing it thereafter. On reuse, the image tag and every
        other setting are (re)applied by the `update_app` that follows — so there
        is no separate image PATCH. Idempotent."""
        uuid = db.get_coolify_uuid(slug)
        if uuid:
            return uuid
        uuid = self._client.create_image_app(
            project_uuid=config.COOLIFY_PROJECT_UUID,
            server_uuid=config.COOLIFY_SERVER_UUID,
            environment_name=config.COOLIFY_ENVIRONMENT,
            destination_uuid=config.COOLIFY_DESTINATION_UUID,
            name=f"tenant-{slug}", image=name, tag=tag, port=port, domain=host)
        db.put_coolify_uuid(slug, uuid)
        return uuid

    def _app_fields(self, slug: str, image: str, tag: str, port: int,
                    host: str) -> dict:
        """The full desired app state the kiosk owns on every deploy: the image
        ref, FQDN, exposed port, per-app resource ceilings, and the auth-chain
        custom labels. Coolify enforces the limits and its Traefik honours the
        labels."""
        label_map = labels.tenant_label_map(
            slug, host, port, config.COOLIFY_TENANT_NETWORK)
        fields: dict = {
            "docker_registry_image_name": image,
            "docker_registry_image_tag": tag,
            "domains": f"https://{host}",
            "ports_exposes": str(port),
            "custom_labels": CoolifyClient.encode_custom_labels(label_map),
            # Ours are the only labels — don't let Coolify auto-generate a second
            # (unauthenticated) Traefik router alongside our chained one.
            "is_container_label_readonly_enabled": True,
        }
        if config.COOLIFY_CPU_LIMIT:
            fields["limits_cpus"] = config.COOLIFY_CPU_LIMIT
        if config.COOLIFY_MEMORY_LIMIT:
            fields["limits_memory"] = config.COOLIFY_MEMORY_LIMIT
        return fields

    def redeploy(self, slug: str) -> tuple[bool, str, str]:
        rec = db.get_app(slug)
        if not rec or not rec.get("image") or rec.get("status") != "running":
            return False, "", "app is not currently running; nothing to redeploy"
        env = tenant_env.build_env(slug)
        return self.deploy(slug, rec["image"], rec["port"], env=env)

    def rollback(self, slug: str) -> tuple[bool, str, str]:
        """Redeploy the previous retained build (the reason prune keeps
        IMAGE_RETAIN>1). Tags are unix timestamps; pick the newest that isn't the
        live one and deploy it through the normal path."""
        rec = db.get_app(slug)
        if not rec or not rec.get("image") or not rec.get("port"):
            return False, "", "no recorded build to roll back from"
        repo = f"{config.REGISTRY_HOST}/tenant-{slug}"
        res = dockercli.run(["images", repo, "--format", "{{.Tag}}"], timeout=30)
        tags = sorted((int(t) for t in res.out.split() if t.isdigit()), reverse=True)
        _, live = dockercli.split_image_ref(rec["image"])
        prev = next((t for t in tags if str(t) != live), None)
        if prev is None:
            return False, "", "no previous build to roll back to"
        image = f"{repo}:{prev}"
        ok, url, msg = self.deploy(slug, image, rec["port"], env=tenant_env.build_env(slug))
        if ok:
            db.set_app_status(slug, "deploying", image=image)
        return ok, url, (f"rolling back to build {prev} (async)" if ok else msg)

    def deploy_status(self, slug: str) -> str:
        """Coolify's real state for a deploying app, mapped to running/failed/
        deploying. Used by the monitor reconciler to correct the optimistic
        'deploying' the saga sets after an async trigger. Transient API errors
        keep it 'deploying' (retried next tick)."""
        uuid = db.get_coolify_uuid(slug)
        if not uuid:
            return "deploying"
        try:
            status = self._client.app_status(uuid).lower()
        except CoolifyError:
            return "deploying"
        if "running" in status or "healthy" in status:
            return "running"
        if any(marker in status for marker in _FAILED_MARKERS):
            return "failed"
        return "deploying"

    def app_logs(self, slug: str, tail: int = 200) -> str:
        uuid = db.get_coolify_uuid(slug)
        if not uuid:
            return "(no Coolify application yet for this app)"
        try:
            return self._client.logs(uuid, lines=tail)
        except CoolifyError as e:
            return f"(could not fetch logs from Coolify: {e})"

    def teardown(self, slug: str) -> None:
        uuid = db.get_coolify_uuid(slug)
        if not uuid:
            return
        try:
            self._client.delete_app(uuid)
        except CoolifyError as e:
            print(f"[coolify] teardown {slug}: {e}", flush=True)
        db.delete_coolify_uuid(slug)

    # ── cron → Coolify Scheduled Tasks ──────────────────────────────────────────
    def sync_cron(self, slug: str, uuid: str | None = None) -> None:
        """Reconcile Coolify Scheduled Tasks with the kiosk's cron rows in BOTH
        directions: create missing tasks, update ones whose schedule/command
        changed, and delete tasks whose kiosk row is gone. (A one-way create-only
        sync would leave edits and deletions silently diverging.) Schedules are
        the kiosk's declared UTC, so tasks are created with timezone=UTC. Called
        with the resolved `uuid` from `deploy`, or without it from the cron route.
        Best-effort — a Coolify without the scheduled-task API logs and skips."""
        uuid = uuid or db.get_coolify_uuid(slug)
        if not uuid:  # not deployed yet — deploy() re-syncs once the app exists
            return
        desired = {r["name"]: r for r in db.list_cron(slug)}
        try:
            existing = {t["name"]: t for t in self._client.list_scheduled_tasks(uuid)
                        if t.get("name")}
            for name, row in desired.items():
                task = existing.get(name)
                if task is None:
                    self._client.create_scheduled_task(
                        uuid, name=name, command=row["command"],
                        frequency=row["schedule"])
                elif (task.get("command") != row["command"]
                      or task.get("frequency") != row["schedule"]):
                    tid = task.get("uuid") or task.get("id")
                    if tid:
                        self._client.update_scheduled_task(
                            uuid, tid, name=name, command=row["command"],
                            frequency=row["schedule"])
            for name, task in existing.items():
                if name not in desired:
                    tid = task.get("uuid") or task.get("id")
                    if tid:
                        self._client.delete_scheduled_task(uuid, tid)
        except CoolifyError as e:
            print(f"[coolify] scheduled-task sync for {slug} skipped: {e}", flush=True)
