"""Symmetric encryption for secrets at rest (tenant DB passwords, app secrets).

Uses Fernet (AES-128-CBC + HMAC) with a key from KIOSK_SECRET_KEY. The key must
be stable across restarts or existing ciphertext can't be decrypted, so it is
required in any real deployment; for local dev a fixed key lives in .env.

This encrypts the metadata-DB-at-rest copy of secrets. They are still injected
as plaintext env into tenant containers at deploy — the README's model is
"encrypted env store", not sealed-from-the-app.
"""

from __future__ import annotations

import base64
import hashlib
import os

from cryptography.fernet import Fernet

from .config import config


def assert_key_secure() -> None:
    """Refuse the shipped/empty key in production. Enforced HERE — the single
    path every entrypoint (web, cron, CLI, tests) funnels through — rather than
    only at web startup, so no side door encrypts secrets under a public key."""
    if config.AUTH_MODE == "google" and config.SECRET_KEY in ("", config.INSECURE_SECRET_KEY):
        raise RuntimeError(
            "KIOSK_SECRET_KEY is the insecure default; refusing to use it in "
            "google mode. Set a real key (openssl rand -base64 32).")


def _fernet() -> Fernet:
    assert_key_secure()
    raw = config.SECRET_KEY or config.INSECURE_SECRET_KEY  # dev fallback only
    # Accept either a proper 44-char urlsafe base64 Fernet key, or any string
    # (which we hash into 32 bytes) so operators can set a human-friendly value.
    try:
        if len(raw) == 44:
            return Fernet(raw.encode())
    except Exception:  # noqa: BLE001
        pass
    key = base64.urlsafe_b64encode(hashlib.sha256(raw.encode()).digest())
    return Fernet(key)


def encrypt(plaintext: str) -> str:
    return _fernet().encrypt(plaintext.encode()).decode()


def decrypt(ciphertext: str) -> str:
    return _fernet().decrypt(ciphertext.encode()).decode()


def random_token(nbytes: int = 24) -> str:
    return base64.urlsafe_b64encode(os.urandom(nbytes)).decode().rstrip("=")
