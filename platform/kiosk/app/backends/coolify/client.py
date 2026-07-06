"""Thin wrapper over the Coolify v4 REST API.

Every Coolify HTTP call the kiosk makes lives here — one place to see the API
surface, one place to adjust if the endpoint shape differs on the target Coolify
version. Methods return parsed JSON (dict/list) on success and raise
`CoolifyError` on any transport/HTTP/JSON failure (including a not-configured
client), so the backend can translate one failure type into a creator-facing
message + Slack escalation instead of a 500.

Endpoint paths follow Coolify v4's documented API. They are all funnelled
through `_request`, so pinning them to a specific Coolify release (the runbook's
EC2 parity gate) is a single-file change.
"""

from __future__ import annotations

import base64
import json

import httpx


class CoolifyError(RuntimeError):
    """Any Coolify API failure — transport, non-2xx, unparseable body, or a
    client built without credentials."""


def _dig(data, key: str):
    """Best-effort read of `key` from a Coolify response that may be the object
    itself or wrapped in `{"data": {...}}`. Returns None for any other shape
    (list, null, scalar) rather than raising."""
    if isinstance(data, dict):
        if data.get(key) is not None:
            return data[key]
        inner = data.get("data")
        if isinstance(inner, dict):
            return inner.get(key)
    return None


