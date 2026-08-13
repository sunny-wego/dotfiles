"""Per-tenant LiteLLM virtual key.

Mints a budgeted virtual key via LiteLLM's admin API and returns env for the
tenant (OpenAI-compatible: base URL + key). Best-effort: if LiteLLM has no key
management configured (no DB), we skip and log rather than fail a provision —
the app just doesn't get an LLM key. Idempotent-ish: we mint once and store the
key as an app secret so re-deploys reuse it.
"""

from __future__ import annotations

import httpx

from . import db, crypto
from .config import config

_SECRET_KEY_NAME = "LITELLM_VIRTUAL_KEY"


def ensure_key(slug: str, log) -> dict[str, str]:
    # Reuse a previously-minted key if present.
    for row in db.get_secrets(slug):
        if row["key"] == _SECRET_KEY_NAME:
            key = crypto.decrypt(row["value_enc"])
            return _env(key)

    url = f"{config.LITELLM_BASE_URL}/key/generate"
    headers = {"Authorization": f"Bearer {config.LITELLM_MASTER_KEY}"}
    payload = {"key_alias": f"tenant-{slug}", "max_budget": config.LITELLM_MAX_BUDGET,
               "metadata": {"tenant": slug}}
    try:
        resp = httpx.post(url, json=payload, headers=headers, timeout=20)
        resp.raise_for_status()
        key = resp.json()["key"]
    except (httpx.HTTPError, KeyError, ValueError) as e:  # noqa: BLE001
        # ValueError covers json.JSONDecodeError — a 200 with a non-JSON body
        # (proxy/gateway error page) must skip, not fail the whole provision.
        log(f"[llm] virtual-key mint skipped ({e}); app gets no LLM key")
        return {}

    db.set_secret(slug, _SECRET_KEY_NAME, crypto.encrypt(key))
    log(f"[llm] minted per-tenant virtual key (budget ${config.LITELLM_MAX_BUDGET})")
    return _env(key)


def _env(key: str) -> dict[str, str]:
    # OpenAI-compatible env most SDKs honor; base URL points at the gateway.
    return {
        "OPENAI_API_KEY": key,
        "OPENAI_BASE_URL": f"{config.LITELLM_BASE_URL}/v1",
        "LLM_API_KEY": key,
        "LLM_BASE_URL": f"{config.LITELLM_BASE_URL}/v1",
    }
