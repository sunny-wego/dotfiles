"""Deploy-backend guarantees that hold regardless of engine.

These pin the parts a person is promised: an app is ALWAYS behind the full auth
chain (no engine may drop a hop), the Coolify client talks to the documented API
with the right shapes, and an unknown backend name fails loudly instead of
silently deploying nothing. No Docker, no Postgres, no live Coolify.
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


def test_docker_label_args_flatten_to_pairs():
    args = labels.docker_label_args("a", "a.apps.localhost", 3000, "net")
    assert args.count("--label") == len(labels.tenant_label_map("a", "a.apps.localhost", 3000, "net"))
    # Every value follows a --label flag.
    assert all(args[i] == "--label" for i in range(0, len(args), 2))


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
        destination_uuid="d", name="tenant-x", image="registry:5000/tenant-x",
        tag="1700", port=8000, domain="x.apps.internal")

    assert uuid == "app-123"
    assert seen["method"] == "POST"
    assert seen["path"] == "/api/v1/applications/dockerimage"
    assert seen["auth"] == "Bearer tok"
    assert seen["body"]["docker_registry_image_tag"] == "1700"
    assert seen["body"]["ports_exposes"] == "8000"
    assert seen["body"]["domains"] == "https://x.apps.internal"


def test_set_envs_uses_bulk_upsert_shape():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json
        seen["path"] = request.url.path
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={})

    _client(handler).set_envs("app-123", {"DATABASE_URL": "postgres://x", "PORT": "8000"})
    assert seen["path"] == "/api/v1/applications/app-123/envs/bulk"
    keys = {e["key"] for e in seen["body"]["data"]}
    assert keys == {"DATABASE_URL", "PORT"}
    assert all(e["is_preview"] is False for e in seen["body"]["data"])


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
        _client(handler).get_app("nope")


def test_missing_credentials_fail_loudly():
    with pytest.raises(CoolifyError):
        CoolifyClient("", "")


# ── backend selection ─────────────────────────────────────────────────────────
def test_unknown_backend_name_raises():
    from app.backends import _build
    with pytest.raises(RuntimeError):
        _build("kubernetes")
