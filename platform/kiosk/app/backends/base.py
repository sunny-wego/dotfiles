"""The deploy-backend interface.

A backend hosts a *verified, pushed image* behind the platform's two invariant
seams — **everything routes through Traefik + the auth chain**, and **every app
is an image from a Dockerfile** — and nothing above those seams (the build /
heal / detect / redact pipeline, the catalog, audit, RBAC) knows which engine is
underneath. Adding an engine means implementing this interface; it never means
touching the pipeline. That is the README's "additive, not a migration".

Capability flags let the kiosk delegate *more* than deploy to an engine that
owns it. `manages_cron=True` means the engine runs scheduled tasks itself (the
kiosk's in-process cron loop stays off and the kiosk only *syncs* the schedule
to the engine). Keeping these as flags rather than two code paths in the caller
means the orchestrator/startup logic reads the same regardless of engine.
"""

from __future__ import annotations

import abc


class DeployBackend(abc.ABC):
    #: Short identifier, used in logs and audit detail.
    name: str = "base"

    #: True if the engine runs scheduled tasks itself (kiosk cron loop stays
    #: off; the kiosk syncs schedules via `sync_cron`). False = the kiosk's
    #: in-process cron scheduler runs the jobs.
    manages_cron: bool = False

    #: True if the engine takes per-tenant DB backups itself. The kiosk's
    #: nightly pg_dump is an *extension* the README keeps in both variants
    #: (§3), so this is False today for both engines; the flag exists so a
    #: future engine that owns tenant-DB backups can turn the kiosk loop off.
    manages_backups: bool = False

    @abc.abstractmethod
    def deploy(self, slug: str, image: str, port: int,
               env: dict[str, str] | None = None) -> tuple[bool, str, str]:
        """Make `image` live at the app's hostname, behind the auth chain and on
        the tenant network (no direct egress). Idempotent per slug. Returns
        (ok, url, message)."""

    @abc.abstractmethod
    def redeploy(self, slug: str) -> tuple[bool, str, str]:
        """Re-apply an already-built app with a freshly-assembled env bundle so a
        secret / egress change takes effect on the live app. No rebuild."""

    @abc.abstractmethod
    def app_logs(self, slug: str, tail: int = 200) -> str:
        """Creator-facing logs — surfaced in the Kiosk (creators never open the
        engine)."""

    @abc.abstractmethod
    def teardown(self, slug: str) -> None:
        """Remove the app from the engine. Best-effort, idempotent."""

    def prune_old_images(self, slug: str, keep: str) -> None:
        """Reclaim disk from superseded builds. Engine-specific; default no-op
        for engines that manage image retention themselves."""

    def rollback(self, slug: str) -> tuple[bool, str, str]:
        """Re-point the app at its previous good build. Default: unsupported."""
        return False, "", "rollback is not supported by this backend"

    def sync_cron(self, slug: str) -> None:
        """Reconcile the engine's scheduled tasks for this app with the kiosk's
        cron rows. No-op for engines whose kiosk-side loop runs the jobs."""

    def admin_dashboard_url(self) -> str | None:
        """Operator admin plane URL, if the engine provides one (Coolify)."""
        return None
