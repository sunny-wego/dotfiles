"""CSRF + same-origin defense on state-changing browser requests.

State-changing POSTs (device approval, deploy, secrets, tokens, …) that mint or
mutate under the caller's identity must resist forged cross-site requests. The
guard is Bearer-exempt (CLI tokens aren't sent ambiently, so aren't CSRF-able)
and double-submit for browsers. No infrastructure needed — pure request checks.
"""
import pytest
from fastapi import HTTPException

from app import main


class _Req:
    def __init__(self, cookies=None, headers=None):
        self.cookies = cookies or {}
        self.headers = headers or {}


def _raises(req, submitted=""):
    try:
        main._enforce_csrf(req, submitted)
        return False
    except HTTPException as e:
        assert e.status_code == 403
        return True


# ── Bearer (CLI) is exempt — a token isn't a CSRF vector ──────────────────────
def test_bearer_token_requests_are_exempt():
    # No cookie, no field, but a Bearer header → allowed (CLI path).
    assert _raises(_Req(headers={"authorization": "Bearer ksk_x"})) is False


# ── browser double-submit ─────────────────────────────────────────────────────
def test_browser_matching_field_ok():
    assert _raises(_Req(cookies={"kiosk_csrf": "t"}), submitted="t") is False


def test_browser_matching_header_ok():
    assert _raises(_Req(cookies={"kiosk_csrf": "t"},
                        headers={"x-csrf-token": "t"})) is False


def test_browser_missing_or_mismatched_token_rejected():
    assert _raises(_Req(cookies={"kiosk_csrf": "t"}), submitted="") is True   # no field
    assert _raises(_Req(cookies={"kiosk_csrf": "t"}), submitted="x") is True  # mismatch
    assert _raises(_Req(cookies={}), submitted="t") is True                   # no cookie


def test_foreign_origin_rejected_even_with_valid_token():
    assert _raises(_Req(cookies={"kiosk_csrf": "t"},
                        headers={"origin": "https://evil.example",
                                 "host": "kiosk.apps.internal"}),
                   submitted="t") is True


# ── same-origin helper ────────────────────────────────────────────────────────
def test_same_origin_allows_absent_and_matching():
    assert main._same_origin_ok(_Req()) is True
    assert main._same_origin_ok(_Req(headers={
        "origin": "https://kiosk.apps.internal", "host": "kiosk.apps.internal"})) is True


def test_same_origin_rejects_foreign_and_uses_referer_fallback():
    assert main._same_origin_ok(_Req(headers={
        "origin": "https://evil.example", "host": "kiosk.apps.internal"})) is False
    assert main._same_origin_ok(_Req(headers={
        "referer": "https://evil.example/x", "host": "kiosk.apps.internal"})) is False
