"""Traefik labels — the auth chain, defined once.

A tenant app must sit behind the *complete* chain, because that chain is a
load-bearing security boundary (README §9):

    strip-auth-in  → clear client-supplied identity/routing headers at ingress
    slug-<slug>    → Set X-App-Slug authoritatively (server-side; the kiosk
                     trusts THIS, never X-Forwarded-Host — anti-IDOR)
    forwardauth    → company Google (authN + domain)
    appauthz       → kiosk /internal/authz (whole-app allow-list, fail-closed)

The Coolify backend emits this as application custom labels; keeping the chain in
one module (pinned by a test) means a deploy can't silently drop a hop.
"""

from __future__ import annotations

# The file-provider middlewares (installed into Coolify's proxy via
# coolify/traefik-dynamic.yml).
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
    """The full Traefik label set for a tenant app: routing, TLS, the
    authoritative X-App-Slug header, the middleware chain, and the service port.
    Returned as {label: value}; the Coolify backend base64-encodes it into the
    application's custom-labels field."""
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
