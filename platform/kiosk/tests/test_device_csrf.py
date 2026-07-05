"""CSRF + same-origin defenses on the device-approval endpoint.

Approving a device code mints a token that acts as the approver, so a forged or
cross-site POST to /device/approve would be token theft. These pin the guards.
No infrastructure needed — the helpers are pure request checks.
"""
from app import main


class _Req:
    def __init__(self, cookies=None, headers=None):
        self.cookies = cookies or {}
        self.headers = headers or {}


# ── double-submit CSRF token ──────────────────────────────────────────────────
def test_csrf_matches_cookie():
    assert main._csrf_ok(_Req(cookies={"kiosk_csrf": "abc"}), "abc") is True


def test_csrf_rejects_mismatch_missing_cookie_and_empty_field():
    assert main._csrf_ok(_Req(cookies={"kiosk_csrf": "abc"}), "xyz") is False
    assert main._csrf_ok(_Req(cookies={}), "abc") is False          # no cookie
    assert main._csrf_ok(_Req(cookies={"kiosk_csrf": "abc"}), "") is False  # no field


# ── same-origin check ─────────────────────────────────────────────────────────
def test_same_origin_allows_absent_and_matching_origin():
    assert main._same_origin_ok(_Req()) is True  # no Origin/Referer → allowed
    assert main._same_origin_ok(_Req(headers={
        "origin": "https://kiosk.apps.internal", "host": "kiosk.apps.internal"})) is True


def test_same_origin_rejects_foreign_origin():
    assert main._same_origin_ok(_Req(headers={
        "origin": "https://evil.example", "host": "kiosk.apps.internal"})) is False


def test_same_origin_uses_referer_when_origin_absent():
    assert main._same_origin_ok(_Req(headers={
        "referer": "https://evil.example/x", "host": "kiosk.apps.internal"})) is False
