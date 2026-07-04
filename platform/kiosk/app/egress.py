"""Default-deny egress + per-app outbound allowlist.

Two layers, structural first:

  1. Structural (load-bearing): tenant containers live ONLY on an internal
     docker network with no route to the internet. That alone blocks all
     outbound — the README's "structural boundary".
  2. Allowlist: a shared squid proxy has internet access and an ACL sourced from
     a file the kiosk regenerates (the union of every app's allowlist). An app
     is given HTTPS_PROXY only when it has ≥1 allowlisted domain; otherwise it
     gets no proxy env and stays fully egress-denied.

v1 residual (documented): the squid ACL is the *union* across apps, not
per-source — app A could in principle reach app B's allowlisted domain. Fine for
the trusted-internal model; per-source ACLs are a later hardening.
"""

from __future__ import annotations

import os

from . import dockercli, db
from .config import config


def proxy_env_for(slug: str) -> dict[str, str]:
    """Env to inject so an app can reach ITS allowlisted domains (only)."""
    domains = db.list_egress(slug)
    if not domains or not config.EGRESS_PROXY:
        return {}  # no allowlist -> no proxy -> fully egress-denied by the network
    proxy = f"http://{config.EGRESS_PROXY}"
    no_proxy = f"localhost,127.0.0.1,{config.PG_TENANT_HOST},litellm"
    return {
        "HTTP_PROXY": proxy, "HTTPS_PROXY": proxy,
        "http_proxy": proxy, "https_proxy": proxy,
        "NO_PROXY": no_proxy, "no_proxy": no_proxy,
    }


def regenerate_allowlist(log=lambda *_: None) -> None:
    """Rewrite the squid allowlist file (union of all apps) and reload squid."""
    path = config.EGRESS_ALLOWLIST_FILE
    domains = db.all_egress_domains()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("\n".join(domains) + ("\n" if domains else ""))
    except OSError as e:
        log(f"[egress] could not write allowlist ({e}); is the /egress volume mounted?")
        return
    # squid re-reads dstdomain files on reconfigure. Best-effort.
    res = dockercli.run(["exec", "egress-proxy", "squid", "-k", "reconfigure"], timeout=30)
    log(f"[egress] allowlist -> {len(domains)} domain(s)"
        + ("" if res.ok else " (squid reload skipped: proxy not running)"))
