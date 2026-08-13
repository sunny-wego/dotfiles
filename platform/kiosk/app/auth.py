"""Identity extraction + company-domain enforcement.

oauth2-proxy (google mode) or the dev stub (dev mode) sets X-Auth-Request-*
headers, which Traefik's forward-auth forwards. The kiosk reads the identity and
independently enforces the company domain in BOTH modes — so the M1 done-when
"a non-company Google account is denied" is exercised locally by pointing
DEV_USER_EMAIL at a non-company address.
"""

from __future__ import annotations

from fastapi import HTTPException, Request

from .config import config


def identity(request: Request) -> str:
    email = request.headers.get("x-auth-request-email", "").strip().lower()
    if not email:
        # No identity injected: forward-auth is misconfigured or bypassed.
        raise HTTPException(status_code=401, detail="not authenticated")
    domain = email.rsplit("@", 1)[-1] if "@" in email else ""
    if domain != config.COMPANY_EMAIL_DOMAIN.lower():
        raise HTTPException(
            status_code=403,
            detail=f"access denied: {email} is outside @{config.COMPANY_EMAIL_DOMAIN}",
        )
    return email
