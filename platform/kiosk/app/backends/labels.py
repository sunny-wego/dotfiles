"""Traefik labels — the auth chain, defined once for every engine.

Both the plain-Docker deployer (container labels) and the Coolify deployer
(application custom labels) must put a tenant app behind the *identical* chain,
because that chain is a load-bearing security boundary (README §9):

    strip-auth-in  → clear client-supplied identity/routing headers at ingress
    slug-<slug>    → Set X-App-Slug authoritatively (server-side; the kiosk
                     trusts THIS, never X-Forwarded-Host — anti-IDOR)
    forwardauth    → company Google (authN + domain)
    appauthz       → kiosk /internal/authz (whole-app allow-list, fail-closed)

Defining the chain in one module means an engine can't silently drop a hop: the
docker backend and the coolify backend build from the same functions, and a
single test pins the order.
"""

from __future__ import annotations

# The file-provider middlewares (defined in traefik/dynamic.yml for the compose
# stack, and in coolify/traefik-dynamic.yml for the Coolify proxy).
STRIP_AUTH_IN = "strip-auth-in@file"
FORWARD_AUTH = "forwardauth@file"
APP_AUTHZ = "appauthz@file"


def slug_middleware(slug: str) -> str:
    """Name of the per-app middleware that Set-overwrites X-App-Slug."""
    return f"slug-{slug}"


def middleware_chain(slug: str) -> list[str]:
    """The ordered forward-auth chain a tenant router must carry. Order matters:
    strip spoofed headers first, set authoritative slug, then authN, then authZ.

    The per-app slug middleware is referenced by bare name: it is defined by the
    same (docker) provider as the router, so Traefik resolves it in-provider —
    matching the M1-verified routing exactly."""
    return [STRIP_AUTH_IN, slug_middleware(slug), FORWARD_AUTH, APP_AUTHZ]


def tenant_label_map(slug: str, host: str, port: int, network: str) -> dict[str, str]:
    """The full Traefik label set for a plain-Docker tenant container: routing,
    TLS, the authoritative X-App-Slug header, the middleware chain, and the
    service port. Returned as {label: value} so callers format it however their
    engine wants (`--label k=v` for docker run; custom-label lines for Coolify)."""
    router = f"app-{slug}"
    slug_mw = slug_middleware(slug)
    chain = ",".join(middleware_chain(slug))
    return {
        "traefik.enable": "true",
        "traefik.docker.network": network,
        f"traefik.http.routers.{router}.rule": f"Host(`{host}`)",
        f"traefik.http.routers.{router}.entrypoints": "websecure",
        f"traefik.http.routers.{router}.tls": "true",
        # Authoritative, server-set app identity for the authz hop. Set()
        # overwrites any client-supplied X-App-Slug; strip-auth-in also clears
        # it on ingress. This is what the kiosk trusts — never X-Forwarded-Host.
        f"traefik.http.middlewares.{slug_mw}.headers.customrequestheaders.X-App-Slug": slug,
        f"traefik.http.routers.{router}.middlewares": chain,
        f"traefik.http.services.{router}.loadbalancer.server.port": str(port),
    }


def docker_label_args(slug: str, host: str, port: int, network: str) -> list[str]:
    """Flatten tenant_label_map into `--label k=v` argv for `docker run`."""
    args: list[str] = []
    for key, val in tenant_label_map(slug, host, port, network).items():
        args += ["--label", f"{key}={val}"]
    return args
