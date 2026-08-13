"""Assemble the runtime environment injected into a tenant container.

One place, used by both the deployer (long-lived app) and the cron runner
(one-shot jobs), so an app's scheduled task sees exactly the same DB, secrets,
egress and LLM wiring as the app itself.
"""

from __future__ import annotations

from . import egress, llmkey, provision_db, secrets_store


def build_env(slug: str, log=lambda *_: None) -> dict[str, str]:
    env: dict[str, str] = {}

    url = provision_db.database_url(slug)
    if url:
        env["DATABASE_URL"] = url

    env.update(secrets_store.env_for(slug))     # encrypted-at-rest app secrets
    env.update(egress.proxy_env_for(slug))      # HTTPS_PROXY iff allowlisted
    env.update(llmkey.ensure_key(slug, log))    # per-tenant LLM key (best-effort)
    return env
