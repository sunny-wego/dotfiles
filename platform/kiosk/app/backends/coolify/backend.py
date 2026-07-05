"""Coolify deploy backend — drives Coolify's REST API on the creator's behalf.

Maps the platform's deploy contract onto Coolify resources:

  * deploy-from-image  → create/update a Docker-image application, push the env
                         bundle into Coolify's encrypted env store, set the FQDN
                         (Coolify-managed Traefik does TLS), set CPU/mem limits,
                         attach the auth-chain via custom Traefik labels, trigger
                         an (async) deploy.
  * cron               → Coolify Scheduled Tasks (the kiosk has no in-process
                         scheduler; it only syncs each app's schedule to Coolify).
  * admin plane        → the Coolify dashboard (operators), surfaced to the kiosk
                         via `admin_dashboard_url`.

The auth chain (strip-auth-in → slug → forwardauth → appauthz) is applied via the
`labels` builder as Coolify application custom labels. The `@file` middlewares it
references must exist in Coolify's proxy — see `platform/coolify/traefik-dynamic.yml`
and the runbook.

Deploys on Coolify are asynchronous: we return success once the deploy is
*accepted*, not once the container is live (unlike the Docker backend, which
blocks). The app page + Coolify dashboard show progress; this difference is
called out in the runbook.
"""

from __future__ import annotations

from ... import db, tenant_env
from ...config import config
from .. import labels
from .client import CoolifyClient, CoolifyError


def _split_image(image: str) -> tuple[str, str]:
    """'registry:5000/tenant-foo:1700000000' → ('registry:5000/tenant-foo',
    '1700000000'). Splits on the LAST colon, so the registry host's own port is
    preserved in the name."""
    name, _, tag = image.rpartition(":")
    if not name:  # no tag present
        return image, "latest"
    return name, tag


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
        name, tag = _split_image(image)
        full_env = {"PORT": str(port), **(env or {})}
        try:
            uuid = self._ensure_app(slug, name, tag, port, host)
            self._client.set_envs(uuid, full_env)
            self._client.update_app(uuid, self._app_fields(slug, port, host))
            self._client.deploy(uuid, force=True)
        except CoolifyError as e:
            return False, "", f"Coolify deploy failed: {e}"
        # Best-effort: sync scheduled tasks now that the app exists.
        self.sync_cron(slug)
        return (True, f"https://{host}",
                "deploy triggered on Coolify (async) behind Google login + allow-list")

    def _ensure_app(self, slug: str, name: str, tag: str, port: int,
                    host: str) -> str:
        """Return the Coolify app UUID for this slug, creating it on first deploy
        and reusing it (updating the image tag) thereafter. Idempotent."""
        uuid = db.get_coolify_uuid(slug)
        if uuid:
            self._client.set_image(uuid, name, tag)
            return uuid
        uuid = self._client.create_image_app(
            project_uuid=config.COOLIFY_PROJECT_UUID,
            server_uuid=config.COOLIFY_SERVER_UUID,
            environment_name=config.COOLIFY_ENVIRONMENT,
            destination_uuid=config.COOLIFY_DESTINATION_UUID,
            name=f"tenant-{slug}", image=name, tag=tag, port=port, domain=host)
        db.put_coolify_uuid(slug, uuid)
        return uuid

    def _app_fields(self, slug: str, port: int, host: str) -> dict:
        """The application settings the kiosk owns on every deploy: the FQDN,
        exposed port, per-app resource ceilings, and the auth-chain custom
        labels. Coolify enforces the limits and its Traefik honours the labels."""
        label_map = labels.tenant_label_map(
            slug, host, port, config.COOLIFY_TENANT_NETWORK)
        fields: dict = {
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
        # Coolify retains deployment history; rolling back is a first-class
        # dashboard action (the README's "rollback" under Coolify-provided).
        url = self.admin_dashboard_url() or config.COOLIFY_BASE_URL
        return (False, url,
                f"roll back from the Coolify deployment history for '{slug}' at {url}")

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
    def sync_cron(self, slug: str) -> None:
        """Reconcile Coolify Scheduled Tasks with the kiosk's cron rows: create
        any missing, leave the rest. Best-effort — a Coolify version without the
        scheduled-task API logs and skips rather than failing a deploy."""
        uuid = db.get_coolify_uuid(slug)
        if not uuid:
            return
        try:
            existing = {t.get("name") for t in self._client.list_scheduled_tasks(uuid)}
            for row in db.list_cron(slug):
                if row["name"] in existing:
                    continue
                self._client.create_scheduled_task(
                    uuid, name=row["name"], command=row["command"],
                    frequency=row["schedule"])
        except CoolifyError as e:
            print(f"[coolify] scheduled-task sync for {slug} skipped: {e}", flush=True)

    def admin_dashboard_url(self) -> str | None:
        return config.COOLIFY_BASE_URL or None
