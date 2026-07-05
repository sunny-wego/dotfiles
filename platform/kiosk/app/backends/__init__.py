"""Deploy backends — the seam the README calls "additive, not a migration".

`deployer.py` documents the contract: everything above the image + auth-chain
contract is engine-agnostic, so the deploy engine is swappable behind a small
interface. This package holds that interface (`base.DeployBackend`) and its two
implementations:

  * `docker`  — the README's sanctioned plain-Docker variant: drive the host
                Docker daemon directly. Default; the local/dev path.
  * `coolify` — the README's headline architecture: drive Coolify's REST API
                (deploy-from-image, env store, Scheduled Tasks, CPU/mem limits,
                TLS/domains, rollback) with the Coolify dashboard as the
                operator admin plane.

`get_backend()` selects one from `config.DEPLOY_BACKEND`, once, at import time of
the first caller. Selection is process-wide (a deploy engine is a box-level
choice, not per-request), so the instance is cached.
"""

from __future__ import annotations

from .base import DeployBackend
from ..config import config

_backend: DeployBackend | None = None


def get_backend() -> DeployBackend:
    global _backend
    if _backend is None:
        _backend = _build(config.DEPLOY_BACKEND)
    return _backend


def _build(name: str) -> DeployBackend:
    if name == "coolify":
        from .coolify.backend import CoolifyBackend
        return CoolifyBackend()
    if name == "docker":
        from .docker import DockerBackend
        return DockerBackend()
    raise RuntimeError(
        f"unknown KIOSK_DEPLOY_BACKEND={name!r}; expected 'docker' or 'coolify'")


__all__ = ["DeployBackend", "get_backend"]
