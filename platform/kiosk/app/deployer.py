"""Deploy facade — dispatches to the active deploy backend.

The deploy engine is swappable behind a small interface (README: "additive, not
a migration"). That interface + its implementations now live in `backends/`
(plain-Docker default, Coolify optional); this module keeps the original
function-level API (`deploy`, `redeploy`, `app_logs`, `teardown`,
`prune_old_images`) so the orchestrator and web layer don't care which engine is
underneath. The backend is chosen once from `KIOSK_DEPLOY_BACKEND`.
"""

from __future__ import annotations

import threading

from .backends import get_backend


def deploy(slug: str, image: str, port: int,
           env: dict[str, str] | None = None) -> tuple[bool, str, str]:
    return get_backend().deploy(slug, image, port, env=env)


def redeploy(slug: str) -> tuple[bool, str, str]:
    """Re-run an already-built app with a freshly-built env bundle, so changes to
    secrets / egress allowlist take effect on the live app. No rebuild."""
    return get_backend().redeploy(slug)


def redeploy_async(slug: str) -> None:
    """Redeploy off the request path. A secret/egress change shouldn't block the
    HTTP response on a full recreate; the UI redirects immediately and the app
    refreshes a moment later."""
    threading.Thread(target=redeploy, args=(slug,), daemon=True).start()


def rollback(slug: str) -> tuple[bool, str, str]:
    return get_backend().rollback(slug)


def app_logs(slug: str, tail: int = 200) -> str:
    return get_backend().app_logs(slug, tail=tail)


def teardown(slug: str) -> None:
    get_backend().teardown(slug)


def prune_old_images(slug: str, keep: str) -> None:
    get_backend().prune_old_images(slug, keep)


def sync_cron(slug: str) -> None:
    get_backend().sync_cron(slug)
