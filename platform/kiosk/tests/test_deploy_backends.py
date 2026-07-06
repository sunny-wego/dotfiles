"""Deploy-backend guarantees.

These pin the parts a person is promised: an app is ALWAYS behind the full auth
chain (a deploy can't drop a hop), and the Coolify client talks to the documented
API with the right shapes. No Docker, no Postgres, no live Coolify.
"""
import base64

import httpx
import pytest

from app.backends import labels
from app.backends.coolify.client import CoolifyClient, CoolifyError


# ── the auth chain is identical and complete for every engine ─────────────────
def test_middleware_chain_order_is_the_full_fail_closed_chain():
    chain = labels.middleware_chain("myapp")
    # strip spoofed headers → set authoritative slug → authN → authZ, in order.
    assert chain == [
        "strip-auth-in@file",
        "slug-myapp",
        "forwardauth@file",
        "appauthz@file",
    ]


def test_tenant_labels_set_authoritative_slug_and_private_router():
    m = labels.tenant_label_map("myapp", "myapp.apps.internal", 8000, "platform_tenant")
    # X-App-Slug is Set server-side to the real slug (anti-IDOR; the kiosk trusts
    # this, never X-Forwarded-Host).
    assert (m["traefik.http.middlewares.slug-myapp.headers.customrequestheaders."
            "X-App-Slug"] == "myapp")
    # The router carries the whole chain, so it is never publicly reachable.
    assert m["traefik.http.routers.app-myapp.middlewares"] == \
        "strip-auth-in@file,slug-myapp,forwardauth@file,appauthz@file"
    assert m["traefik.http.services.app-myapp.loadbalancer.server.port"] == "8000"
    assert m["traefik.http.routers.app-myapp.tls"] == "true"


def test_coolify_custom_labels_roundtrip_preserves_chain():
    m = labels.tenant_label_map("myapp", "myapp.apps.internal", 8000, "coolnet")
    encoded = CoolifyClient.encode_custom_labels(m)
    decoded = base64.b64decode(encoded).decode()
    # The auth-chain label survives the base64 transport Coolify uses.
    assert "strip-auth-in@file,slug-myapp,forwardauth@file,appauthz@file" in decoded


# ── the Coolify client hits the documented endpoints with the right shapes ────
def _client(handler):
    return CoolifyClient("https://coolify.internal", "tok",
                         transport=httpx.MockTransport(handler))


def test_create_image_app_posts_dockerimage_and_returns_uuid():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["method"] = request.method
        seen["path"] = request.url.path
        seen["auth"] = request.headers.get("authorization")
        import json
        seen["body"] = json.loads(request.content)
        return httpx.Response(201, json={"uuid": "app-123"})

    uuid = _client(handler).create_image_app(
        project_uuid="p", server_uuid="s", environment_name="production",
        environment_uuid="env-9", destination_uuid="d", name="tenant-x",
        image="registry:5000/tenant-x", tag="1700", port=8000,
        domain="x.apps.internal")

    assert uuid == "app-123"
    assert seen["method"] == "POST"
    assert seen["path"] == "/api/v1/applications/dockerimage"
    assert seen["auth"] == "Bearer tok"
    assert seen["body"]["docker_registry_image_tag"] == "1700"
    assert seen["body"]["ports_exposes"] == "8000"
    assert seen["body"]["domains"] == "https://x.apps.internal"
    assert seen["body"]["environment_uuid"] == "env-9"  # required by Coolify


def test_replace_envs_uses_bulk_upsert_shape():
    bulk = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json
        if request.method == "PATCH":
            bulk["path"] = request.url.path
            bulk["body"] = json.loads(request.content)
            return httpx.Response(200, json={})
        return httpx.Response(200, json=[])  # GET list_envs → nothing to prune

    _client(handler).replace_envs("app-123", {"DATABASE_URL": "postgres://x", "PORT": "8000"})
    assert bulk["path"] == "/api/v1/applications/app-123/envs/bulk"
    keys = {e["key"] for e in bulk["body"]["data"]}
    assert keys == {"DATABASE_URL", "PORT"}
    assert all(e["is_preview"] is False for e in bulk["body"]["data"])


def test_deploy_triggers_with_uuid_and_force():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["path"] = request.url.path
        seen["params"] = dict(request.url.params)
        return httpx.Response(200, json={"deployments": []})

    _client(handler).deploy("app-123", force=True)
    assert seen["path"] == "/api/v1/deploy"
    assert seen["params"] == {"uuid": "app-123", "force": "true"}


def test_http_error_becomes_coolify_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(422, text="unprocessable")

    with pytest.raises(CoolifyError):
        _client(handler).update_app("nope", {})


def test_unconfigured_client_fails_at_call_not_construction():
    # Construction must NOT raise (that would 500 web routes that merely build
    # the backend); the failure surfaces as a clean CoolifyError when a call is
    # actually made, which the backend catches.
    c = CoolifyClient("", "")  # no raise
    with pytest.raises(CoolifyError):
        c.update_app("x", {})


