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

from __future__ import annotations

from . import db
from .config import config


def domain_ok(email: str) -> bool:
    email = (email or "").lower()
    return "@" in email and email.rsplit("@", 1)[1] == config.COMPANY_EMAIL_DOMAIN.lower()


def can_open(slug: str, email: str) -> bool:
    email = (email or "").lower()
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
