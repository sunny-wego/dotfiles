"""Token auth for the non-browser (CLI / agent) surface.

Proves a personal API token resolves to its owner's company identity, that the
company-domain guarantee holds for tokens exactly as for browser headers, and
that revocation takes effect. Needs Postgres; skips cleanly without one.
"""
import os

os.environ.setdefault("DATABASE_URL", "postgresql://kiosk:kiosk@localhost:55432/kiosk")
os.environ.setdefault("PG_ADMIN_URL", os.environ["DATABASE_URL"])

import pytest  # noqa: E402
import psycopg  # noqa: E402

try:
    psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=2).close()
except Exception as exc:  # noqa: BLE001
    pytest.skip(f"Postgres not reachable ({exc}); skipping token tests",
                allow_module_level=True)

from fastapi import HTTPException  # noqa: E402

from app import auth, db  # noqa: E402


@pytest.fixture(scope="module", autouse=True)
def _schema():
    db.init()
    yield


@pytest.fixture(autouse=True)
def _clean():
    with db.cursor() as cur:
        cur.execute("DELETE FROM api_tokens")
    yield


class _Req:
    """Minimal stand-in for a Starlette Request (auth.identity only reads
    .headers.get)."""
    def __init__(self, **headers):
        self.headers = {k.lower(): v for k, v in headers.items()}


def test_token_resolves_to_owner_email():
    tok = "ksk_probe_token_1"
    db.create_api_token("dev@wego.com", tok, "cli")
    assert db.email_for_token(tok) == "dev@wego.com"
    assert db.email_for_token("ksk_wrong") is None


def test_identity_accepts_bearer_token():
    tok = "ksk_probe_token_2"
    db.create_api_token("dev@wego.com", tok, "cli")
    assert auth.identity(_Req(authorization=f"Bearer {tok}")) == "dev@wego.com"


def test_identity_prefers_browser_header():
    assert auth.identity(_Req(**{"x-auth-request-email": "web@wego.com"})) == "web@wego.com"


def test_identity_rejects_no_credentials():
    with pytest.raises(HTTPException) as e:
        auth.identity(_Req())
    assert e.value.status_code == 401


def test_identity_rejects_unknown_token():
    with pytest.raises(HTTPException) as e:
        auth.identity(_Req(authorization="Bearer ksk_nope"))
    assert e.value.status_code == 401


def test_company_domain_enforced_for_tokens_too():
    # A token whose owner is outside the company domain is still denied at use.
    tok = "ksk_intruder"
    db.create_api_token("intruder@gmail.com", tok, "x")
    with pytest.raises(HTTPException) as e:
        auth.identity(_Req(authorization=f"Bearer {tok}"))
    assert e.value.status_code == 403


def test_revoke_invalidates_token():
    tok = "ksk_probe_token_3"
    db.create_api_token("dev@wego.com", tok, "cli")
    tid = db.list_api_tokens("dev@wego.com")[0]["id"]
    assert db.revoke_api_token("dev@wego.com", tid) is True
    assert db.email_for_token(tok) is None
    with pytest.raises(HTTPException) as e:
        auth.identity(_Req(authorization=f"Bearer {tok}"))
    assert e.value.status_code == 401
