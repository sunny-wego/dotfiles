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
            "destination_uuid": destination_uuid,
            "name": name,
            "docker_registry_image_name": image,
            "docker_registry_image_tag": tag,
            "ports_exposes": str(port),
            "domains": f"https://{domain}",
            "instant_deploy": False,
        }
        if environment_uuid:
            body["environment_uuid"] = environment_uuid
        data = self._request("POST", "/applications/dockerimage", json_body=body)
        uuid = _dig(data, "uuid")
        if not uuid:
            raise CoolifyError(f"create app: no uuid in response: {data}")
        return uuid

    def update_app(self, uuid: str, fields: dict) -> dict:
        return self._request("PATCH", f"/applications/{uuid}", json_body=fields)

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
    # prefix; SOURCE_COMMIT is its one common non-prefixed one. Verify this set
    # against the target Coolify version on the parity gate.
    _RESERVED_ENV = ("SOURCE_COMMIT",)

    def replace_envs(self, uuid: str, env: dict[str, str]) -> None:
        """Make the app's env EXACTLY `env` (for kiosk-managed keys): bulk-upsert
        the desired keys, then delete any key we previously set that is no longer
        present — so a removed/rotated secret actually stops being injected.
        Coolify-managed keys are left untouched."""
        payload = {"data": [{"key": k, "value": v, "is_preview": False}
                            for k, v in env.items()]}
        self._request("PATCH", f"/applications/{uuid}/envs/bulk", json_body=payload)
        desired = set(env)
        for row in self.list_envs(uuid):
            key = row.get("key")
            if (not key or key in desired or key.startswith("COOLIFY_")
                    or key in self._RESERVED_ENV):
                continue
            env_uuid = row.get("uuid") or row.get("id")
            if env_uuid:
                self.delete_env(uuid, env_uuid)

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
    def encode_custom_labels(label_map: dict[str, str]) -> str:
        """Coolify carries per-app Traefik labels as a base64-encoded, newline-
        joined `key=value` block in the application's `custom_labels` field."""
        block = "\n".join(f"{k}={v}" for k, v in label_map.items())
        return base64.b64encode(block.encode()).decode()
