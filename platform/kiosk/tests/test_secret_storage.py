"""Promise: your secrets are stored encrypted, and the platform won't run
insecurely in production.

App secrets and tenant DB passwords are encrypted at rest, and a production
(google-auth) deployment refuses to start under the shipped default key — so no
one accidentally ships secrets encrypted with a public value.
"""
import pytest

from app import crypto


def test_a_stored_secret_round_trips_and_is_not_kept_in_the_clear():
    plaintext = "hunter2-super-secret"
    stored = crypto.encrypt(plaintext)
    assert stored != plaintext                 # not stored as-is
    assert plaintext not in stored             # and not embedded anywhere in it
    assert crypto.decrypt(stored) == plaintext  # but recoverable by the platform


def test_production_refuses_the_shipped_default_key(monkeypatch):
    monkeypatch.setattr(crypto.config, "AUTH_MODE", "google")
    monkeypatch.setattr(crypto.config, "SECRET_KEY", crypto.config.INSECURE_SECRET_KEY)
    # The guard fires, and it fires at the point of use too (not just startup).
    with pytest.raises(RuntimeError):
        crypto.assert_key_secure()
    with pytest.raises(RuntimeError):
        crypto.encrypt("secret")


def test_production_accepts_a_real_key(monkeypatch):
    monkeypatch.setattr(crypto.config, "AUTH_MODE", "google")
    monkeypatch.setattr(crypto.config, "SECRET_KEY", "a-real-operator-provided-key")
    crypto.assert_key_secure()                 # does not raise
    assert crypto.decrypt(crypto.encrypt("ok")) == "ok"


def test_generated_db_passwords_are_unique_and_url_safe():
    a, b = crypto.random_token(), crypto.random_token()
    assert a != b
    # Safe to drop straight into a DATABASE_URL without escaping.
    assert all(c not in a for c in ':/@?#')