class CoolifyClient:
    def __init__(self, base_url: str, token: str, timeout: float = 30.0,
                 transport: httpx.BaseTransport | None = None) -> None:
        # Missing creds don't raise here — they raise from `_request` when a call
        # is actually made, so an unconfigured box degrades to clean per-request
        # CoolifyErrors (caught by the backend) instead of 500-ing web routes
        # that merely construct the client.
        self._configured = bool(base_url and token)
        self._http = httpx.Client(
            base_url=(base_url.rstrip("/") + "/api/v1") if self._configured
            else "http://coolify.unconfigured/api/v1",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            timeout=timeout,
            transport=transport,
        )

    # ── transport ────────────────────────────────────────────────────────────
    def _request(self, method: str, path: str, *,
                 params: dict | None = None, json_body: dict | None = None):
        if not self._configured:
            raise CoolifyError(
                "Coolify is not configured (set COOLIFY_BASE_URL / "
                "COOLIFY_API_TOKEN)")
        try:
            resp = self._http.request(method, path, params=params, json=json_body)
        except httpx.HTTPError as e:
            raise CoolifyError(f"{method} {path}: transport error: {e}") from e
        if resp.status_code >= 400:
            raise CoolifyError(
                f"{method} {path}: HTTP {resp.status_code}: {resp.text[:400]}")
        if not resp.content:
            return {}
        try:
            return resp.json()
        except json.JSONDecodeError as e:
            raise CoolifyError(f"{method} {path}: bad JSON: {resp.text[:200]}") from e

    # ── applications ───────────────────────────────────────────────────────────
    def create_image_app(self, *, project_uuid: str, server_uuid: str,
                          environment_name: str, environment_uuid: str,
                          destination_uuid: str, name: str, image: str, tag: str,
                          port: int, domain: str) -> str:
        """Create a deploy-from-image application. Returns the new app UUID.
        Coolify requires project_uuid + server_uuid + environment_name +
        environment_uuid + docker_registry_image_name."""
        body = {
            "project_uuid": project_uuid,
            "server_uuid": server_uuid,
            "environment_name": environment_name,
            "name": name,
            "docker_registry_image_name": image,
            "docker_registry_image_tag": tag,
            "ports_exposes": str(port),
            "domains": f"https://{domain}",
            "instant_deploy": False,
        }
        if environment_uuid:
            body["environment_uuid"] = environment_uuid
        # Only send destination_uuid when set — an empty string is rejected by a
        # single-destination server (matching create_postgres/create_service).
        if destination_uuid:
            body["destination_uuid"] = destination_uuid
        data = self._request("POST", "/applications/dockerimage", json_body=body)
        uuid = _dig(data, "uuid")
        if not uuid:
            raise CoolifyError(f"create app: no uuid in response: {data}")
        return uuid

    def update_app(self, uuid: str, fields: dict) -> dict:
        return self._request("PATCH", f"/applications/{uuid}", json_body=fields)

    def delete_app(self, uuid: str) -> None:
        self._request("DELETE", f"/applications/{uuid}")

    def app_status(self, uuid: str) -> str:
        """The app's current status string (e.g. 'running:healthy', 'exited',
        'degraded'). Empty string if Coolify doesn't report one."""
        return str(_dig(self._request("GET", f"/applications/{uuid}"), "status") or "")

    def deploy(self, uuid: str, force: bool) -> dict:
        """Trigger a (re)deploy. Coolify runs it asynchronously; we only kick it."""
        return self._request("GET", "/deploy",
                             params={"uuid": uuid, "force": str(force).lower()})

    def logs(self, uuid: str, lines: int = 200) -> str:
        data = self._request("GET", f"/applications/{uuid}/logs",
                             params={"lines": lines})
        if isinstance(data, dict):
            # Empty logs come back as "" — return that, don't fall through to a
            # raw JSON dump of the envelope.
            for key in ("logs", "data"):
                if key in data:
                    return data[key] or ""
            return json.dumps(data)
        return str(data)

    # ── environment variables (Coolify's encrypted env store) ──────────────────
    def list_envs(self, uuid: str) -> list[dict]:
        data = self._request("GET", f"/applications/{uuid}/envs")
        return data if isinstance(data, list) else data.get("data", [])

    def delete_env(self, uuid: str, env_uuid: str) -> None:
        self._request("DELETE", f"/applications/{uuid}/envs/{env_uuid}")

    # Coolify-injected env we must never prune. COOLIFY_* is the documented
    # prefix; SERVICE_* is Coolify's compose-service magic (SERVICE_FQDN_*,
    # SERVICE_URL_*, generated SERVICE_PASSWORD_*, …); SOURCE_COMMIT is a common
    # non-prefixed one. Verify against the target Coolify version on the parity gate.
    _RESERVED_ENV = ("SOURCE_COMMIT",)
    _RESERVED_PREFIXES = ("COOLIFY_", "SERVICE_")

    def _replace_envs(self, kind: str, uuid: str, env: dict[str, str]) -> None:
        """Make a resource's env EXACTLY `env` for kiosk-managed keys: bulk-upsert
        the desired keys, then delete any non-reserved key we previously set that
        is no longer present — so a removed/rotated secret actually stops being
        injected. `kind` is 'applications' or 'services'."""
        payload = {"data": [{"key": k, "value": v, "is_preview": False}
                            for k, v in env.items()]}
        self._request("PATCH", f"/{kind}/{uuid}/envs/bulk", json_body=payload)
        desired = set(env)
        listed = self._request("GET", f"/{kind}/{uuid}/envs")
        rows = listed if isinstance(listed, list) else listed.get("data", [])
        for row in rows:
            key = row.get("key")
            if (not key or key in desired or key in self._RESERVED_ENV
                    or key.startswith(self._RESERVED_PREFIXES)):
                continue
            env_uuid = row.get("uuid") or row.get("id")
            if env_uuid:
                self._request("DELETE", f"/{kind}/{uuid}/envs/{env_uuid}")

    def replace_envs(self, uuid: str, env: dict[str, str]) -> None:
        self._replace_envs("applications", uuid, env)

    # ── databases (Coolify-managed Postgres == the README's per-tenant DB) ─────
    def create_postgres(self, *, project_uuid: str, server_uuid: str,
                        environment_name: str, environment_uuid: str,
                        destination_uuid: str, name: str, db_name: str,
                        db_user: str, db_password: str,
                        limits_cpus: str = "", limits_memory: str = "") -> str:
        """Create a Coolify-managed PostgreSQL database resource and start it.
        Returns the new database UUID. Coolify assigns the container host, so the
        connection URL is read back via `database_url` — not reconstructed here."""
        body: dict = {
            "project_uuid": project_uuid,
            "server_uuid": server_uuid,
            "environment_name": environment_name,
            "name": name,
            "postgres_user": db_user,
            "postgres_password": db_password,
            "postgres_db": db_name,
            "instant_deploy": True,
        }
        if environment_uuid:
            body["environment_uuid"] = environment_uuid
        if destination_uuid:
            body["destination_uuid"] = destination_uuid
        if limits_cpus:
            body["limits_cpus"] = limits_cpus
        if limits_memory:
            body["limits_memory"] = limits_memory
        data = self._request("POST", "/databases/postgresql", json_body=body)
        uuid = _dig(data, "uuid")
        if not uuid:
            raise CoolifyError(f"create database: no uuid in response: {data}")
        return uuid

    def list_databases(self) -> list[dict]:
        data = self._request("GET", "/databases")
        return data if isinstance(data, list) else data.get("data", [])

    def get_database(self, uuid: str) -> dict:
        data = self._request("GET", f"/databases/{uuid}")
        if isinstance(data, dict):
            return data.get("data") if isinstance(data.get("data"), dict) else data
        return {}

    def database_url(self, uuid: str) -> str:
        """The connection URL a container on the tenant network uses to reach this
        database. Coolify exposes it as `internal_db_url`. Normalised to the
        `postgresql://` scheme mainstream ORMs expect."""
        data = self.get_database(uuid)
        url = _dig(data, "internal_db_url") or _dig(data, "internal_url")
        if not url:
            raise CoolifyError(
                f"database {uuid}: no internal_db_url in response: {data}")
        if url.startswith("postgres://"):
            url = "postgresql://" + url[len("postgres://"):]
        return url

    def database_status(self, uuid: str) -> str:
        return str(_dig(self.get_database(uuid), "status") or "")

    def delete_database(self, uuid: str) -> None:
        # Removes the container, its volume and any scheduled backups.
        self._request("DELETE", f"/databases/{uuid}")

    def list_backups(self, uuid: str) -> list[dict]:
        data = self._request("GET", f"/databases/{uuid}/backups")
        return data if isinstance(data, list) else data.get("data", [])

    def create_backup(self, uuid: str, *, frequency: str, enabled: bool = True,
                      save_s3: bool = False, s3_storage_uuid: str = "",
                      retention_days_locally: int = 7) -> str:
        """Configure a native scheduled backup on a Coolify database resource.
        Returns the scheduled-backup UUID."""
        body: dict = {
            "frequency": frequency,
            "enabled": enabled,
            "save_s3": save_s3,
            "dump_all": False,
            "database_backup_retention_days_locally": retention_days_locally,
        }
        if save_s3 and s3_storage_uuid:
            body["s3_storage_uuid"] = s3_storage_uuid
        data = self._request("POST", f"/databases/{uuid}/backups", json_body=body)
        return _dig(data, "uuid") or ""

    # ── services (a Coolify-managed docker-compose stack) ──────────────────────
    # Used to SELF-HOST the platform's own control plane (kiosk + oauth2-proxy +
    # litellm + registry + egress-proxy + metadata Postgres) as one Coolify
    # resource on the tenant network — so Coolify owns the kiosk's domain/TLS/auth
    # chain exactly like a tenant app. See coolify/bootstrap.py.
    def create_service(self, *, project_uuid: str, server_uuid: str,
                       environment_name: str, environment_uuid: str,
                       destination_uuid: str, name: str, compose: str,
                       instant_deploy: bool = True) -> str:
        """Create a Coolify service from a raw docker-compose (sent base64 as
        `docker_compose_raw`). Returns the new service UUID."""
        body: dict = {
            "project_uuid": project_uuid,
            "server_uuid": server_uuid,
            "environment_name": environment_name,
            "name": name,
            "docker_compose_raw": self._b64(compose),
            "instant_deploy": instant_deploy,
        }
        if environment_uuid:
            body["environment_uuid"] = environment_uuid
        if destination_uuid:
            body["destination_uuid"] = destination_uuid
        data = self._request("POST", "/services", json_body=body)
        uuid = _dig(data, "uuid")
        if not uuid:
            raise CoolifyError(f"create service: no uuid in response: {data}")
        return uuid

    def list_services(self) -> list[dict]:
        data = self._request("GET", "/services")
        return data if isinstance(data, list) else data.get("data", [])

    def get_service(self, uuid: str) -> dict:
        data = self._request("GET", f"/services/{uuid}")
        if isinstance(data, dict):
            return data.get("data") if isinstance(data.get("data"), dict) else data
        return {}

    def service_status(self, uuid: str) -> str:
        return str(_dig(self.get_service(uuid), "status") or "")

    def start_service(self, uuid: str) -> dict:
        return self._request("GET", f"/services/{uuid}/start")

    def delete_service(self, uuid: str) -> None:
        self._request("DELETE", f"/services/{uuid}")

    def replace_service_envs(self, uuid: str, env: dict[str, str]) -> None:
        """Make the control-plane service's env EXACTLY `env` for kiosk-managed
        keys: upsert the desired keys and prune any non-reserved key we previously
        set that is gone — so a decommissioned/rotated control-plane secret stops
        being injected (same guarantee as the tenant path). Coolify's own
        SERVICE_*/COOLIFY_* magic is preserved."""
        self._replace_envs("services", uuid, env)

    # ── control-plane provisioning (bootstrap helpers) ─────────────────────────
    # Small read/create helpers so `coolify/provision.py` can resolve the
    # project/environment/server UUIDs from just an API token — turning the
    # dashboard's copy-the-UUIDs chore into one auto-provision step.
    def list_servers(self) -> list[dict]:
        data = self._request("GET", "/servers")
        return data if isinstance(data, list) else data.get("data", [])

    def list_projects(self) -> list[dict]:
        data = self._request("GET", "/projects")
        return data if isinstance(data, list) else data.get("data", [])

    def create_project(self, name: str, description: str = "") -> str:
        data = self._request("POST", "/projects",
                             json_body={"name": name, "description": description})
        uuid = _dig(data, "uuid")
        if not uuid:
            raise CoolifyError(f"create project: no uuid in response: {data}")
        return uuid

    def list_environments(self, project_uuid: str) -> list[dict]:
        data = self._request("GET", f"/projects/{project_uuid}/environments")
        return data if isinstance(data, list) else data.get("data", [])

    def create_environment(self, project_uuid: str, name: str) -> str:
        data = self._request("POST", f"/projects/{project_uuid}/environments",
                             json_body={"name": name})
        uuid = _dig(data, "uuid")
        if not uuid:
            raise CoolifyError(f"create environment: no uuid in response: {data}")
        return uuid

    # ── scheduled tasks (Coolify Scheduled Task == the README's cron) ──────────
    def list_scheduled_tasks(self, uuid: str) -> list[dict]:
        data = self._request("GET", f"/applications/{uuid}/scheduled-tasks")
        return data if isinstance(data, list) else data.get("data", [])

    def create_scheduled_task(self, uuid: str, *, name: str, command: str,
                              frequency: str) -> None:
        # No timezone field: Coolify runs scheduled tasks in the container's TZ
        # (typically UTC on slim base images) — there is no API knob to pin it.
        self._request("POST", f"/applications/{uuid}/scheduled-tasks", json_body={
            "name": name, "command": command, "frequency": frequency,
        })

    def update_scheduled_task(self, uuid: str, task_uuid: str, *, name: str,
                              command: str, frequency: str) -> None:
        self._request("PATCH",
                      f"/applications/{uuid}/scheduled-tasks/{task_uuid}",
                      json_body={"name": name, "command": command,
                                 "frequency": frequency})

    def delete_scheduled_task(self, uuid: str, task_uuid: str) -> None:
        self._request("DELETE", f"/applications/{uuid}/scheduled-tasks/{task_uuid}")

    # ── helpers ────────────────────────────────────────────────────────────────
    @staticmethod
    def _b64(text: str) -> str:
        return base64.b64encode(text.encode()).decode()

    @staticmethod
    def encode_custom_labels(label_map: dict[str, str]) -> str:
        """Coolify carries per-app Traefik labels as a base64-encoded, newline-
        joined `key=value` block in the application's `custom_labels` field."""
        block = "\n".join(f"{k}={v}" for k, v in label_map.items())
        return CoolifyClient._b64(block)
