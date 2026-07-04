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


def _fernet() -> Fernet:
    raw = config.SECRET_KEY
    if not raw:
        # Dev fallback only. Production use of this key is blocked at startup
        # (see main._startup, which refuses google mode with the default key).
        raw = config.INSECURE_SECRET_KEY
    # Accept either a proper 44-char urlsafe base64 Fernet key, or any string
    # (which we hash into 32 bytes) so operators can set a human-friendly value.
    try:
        if len(raw) == 44:
            Fernet(raw.encode())
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
