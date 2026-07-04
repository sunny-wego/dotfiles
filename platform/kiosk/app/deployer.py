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


def deploy(slug: str, image: str, port: int) -> tuple[bool, str, str]:
    """Return (ok, url, message)."""
    name = f"app-{slug}"
    host = config.app_host(slug)
    dockercli.rm_force(name)

    router = f"app-{slug}"
    labels = [
        "--label", "traefik.enable=true",
        "--label", f"traefik.docker.network={config.PROXY_NETWORK}",
        "--label", f"traefik.http.routers.{router}.rule=Host(`{host}`)",
        "--label", f"traefik.http.routers.{router}.entrypoints=websecure",
        "--label", f"traefik.http.routers.{router}.tls=true",
        # strip spoofed identity headers, then require company Google login.
        "--label",
        f"traefik.http.routers.{router}.middlewares=strip-auth-in@file,forwardauth@file",
        "--label",
        f"traefik.http.services.{router}.loadbalancer.server.port={port}",
    ]
    res = dockercli.run([
        "run", "-d", "--name", name, "--restart", "unless-stopped",
        "--network", config.PROXY_NETWORK,
        "-e", f"PORT={port}",
        *labels,
        image,
    ], timeout=120)

    if not res.ok:
        return False, "", f"deploy failed:\n{res.out[-500:]}"
    return True, f"https://{host}", "deployed behind Google login"


def app_logs(slug: str, tail: int = 200) -> str:
    """Creator-facing logs — surfaced in the Kiosk (creators never open the
    engine)."""
    return dockercli.logs(f"app-{slug}", tail=tail)


def teardown(slug: str) -> None:
    dockercli.rm_force(f"app-{slug}")
