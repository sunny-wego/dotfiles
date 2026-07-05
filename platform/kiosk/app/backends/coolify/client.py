"""Thin wrapper over the Coolify v4 REST API.

Every Coolify HTTP call the kiosk makes lives here — one place to see the API
surface, one place to adjust if the endpoint shape differs on the target Coolify
version. Methods return parsed JSON (dict/list) on success and raise
`CoolifyError` on any transport/HTTP/JSON failure, so the backend can translate
one failure type into a creator-facing message + Slack escalation.

Endpoint paths follow Coolify v4's documented API. They are all funnelled
through `_request`, so pinning them to a specific Coolify release (the runbook's
EC2 parity gate) is a single-file change.
"""

from __future__ import annotations

import base64
import json

import httpx


class CoolifyError(RuntimeError):
    """Any Coolify API failure — transport, non-2xx, or unparseable body."""


class CoolifyClient:
    def __init__(self, base_url: str, token: str, timeout: float = 30.0,
                 transport: httpx.BaseTransport | None = None) -> None:
        if not base_url or not token:
            raise CoolifyError(
                "Coolify backend selected but COOLIFY_BASE_URL / "
                "COOLIFY_API_TOKEN are not set")
        # `transport` is an injection seam for tests (httpx.MockTransport); in
        # production it stays None and httpx uses its default HTTP transport.
        self._http = httpx.Client(
            base_url=base_url.rstrip("/") + "/api/v1",
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
                          environment_name: str, destination_uuid: str,
                          name: str, image: str, tag: str, port: int,
                          domain: str) -> str:
        """Create a deploy-from-image application. Returns the new app UUID."""
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
        data = self._request("POST", "/applications/dockerimage", json_body=body)
        uuid = data.get("uuid") or data.get("data", {}).get("uuid")
        if not uuid:
            raise CoolifyError(f"create app: no uuid in response: {data}")
        return uuid

    def update_app(self, uuid: str, fields: dict) -> dict:
        return self._request("PATCH", f"/applications/{uuid}", json_body=fields)

    def delete_app(self, uuid: str) -> None:
        self._request("DELETE", f"/applications/{uuid}",
                      params={"delete_volumes": "true"})

    def deploy(self, uuid: str, *, force: bool = False) -> dict:
        """Trigger a (re)deploy. Coolify runs it asynchronously; we only kick it."""
        return self._request("GET", "/deploy",
                             params={"uuid": uuid, "force": str(force).lower()})

    def logs(self, uuid: str, lines: int = 200) -> str:
        data = self._request("GET", f"/applications/{uuid}/logs",
                             params={"lines": lines})
        if isinstance(data, dict):
            return data.get("logs") or data.get("data") or json.dumps(data)
        return str(data)

    # ── environment variables (Coolify's encrypted env store) ──────────────────
    def set_envs(self, uuid: str, env: dict[str, str]) -> None:
        """Replace the app's env with `env` (bulk upsert). Coolify stores these
        encrypted and injects them at container start — the README's
        'Coolify encrypted env store'."""
        payload = {"data": [{"key": k, "value": v, "is_preview": False}
                            for k, v in env.items()]}
        self._request("PATCH", f"/applications/{uuid}/envs/bulk", json_body=payload)

    # ── scheduled tasks (Coolify Scheduled Task == the README's cron) ──────────
    def list_scheduled_tasks(self, uuid: str) -> list[dict]:
        data = self._request("GET", f"/applications/{uuid}/scheduled-tasks")
        return data if isinstance(data, list) else data.get("data", [])

    def create_scheduled_task(self, uuid: str, *, name: str, command: str,
                              frequency: str) -> None:
        self._request("POST", f"/applications/{uuid}/scheduled-tasks", json_body={
            "name": name, "command": command, "frequency": frequency,
        })

    # ── helpers ────────────────────────────────────────────────────────────────
    @staticmethod
    def encode_custom_labels(label_map: dict[str, str]) -> str:
        """Coolify carries per-app Traefik labels as a base64-encoded, newline-
        joined `key=value` block in the application's `custom_labels` field."""
        block = "\n".join(f"{k}={v}" for k, v in label_map.items())
        return base64.b64encode(block.encode()).decode()
