"""Per-app secrets — encrypted at rest, injected as env at deploy.

Thin domain layer over db + crypto. The generation prompt already forbids
baking secrets into the image or build args (README §9), so secrets only ever
arrive at runtime via the container env the deployer sets.
"""

from __future__ import annotations

from . import crypto, db


def set_secret(slug: str, key: str, value: str) -> None:
    db.set_secret(slug, key.strip(), crypto.encrypt(value))


def delete_secret(slug: str, key: str) -> None:
    db.delete_secret(slug, key)


def secret_keys(slug: str) -> list[str]:
    return [r["key"] for r in db.get_secrets(slug)]


def env_for(slug: str) -> dict[str, str]:
    """Decrypted {KEY: value} to inject into the tenant container."""
    out: dict[str, str] = {}
    for row in db.get_secrets(slug):
        try:
            out[row["key"]] = crypto.decrypt(row["value_enc"])
        except Exception as e:  # noqa: BLE001
            print(f"[secrets] decrypt failed for {slug}/{row['key']}: {e}", flush=True)
    return out
