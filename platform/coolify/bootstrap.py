#!/usr/bin/env python3
"""Self-host the control plane on Coolify (Option B) — the platform hosting
itself.

Drives the SHIPPED CoolifyClient to create `coolify/platform-stack.yml` as a
Coolify SERVICE: the kiosk + oauth2-proxy + litellm + registry + egress-proxy +
metadata Postgres, run by Coolify on the tenant network, with Coolify owning the
kiosk's domain + TLS + auth chain. This is the bootstrap answer to "who deploys
the kiosk?" — the same REST client that deploys tenant apps deploys the platform.

Idempotent: re-running reuses the existing service (matched by name), refreshes
its env store, and redeploys. `--delete` tears it down.

Run via coolify/bootstrap.sh (sources .env). Exit 0 ok, 1 failed, 2 not configured.
"""
from __future__ import annotations

import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "kiosk"))
from app.backends.coolify.client import CoolifyClient, CoolifyError  # noqa: E402

SERVICE_NAME = "platform-control-plane"
REQUIRED = ["COOLIFY_BASE_URL", "COOLIFY_API_TOKEN", "COOLIFY_PROJECT_UUID",
            "COOLIFY_SERVER_UUID", "COOLIFY_ENVIRONMENT_UUID"]

# Keys platform-stack.yml references; pushed into the service env store so
# Coolify resolves the compose's ${VAR} placeholders. (Only those present are
# sent; secrets live in the env store, never in the committed compose.)
STACK_ENV_KEYS = [
    "PLATFORM_DOMAIN", "AUTH_MODE", "COMPANY_EMAIL_DOMAIN",
    "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB",
    "LITELLM_MASTER_KEY", "KIOSK_LLM_MODE", "KIOSK_SECRET_KEY",
    "SLACK_WEBHOOK_URL", "OPENROUTER_API_KEY", "KIOSK_IMAGE",
    "OIDC_ISSUER_URL", "OAUTH2_PROXY_CLIENT_ID", "OAUTH2_PROXY_CLIENT_SECRET",
    "OAUTH2_PROXY_COOKIE_SECRET",
    "COOLIFY_BASE_URL", "COOLIFY_API_TOKEN", "COOLIFY_PROJECT_UUID",
    "COOLIFY_ENVIRONMENT", "COOLIFY_ENVIRONMENT_UUID", "COOLIFY_SERVER_UUID",
    "COOLIFY_DESTINATION_UUID", "COOLIFY_TENANT_NETWORK",
    "COOLIFY_BACKUP_FREQUENCY",
]


def _env(k: str, d: str = "") -> str:
    return os.environ.get(k, d)


def _client() -> CoolifyClient:
    return CoolifyClient(_env("COOLIFY_BASE_URL"), _env("COOLIFY_API_TOKEN"),
                         timeout=float(_env("COOLIFY_TIMEOUT_S", "30")))


def _find(client: CoolifyClient) -> str | None:
    for s in client.list_services():
        if s.get("name") == SERVICE_NAME:
            return s.get("uuid") or s.get("id")
    return None


def main() -> int:
    missing = [k for k in REQUIRED if not _env(k)]
    if missing:
        print(f"not configured — set: {', '.join(missing)}", file=sys.stderr)
        return 2

    client = _client()
    delete = "--delete" in sys.argv[1:]

    try:
        existing = _find(client)
        if delete:
            if existing:
                client.delete_service(existing)
                print(f"deleted service {SERVICE_NAME} ({existing})")
            else:
                print(f"no service {SERVICE_NAME} to delete")
            return 0

        env = {k: _env(k) for k in STACK_ENV_KEYS if _env(k) != ""}

        if existing:
            uuid = existing
            print(f"reusing service {SERVICE_NAME} ({uuid})")
            client.set_service_envs(uuid, env)
            client.start_service(uuid)      # redeploy with refreshed env
            print("env refreshed + redeploy triggered")
        else:
            compose = (pathlib.Path(__file__).resolve().parent
                       / "platform-stack.yml").read_text()
            uuid = client.create_service(
                project_uuid=_env("COOLIFY_PROJECT_UUID"),
                server_uuid=_env("COOLIFY_SERVER_UUID"),
                environment_name=_env("COOLIFY_ENVIRONMENT", "production"),
                environment_uuid=_env("COOLIFY_ENVIRONMENT_UUID"),
                destination_uuid=_env("COOLIFY_DESTINATION_UUID"),
                name=SERVICE_NAME, compose=compose, instant_deploy=False)
            print(f"created service {SERVICE_NAME} ({uuid})")
            client.set_service_envs(uuid, env)   # set env BEFORE first deploy
            client.start_service(uuid)
            print("env set + deploy triggered")
    except CoolifyError as e:
        print(f"bootstrap failed: {e}", file=sys.stderr)
        return 1

    domain = _env("PLATFORM_DOMAIN", "apps.internal")
    print(f"\ncontrol plane deploying on Coolify. Kiosk will come up at:")
    print(f"  https://kiosk.{domain}")
    print("Reminders (see coolify/platform-stack.yml PARITY-GATE CHECKS):")
    print(f"  • connect the service to the '{_env('COOLIFY_TENANT_NETWORK', 'platform_tenant')}' network")
    print("  • ensure Coolify doesn't ALSO publish an auto-domain for the kiosk")
    print("  • install coolify/traefik-dynamic.yml in Coolify's proxy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
