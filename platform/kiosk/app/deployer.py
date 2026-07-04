"""Deploy-from-image onto the one box (plain-Docker variant).

Runs the verified, pushed image as a long-lived container on the proxy network
with Traefik labels, so it gets a hostname + TLS and sits BEHIND forward-auth
(private by default — the README's non-negotiable). Idempotent: re-deploying a
slug replaces the previous container.

This is deliberately behind a small interface (`deploy`, `app_logs`, `teardown`)
so a Coolify-API deployer is a drop-in addition later — the seam the README
calls "additive, not a migration". Nothing above the image contract changes.
"""

from __future__ import annotations

from . import dockercli
from .config import config


def deploy(slug: str, image: str, port: int,
           env: dict[str, str] | None = None) -> tuple[bool, str, str]:
    """Return (ok, url, message).

    The app runs on the internal tenant network (no direct egress — v1's
    default-deny boundary) and behind the auth chain: strip spoofed identity
    headers -> company Google (forwardauth) -> per-app allow-list (appauthz).
    """
    name = f"app-{slug}"
    host = config.app_host(slug)
    dockercli.rm_force(name)

    router = f"app-{slug}"
    slug_mw = f"slug-{slug}"
    labels = [
        "--label", "traefik.enable=true",
        "--label", f"traefik.docker.network={config.TENANT_NETWORK}",
        "--label", f"traefik.http.routers.{router}.rule=Host(`{host}`)",
        "--label", f"traefik.http.routers.{router}.entrypoints=websecure",
        "--label", f"traefik.http.routers.{router}.tls=true",
        # Authoritative, server-set app identity for the authz hop. Set()
        # overwrites any client-supplied X-App-Slug; strip-auth-in also clears
        # it on ingress. This is what the kiosk trusts — never X-Forwarded-Host.
        "--label",
        f"traefik.http.middlewares.{slug_mw}.headers.customrequestheaders.X-App-Slug={slug}",
        "--label",
        f"traefik.http.routers.{router}.middlewares="
        f"strip-auth-in@file,{slug_mw},forwardauth@file,appauthz@file",
        "--label",
        f"traefik.http.services.{router}.loadbalancer.server.port={port}",
    ]
    envargs: list[str] = ["-e", f"PORT={port}"]
    for k, v in (env or {}).items():
        envargs += ["-e", f"{k}={v}"]

    res = dockercli.run([
        "run", "-d", "--name", name, "--restart", "unless-stopped",
        "--network", config.TENANT_NETWORK,
        *envargs,
        *labels,
        image,
    ], timeout=120)

    if not res.ok:
        return False, "", f"deploy failed:\n{res.out[-500:]}"
    return True, f"https://{host}", "deployed behind Google login + allow-list"


def app_logs(slug: str, tail: int = 200) -> str:
    """Creator-facing logs — surfaced in the Kiosk (creators never open the
    engine)."""
    return dockercli.logs(f"app-{slug}", tail=tail)


def teardown(slug: str) -> None:
    dockercli.rm_force(f"app-{slug}")
