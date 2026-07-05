"""Identity extraction + company-domain enforcement.

Two ways in, one identity out:
  * Browser (web UI): oauth2-proxy / dev stub sets X-Auth-Request-* headers,
    forwarded by Traefik's forward-auth.
  * Non-browser (the `kiosk` CLI + agent skill): a personal API token in
    `Authorization: Bearer <token>`, resolved to its owner's email.

Either way the kiosk independently enforces the company domain, so the same
"non-company identity is denied" guarantee — and the same audit actor + per-app
RBAC — hold regardless of which surface the request came from.
"""

from __future__ import annotations

from fastapi import HTTPException, Request

from . import db
from .config import config


def identity(request: Request) -> str:
    email = request.headers.get("x-auth-request-email", "").strip().lower()
    if not email:
        # No browser identity: fall back to a personal API token (CLI surface).
        auth_header = request.headers.get("authorization", "")
        if auth_header[:7].lower() == "bearer ":
            email = (db.email_for_token(auth_header[7:].strip()) or "").lower()
    if not email:
        # Neither a forwarded identity nor a valid token.
        raise HTTPException(status_code=401, detail="not authenticated")
    domain = email.rsplit("@", 1)[-1] if "@" in email else ""
    if domain != config.COMPANY_EMAIL_DOMAIN.lower():
        raise HTTPException(
            status_code=403,
            detail=f"access denied: {email} is outside @{config.COMPANY_EMAIL_DOMAIN}",
        )
    return email
