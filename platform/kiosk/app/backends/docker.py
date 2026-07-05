"""Plain-Docker deploy backend — the README's sanctioned variant (default).

Runs the verified, pushed image as a long-lived container on the tenant network
with Traefik labels, so it gets a hostname + TLS and sits BEHIND the auth chain
(private by default — the README's non-negotiable). Idempotent: re-deploying a
slug replaces the previous container.

Cron and backups are run by the kiosk in-process here (this engine has no
scheduler of its own), so `manages_cron`/`manages_backups` stay False and the
kiosk's cron loop + nightly backup thread do the work.
"""

from __future__ import annotations

from .. import db, dockercli, tenant_env
from ..config import config
from . import labels
from .base import DeployBackend

# How many recent builds of each app to keep locally. The live one plus one
# previous, so a redeploy can be rolled back to the prior image; older builds
# are pruned so /var/lib/docker doesn't fill up.
IMAGE_RETAIN = 2


class DockerBackend(DeployBackend):
    name = "docker"
    manages_cron = False
    manages_backups = False

    def deploy(self, slug: str, image: str, port: int,
               env: dict[str, str] | None = None) -> tuple[bool, str, str]:
        name = f"app-{slug}"
        host = config.app_host(slug)
        dockercli.rm_force(name)

        label_args = labels.docker_label_args(slug, host, port, config.TENANT_NETWORK)
        envargs: list[str] = ["-e", f"PORT={port}"]
        for k, v in (env or {}).items():
            envargs += ["-e", f"{k}={v}"]

        res = dockercli.run([
            "run", "-d", "--name", name, "--restart", "unless-stopped",
            "--network", config.TENANT_NETWORK,
            *envargs,
            *label_args,
            image,
        ], timeout=120)

        if not res.ok:
            return False, "", f"deploy failed:\n{res.out[-500:]}"
        return True, f"https://{host}", "deployed behind Google login + allow-list"

    def redeploy(self, slug: str) -> tuple[bool, str, str]:
        rec = db.get_app(slug)
        if not rec or not rec.get("image") or rec.get("status") != "running":
            return False, "", "app is not currently running; nothing to redeploy"
        env = tenant_env.build_env(slug)
        return self.deploy(slug, rec["image"], rec["port"], env=env)

    def rollback(self, slug: str) -> tuple[bool, str, str]:
        """Re-point the app at the newest *previous* local build (tags are unix
        timestamps). Relies on IMAGE_RETAIN keeping ≥1 prior image."""
        rec = db.get_app(slug)
        if not rec or not rec.get("image") or not rec.get("port"):
            return False, "", "app has no recorded build to roll back from"
        repo = f"{config.REGISTRY_HOST}/tenant-{slug}"
        res = dockercli.run(["images", repo, "--format", "{{.Tag}}"], timeout=30)
        tags = sorted((int(t) for t in res.out.split()
                       if t and t != "<none>" and t.isdigit()), reverse=True)
        live = rec["image"].rsplit(":", 1)[-1]
        prev = next((t for t in tags if str(t) != live), None)
        if prev is None:
            return False, "", "no previous build to roll back to"
        image = f"{repo}:{prev}"
        env = tenant_env.build_env(slug)
        ok, url, msg = self.deploy(slug, image, rec["port"], env=env)
        if ok:
            db.set_app_status(slug, "running", url=url, image=image)
        return ok, url, (f"rolled back to build {prev}" if ok else msg)

    def app_logs(self, slug: str, tail: int = 200) -> str:
        return dockercli.logs(f"app-{slug}", tail=tail)

    def teardown(self, slug: str) -> None:
        dockercli.rm_force(f"app-{slug}")

    def prune_old_images(self, slug: str, keep: str) -> None:
        """Keep the newest IMAGE_RETAIN builds of this slug (always including
        `keep`, the just-deployed live image); remove older ones. Tags are unix
        timestamps, so newest = numerically largest. Best-effort — missing /
        in-use tags skipped."""
        repo = f"{config.REGISTRY_HOST}/tenant-{slug}"
        res = dockercli.run(["images", repo, "--format", "{{.Tag}}"], timeout=30)
        if not res.ok:
            return
        tags = [t for t in res.out.split() if t and t != "<none>"]

        def ts(t: str) -> int:
            try:
                return int(t)
            except ValueError:
                return -1

        live = keep.rsplit(":", 1)[-1]
        retain = set(sorted(tags, key=ts, reverse=True)[:IMAGE_RETAIN]) | {live}
        for t in tags:
            if t not in retain:
                dockercli.run(["rmi", "-f", f"{repo}:{t}"], timeout=30)