def test_replace_envs_upserts_then_prunes_removed_nonreserved_keys():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path))
        if request.method == "GET":  # list existing envs
            return httpx.Response(200, json=[
                {"key": "DATABASE_URL", "uuid": "e1"},   # still desired — keep
                {"key": "OLD_SECRET", "uuid": "e2"},     # gone — must delete
                {"key": "COOLIFY_URL", "uuid": "e3"},    # reserved — never touch
            ])
        return httpx.Response(200, json={})

    _client(handler).replace_envs("app-1", {"DATABASE_URL": "x", "PORT": "8000"})
    assert ("PATCH", "/api/v1/applications/app-1/envs/bulk") in calls
    # Only the stale, non-reserved key is deleted.
    assert ("DELETE", "/api/v1/applications/app-1/envs/e2") in calls
    assert not any(m == "DELETE" and p.endswith(("/e1", "/e3")) for m, p in calls)


# ── Coolify-managed databases (per-tenant Postgres) ──────────────────────────
def test_create_postgres_posts_creds_and_returns_uuid():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json
        seen["path"] = request.url.path
        seen["body"] = json.loads(request.content)
        return httpx.Response(201, json={"uuid": "db-77"})

    uuid = _client(handler).create_postgres(
        project_uuid="p", server_uuid="s", environment_name="production",
        environment_uuid="env-9", destination_uuid="d", name="tenant-x-db",
        db_name="d_x", db_user="t_x", db_password="pw")

    assert uuid == "db-77"
    assert seen["path"] == "/api/v1/databases/postgresql"
    assert seen["body"]["postgres_db"] == "d_x"
    assert seen["body"]["postgres_user"] == "t_x"
    assert seen["body"]["environment_uuid"] == "env-9"
    assert seen["body"]["instant_deploy"] is True


def test_database_url_reads_internal_url_and_normalises_scheme():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={
            "uuid": "db-77", "status": "running",
            "internal_db_url": "postgres://t_x:pw@db-host:5432/d_x"})

    # postgres:// → postgresql:// (what mainstream ORMs expect).
    assert _client(handler).database_url("db-77") == \
        "postgresql://t_x:pw@db-host:5432/d_x"


def test_database_url_missing_internal_url_raises():
    bad = _client(lambda r: httpx.Response(200, json={"uuid": "db-77"}))
    with pytest.raises(CoolifyError):
        bad.database_url("db-77")


def test_create_backup_posts_frequency_and_returns_uuid():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json
        seen["path"] = request.url.path
        seen["body"] = json.loads(request.content)
        return httpx.Response(201, json={"uuid": "bk-1", "message": "ok"})

    uuid = _client(handler).create_backup("db-77", frequency="daily",
                                          retention_days_locally=7)
    assert uuid == "bk-1"
    assert seen["path"] == "/api/v1/databases/db-77/backups"
    assert seen["body"]["frequency"] == "daily"
    assert seen["body"]["enabled"] is True
    assert seen["body"]["save_s3"] is False


# ── self-hosting the control plane as a Coolify service (Option B) ───────────
def test_kiosk_label_map_is_google_only_not_per_app_authz():
    m = labels.kiosk_label_map("kiosk.apps.internal", "platform_tenant")
    # The kiosk UI sits behind company Google, NOT the per-app slug/appauthz hops.
    assert m["traefik.http.routers.kiosk.middlewares"] == \
        "strip-auth-in@file,forwardauth@file"
    assert "appauthz@file" not in m["traefik.http.routers.kiosk.middlewares"]
    assert m["traefik.http.routers.kiosk.rule"] == "Host(`kiosk.apps.internal`)"
    assert m["traefik.http.services.kiosk.loadbalancer.server.port"] == "8000"
    # No slug middleware is emitted for the kiosk itself.
    assert not any("middlewares.slug-" in k for k in m)


def test_create_service_posts_base64_compose_and_returns_uuid():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json
        seen["path"] = request.url.path
        seen["body"] = json.loads(request.content)
        return httpx.Response(201, json={"uuid": "svc-1", "domains": ["https://kiosk.x"]})

    compose = "services:\n  kiosk:\n    image: platform/kiosk:m1\n"
    uuid = _client(handler).create_service(
        project_uuid="p", server_uuid="s", environment_name="production",
        environment_uuid="env-9", destination_uuid="d",
        name="platform-control-plane", compose=compose)

    assert uuid == "svc-1"
    assert seen["path"] == "/api/v1/services"
    # The compose is sent base64-encoded and round-trips exactly.
    assert base64.b64decode(seen["body"]["docker_compose_raw"]).decode() == compose
    assert seen["body"]["environment_uuid"] == "env-9"


def test_logs_empty_string_is_not_a_json_dump():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"logs": ""})

    assert _client(handler).logs("app-1") == ""


def test_create_image_app_tolerates_wrapped_and_rejects_bad_shapes():
    # Wrapped in {"data": {...}} → extracted, not crashed.
    ok = _client(lambda r: httpx.Response(201, json={"data": {"uuid": "u9"}}))
    assert ok.create_image_app(
        project_uuid="p", server_uuid="s", environment_name="e",
        environment_uuid="ev", destination_uuid="d", name="n", image="i",
        tag="t", port=8000, domain="h") == "u9"
    # A list body (no uuid) → CoolifyError, never AttributeError.
    bad = _client(lambda r: httpx.Response(201, json=[]))
    with pytest.raises(CoolifyError):
        bad.create_image_app(
            project_uuid="p", server_uuid="s", environment_name="e",
            environment_uuid="ev", destination_uuid="d", name="n", image="i",
            tag="t", port=8000, domain="h")
