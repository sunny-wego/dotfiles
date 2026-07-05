"""Deploy backend — Coolify.

The kiosk drives Coolify's REST API on the creator's behalf (deploy-from-image,
encrypted env store, Scheduled Tasks, CPU/mem limits, TLS/domains, rollback);
operators use the Coolify dashboard as the admin plane. See `coolify/backend.py`
and `coolify/client.py`.

`get_backend()` returns the single process-wide instance (a deploy engine is a
box-level choice, not per-request), so it is cached.
"""

from __future__ import annotations

_backend = None


def get_backend():
    """Return the process-wide CoolifyBackend (built lazily so importing this
    package — e.g. for `labels` — doesn't require the backend's heavy deps)."""
    global _backend
    if _backend is None:
        from .coolify.backend import CoolifyBackend
        _backend = CoolifyBackend()
    return _backend


__all__ = ["get_backend"]
