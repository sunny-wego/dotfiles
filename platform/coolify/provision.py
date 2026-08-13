#!/usr/bin/env python3
"""Auto-provision the Coolify project/environment/server UUIDs from just an API
token — so the local one-liner needs one browser step (create admin + token),
not a copy-the-UUIDs chore.

Given COOLIFY_BASE_URL + COOLIFY_API_TOKEN in the environment, this:
  * finds (or creates) a project named $COOLIFY_PROJECT_NAME (default internal-apps)
  * finds (or creates) its $COOLIFY_ENVIRONMENT (default production) environment
  * picks the first server (a single-node Colima/EC2 box)
  * writes COOLIFY_PROJECT_UUID / COOLIFY_ENVIRONMENT_UUID / COOLIFY_SERVER_UUID
    into local/.env.local (idempotent — existing values are replaced)

DESTINATION_UUID is left empty: a fresh single-node Coolify has one standalone
docker destination, and the client only sends destination_uuid when set.

Idempotent + safe to re-run. Exit 0 ok, 1 failed, 2 not configured (no token).
"""
from __future__ import annotations

import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "kiosk"))
from app.backends.coolify.client import CoolifyClient, CoolifyError  # noqa: E402

ENV_LOCAL = pathlib.Path(__file__).resolve().parents[1] / "local" / ".env.local"


def _env(k: str, d: str = "") -> str:
    return os.environ.get(k, d)


def _write_env_local(values: dict[str, str]) -> None:
    """Replace/append KEY=VALUE lines in local/.env.local without disturbing the
    rest of the file (comments, the token the user pasted, etc.)."""
    lines = ENV_LOCAL.read_text().splitlines() if ENV_LOCAL.exists() else []
    for key, val in values.items():
        line = f"{key}={val}"
        for i, existing in enumerate(lines):
            if existing.startswith(f"{key}="):
                lines[i] = line
                break
        else:
            lines.append(line)
    ENV_LOCAL.write_text("\n".join(lines) + "\n")


def _find_by_name(items: list[dict], name: str) -> dict | None:
    return next((it for it in items if it.get("name") == name), None)


def main() -> int:
    if not (_env("COOLIFY_BASE_URL") and _env("COOLIFY_API_TOKEN")):
        print("not configured — set COOLIFY_BASE_URL + COOLIFY_API_TOKEN in "
              "local/.env.local (create an API token in the Coolify dashboard first)",
              file=sys.stderr)
        return 2

    client = CoolifyClient(_env("COOLIFY_BASE_URL"), _env("COOLIFY_API_TOKEN"),
                           timeout=float(_env("COOLIFY_TIMEOUT_S", "30")))
    proj_name = _env("COOLIFY_PROJECT_NAME", "internal-apps")
    env_name = _env("COOLIFY_ENVIRONMENT", "production")

    try:
        servers = client.list_servers()
        if not servers:
            print("no servers in Coolify yet — add the localhost server in the "
                  "dashboard first", file=sys.stderr)
            return 1
        server_uuid = servers[0].get("uuid") or servers[0].get("id")

        project = _find_by_name(client.list_projects(), proj_name)
        if project:
            project_uuid = project.get("uuid") or project.get("id")
            print(f"reusing project {proj_name} ({project_uuid})")
        else:
            project_uuid = client.create_project(proj_name, "Internal App Platform")
            print(f"created project {proj_name} ({project_uuid})")

        environment = _find_by_name(client.list_environments(project_uuid), env_name)
        if environment:
            env_uuid = environment.get("uuid") or environment.get("id")
            print(f"reusing environment {env_name} ({env_uuid})")
        else:
            env_uuid = client.create_environment(project_uuid, env_name)
            print(f"created environment {env_name} ({env_uuid})")
    except CoolifyError as e:
        print(f"provision failed: {e}", file=sys.stderr)
        return 1

    _write_env_local({
        "COOLIFY_SERVER_UUID": server_uuid,
        "COOLIFY_PROJECT_UUID": project_uuid,
        "COOLIFY_ENVIRONMENT": env_name,
        "COOLIFY_ENVIRONMENT_UUID": env_uuid,
    })
    print(f"wrote server/project/environment UUIDs to {ENV_LOCAL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
