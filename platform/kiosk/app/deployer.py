"""Deploy facade — delegates to Coolify.

The kiosk builds + pushes an image, then hands off hosting to Coolify (deploy,
env, cron, TLS, rollback, logs). This module keeps the function-level API the
orchestrator and web layer call, so they don't reach into the backend directly.

`prune_old_images` is the exception: it reclaims disk from *locally built* images
(the kiosk builds every app here before Coolify deploys from the registry), so it
runs against the local Docker daemon regardless of the hosting engine.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from . import dockercli
from .config import config

# Keep the newest N local builds per app (the live one + one previous for a quick
# local rebuild); older tags are pruned so the build box's disk doesn't fill up.
IMAGE_RETAIN = 2

# Bounded pool for off-request-path Coolify work (redeploys, cron sync) and for
# offloading blocking Coolify reads (logs) out of FastAPI's shared worker pool —
# so a burst of edits or a slow/hung Coolify can't spawn unbounded threads or
# starve other routes.
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="coolify")

_backend = None


def _b():
    """The process-wide Coolify backend, built lazily so importing this module
    (or `backends.labels`) doesn't construct the Coolify client — which requires
    credentials — until a deploy actually needs it."""
    global _backend
    if _backend is None:
        from .backends.coolify.backend import CoolifyBackend
        _backend = CoolifyBackend()
    return _backend


def pool() -> ThreadPoolExecutor:
    """The shared off-path executor (used by async routes to offload blocking
    Coolify calls)."""
    return _pool


def deploy(slug: str, image: str, port: int,
           env: dict[str, str] | None = None) -> tuple[bool, str, str]:
    return _b().deploy(slug, image, port, env=env)


def redeploy(slug: str) -> tuple[bool, str, str]:
    """Re-apply an already-built app with a freshly-built env bundle, so changes
    to secrets / egress allowlist take effect on the live app. No rebuild."""
    return _b().redeploy(slug)


def redeploy_async(slug: str) -> None:
    """Redeploy off the request path so a secret/egress change doesn't block the
    HTTP response; the UI redirects immediately and the app refreshes shortly."""
    _pool.submit(redeploy, slug)


def rollback(slug: str) -> tuple[bool, str, str]:
    return _b().rollback(slug)


def deploy_status(slug: str) -> str:
    return _b().deploy_status(slug)


def app_logs(slug: str, tail: int = 200) -> str:
    return _b().app_logs(slug, tail=tail)


def sync_cron(slug: str) -> None:
    _b().sync_cron(slug)


def sync_cron_async(slug: str) -> None:
    """Register/reconcile Coolify Scheduled Tasks off the request path."""
    _pool.submit(sync_cron, slug)


def prune_old_images(slug: str, keep: str) -> None:
    """Keep the newest IMAGE_RETAIN local builds of this slug (always including
    `keep`, the just-deployed image); remove older ones. Tags are unix
    timestamps, so newest = numerically largest. Best-effort — missing / in-use
    tags skipped."""
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
