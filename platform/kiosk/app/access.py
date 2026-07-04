"""Whole-app allow-list authorization (v1 authZ).

M1 gave us authN (company Google) + a company-domain check. v1 adds "only the
right people can open THIS app": a per-app allow-list, enforced at the proxy as
a second forward-auth hop (see main.internal_authz) so it holds with zero app
code — a denied user never reaches the container.

Rules (fail-closed):
  * identity must be inside the company domain (defense in depth);
  * the app owner is always allowed;
  * visibility=all-staff  -> any company user may open it;
  * visibility=invite-only -> only listed principals (emails) may open it.

Google Group principals ("group:eng@company") are recognised in the schema but
group membership resolution is deferred (documented) — v1 uses explicit emails.
"""

import threading
import time

from . import db
from .config import config

# Short-TTL decision cache: internal_authz runs on EVERY tenant request, so
# without this the metadata DB is a full-traffic SPOF (README: "authz serves
# from a local cache with explicit staleness bounds, invalidated on role
# change"). Staleness is bounded by the TTL and by invalidate() on any change.
_CACHE_TTL = 30.0
_CACHE_MAX = 5000
_cache: dict[tuple[str, str], tuple[float, bool]] = {}
_lock = threading.Lock()


def domain_ok(email: str) -> bool:
    email = (email or "").lower()
    return "@" in email and email.rsplit("@", 1)[1] == config.COMPANY_EMAIL_DOMAIN.lower()


def invalidate(slug: str | None = None) -> None:
    """Drop cached decisions — for one app on role/visibility change, or all."""
    with _lock:
        if slug is None:
            _cache.clear()
        else:
            for k in [k for k in _cache if k[0] == slug]:
                _cache.pop(k, None)


def can_open(slug: str, email: str) -> bool:
    email = (email or "").lower()
    key = (slug, email)
    now = time.time()
    with _lock:
        hit = _cache.get(key)
        if hit is not None and hit[0] > now:
            return hit[1]
    result = _compute(slug, email)
    with _lock:
        if len(_cache) > _CACHE_MAX:
            _cache.clear()
        _cache[key] = (now + _CACHE_TTL, result)
    return result


def _compute(slug: str, email: str) -> bool:
    if not domain_ok(email):
        return False
    app = db.get_app(slug)
    if app is None:
        return False
    if email == (app.get("owner") or "").lower():
        return True
    if app.get("visibility") == "all-staff":
        return True
    return email in set(db.list_access(slug))
