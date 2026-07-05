"""Metadata Postgres access + schema bootstrap.

Two tables in M1:
  * apps  — the catalog (owner field included, per the lean-v1 hygiene note).
  * audit — APPEND-ONLY. A trigger blocks UPDATE/DELETE at the database, so the
            append-only guarantee is structural, not merely a convention.
"""

from __future__ import annotations

import json
import time
from contextlib import contextmanager

import psycopg  # noqa: F401  (kept for type/reference parity)
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from .config import config

_SCHEMA = """
CREATE TABLE IF NOT EXISTS apps (
    slug        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    owner       TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    url         TEXT,
    image       TEXT,
    port        INTEGER,
    detection   JSONB,
    visibility  TEXT NOT NULL DEFAULT 'invite-only',  -- invite-only | all-staff
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE apps ADD COLUMN IF NOT EXISTS visibility TEXT NOT NULL DEFAULT 'invite-only';

-- Per-tenant database credentials (password encrypted at rest).
CREATE TABLE IF NOT EXISTS tenant_db (
    slug          TEXT PRIMARY KEY,
    dbname        TEXT NOT NULL,
    dbuser        TEXT NOT NULL,
    dbpassword_enc TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Encrypted per-app secrets, injected as env at deploy.
CREATE TABLE IF NOT EXISTS app_secrets (
    slug       TEXT NOT NULL,
    key        TEXT NOT NULL,
    value_enc  TEXT NOT NULL,
    PRIMARY KEY (slug, key)
);

-- Whole-app allow-list principals (emails). Owner is always allowed.
CREATE TABLE IF NOT EXISTS app_access (
    slug       TEXT NOT NULL,
    principal  TEXT NOT NULL,
    PRIMARY KEY (slug, principal)
);

-- Per-app outbound domain allowlist (default-deny egress).
CREATE TABLE IF NOT EXISTS app_egress (
    slug    TEXT NOT NULL,
    domain  TEXT NOT NULL,
    PRIMARY KEY (slug, domain)
);

-- Per-app scheduled tasks (cron).
CREATE TABLE IF NOT EXISTS app_cron (
    slug      TEXT NOT NULL,
    name      TEXT NOT NULL,
    schedule  TEXT NOT NULL,     -- 5-field cron
    command   TEXT NOT NULL,     -- shell command run in the app image
    enabled   BOOLEAN NOT NULL DEFAULT true,
    last_run  TIMESTAMPTZ,
    last_ok   BOOLEAN,
    PRIMARY KEY (slug, name)
);

-- Coolify application identity per app (only used when the Coolify deploy
-- backend is active). Maps our slug to the Coolify application UUID so
-- re-deploys, env/cron sync, rollback and teardown target the same resource.
CREATE TABLE IF NOT EXISTS coolify_app (
    slug        TEXT PRIMARY KEY,
    app_uuid    TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit (
    id        BIGGENERATED_PLACEHOLDER,
    ts        TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor     TEXT NOT NULL,
    action    TEXT NOT NULL,
    app_slug  TEXT,
    detail    JSONB
);

CREATE OR REPLACE FUNCTION audit_is_append_only() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'audit table is append-only (% blocked)', TG_OP;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS audit_no_mutate ON audit;
CREATE TRIGGER audit_no_mutate
    BEFORE UPDATE OR DELETE ON audit
    FOR EACH ROW EXECUTE FUNCTION audit_is_append_only();
""".replace(
    "BIGGENERATED_PLACEHOLDER",
    "BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY",
)


# A connection POOL, not a single shared connection: the kiosk serves requests
# on a threadpool AND runs background threads (cron/monitor/backup), so one
# shared psycopg connection would serialize everything and race on reconnect.
# The pool hands each caller its own connection for the duration of a cursor().
_pool: ConnectionPool | None = None


def _make_pool(retries: int = 30) -> ConnectionPool:
    last: Exception | None = None
    for _ in range(retries):
        try:
            pool = ConnectionPool(
                config.DATABASE_URL, min_size=1, max_size=10, timeout=10,
                kwargs={"autocommit": True, "row_factory": dict_row}, open=True)
            with pool.connection() as conn:
                conn.execute("SELECT 1")
            return pool
        except Exception as e:  # noqa: BLE001,PERF203
            last = e
            time.sleep(1)
    raise RuntimeError(f"cannot reach postgres: {last}")


def init() -> None:
    global _pool
    if _pool is None:
        _pool = _make_pool()
    with _pool.connection() as conn, conn.cursor() as cur:
        cur.execute(_SCHEMA)


@contextmanager
def cursor():
    assert _pool is not None, "db.init() not called"
    with _pool.connection() as conn, conn.cursor() as cur:
        yield cur


# ── apps catalog ────────────────────────────────────────────────────────────
def upsert_app(slug: str, name: str, owner: str, detection: dict) -> None:
    with cursor() as cur:
        cur.execute(
            """
            INSERT INTO apps (slug, name, owner, detection, status)
            VALUES (%s, %s, %s, %s, 'pending')
            ON CONFLICT (slug) DO UPDATE
              SET name = EXCLUDED.name,
                  detection = EXCLUDED.detection,
                  updated_at = now()
            """,
            (slug, name, owner, json.dumps(detection)),
        )


def set_app_status(slug: str, status: str, *, url: str | None = None,
                   image: str | None = None, port: int | None = None) -> None:
    with cursor() as cur:
        cur.execute(
            """
            UPDATE apps SET status = %s,
                            url = COALESCE(%s, url),
                            image = COALESCE(%s, image),
                            port = COALESCE(%s, port),
                            updated_at = now()
            WHERE slug = %s
            """,
            (status, url, image, port, slug),
        )


def get_app(slug: str) -> dict | None:
    with cursor() as cur:
        cur.execute("SELECT * FROM apps WHERE slug = %s", (slug,))
        return cur.fetchone()


def list_apps() -> list[dict]:
    with cursor() as cur:
        cur.execute("SELECT * FROM apps ORDER BY created_at DESC")
        return cur.fetchall()


# ── audit (insert-only) ───────────────────────────────────────────────────────
def insert_audit(actor: str, action: str, app_slug: str | None,
                 detail: dict | None) -> None:
    with cursor() as cur:
        cur.execute(
            "INSERT INTO audit (actor, action, app_slug, detail) "
            "VALUES (%s, %s, %s, %s)",
            (actor, action, app_slug, json.dumps(detail or {})),
        )


def recent_audit(limit: int = 50) -> list[dict]:
    with cursor() as cur:
        cur.execute("SELECT * FROM audit ORDER BY ts DESC LIMIT %s", (limit,))
        return cur.fetchall()


def set_visibility(slug: str, visibility: str) -> None:
    with cursor() as cur:
        cur.execute("UPDATE apps SET visibility=%s, updated_at=now() WHERE slug=%s",
                    (visibility, slug))


# ── tenant DB creds ───────────────────────────────────────────────────────────
def get_tenant_db(slug: str) -> dict | None:
    with cursor() as cur:
        cur.execute("SELECT * FROM tenant_db WHERE slug=%s", (slug,))
        return cur.fetchone()


def put_tenant_db(slug: str, dbname: str, dbuser: str, dbpassword_enc: str) -> None:
    with cursor() as cur:
        cur.execute(
            "INSERT INTO tenant_db (slug, dbname, dbuser, dbpassword_enc) "
            "VALUES (%s,%s,%s,%s) ON CONFLICT (slug) DO NOTHING",
            (slug, dbname, dbuser, dbpassword_enc),
        )


def delete_tenant_db(slug: str) -> None:
    with cursor() as cur:
        cur.execute("DELETE FROM tenant_db WHERE slug=%s", (slug,))


# ── secrets ───────────────────────────────────────────────────────────────────
def set_secret(slug: str, key: str, value_enc: str) -> None:
    with cursor() as cur:
        cur.execute(
            "INSERT INTO app_secrets (slug, key, value_enc) VALUES (%s,%s,%s) "
            "ON CONFLICT (slug, key) DO UPDATE SET value_enc=EXCLUDED.value_enc",
            (slug, key, value_enc),
        )


def delete_secret(slug: str, key: str) -> None:
    with cursor() as cur:
        cur.execute("DELETE FROM app_secrets WHERE slug=%s AND key=%s", (slug, key))


def get_secrets(slug: str) -> list[dict]:
    with cursor() as cur:
        cur.execute("SELECT key, value_enc FROM app_secrets WHERE slug=%s ORDER BY key",
                    (slug,))
        return cur.fetchall()


# ── access allow-list ─────────────────────────────────────────────────────────
def add_access(slug: str, principal: str) -> None:
    with cursor() as cur:
        cur.execute(
            "INSERT INTO app_access (slug, principal) VALUES (%s, lower(%s)) "
            "ON CONFLICT DO NOTHING", (slug, principal))


def remove_access(slug: str, principal: str) -> None:
    with cursor() as cur:
        cur.execute("DELETE FROM app_access WHERE slug=%s AND principal=lower(%s)",
                    (slug, principal))


def list_access(slug: str) -> list[str]:
    with cursor() as cur:
        cur.execute("SELECT principal FROM app_access WHERE slug=%s ORDER BY principal",
                    (slug,))
        return [r["principal"] for r in cur.fetchall()]


# ── egress allowlist ──────────────────────────────────────────────────────────
def add_egress(slug: str, domain: str) -> None:
    with cursor() as cur:
        cur.execute("INSERT INTO app_egress (slug, domain) VALUES (%s, lower(%s)) "
                    "ON CONFLICT DO NOTHING", (slug, domain))


def list_egress(slug: str) -> list[str]:
    with cursor() as cur:
        cur.execute("SELECT domain FROM app_egress WHERE slug=%s ORDER BY domain", (slug,))
        return [r["domain"] for r in cur.fetchall()]


def all_egress_domains() -> list[str]:
    with cursor() as cur:
        cur.execute("SELECT DISTINCT domain FROM app_egress ORDER BY domain")
        return [r["domain"] for r in cur.fetchall()]


# ── cron ──────────────────────────────────────────────────────────────────────
def add_cron(slug: str, name: str, schedule: str, command: str) -> None:
    with cursor() as cur:
        cur.execute(
            "INSERT INTO app_cron (slug, name, schedule, command) VALUES (%s,%s,%s,%s) "
            "ON CONFLICT (slug, name) DO UPDATE SET schedule=EXCLUDED.schedule, "
            "command=EXCLUDED.command, enabled=true",
            (slug, name, schedule, command))


def list_cron(slug: str) -> list[dict]:
    with cursor() as cur:
        cur.execute("SELECT * FROM app_cron WHERE slug=%s ORDER BY name", (slug,))
        return cur.fetchall()


# ── Coolify application identity ──────────────────────────────────────────────
def get_coolify_uuid(slug: str) -> str | None:
    with cursor() as cur:
        cur.execute("SELECT app_uuid FROM coolify_app WHERE slug=%s", (slug,))
        row = cur.fetchone()
        return row["app_uuid"] if row else None


def put_coolify_uuid(slug: str, app_uuid: str) -> None:
    with cursor() as cur:
        cur.execute(
            "INSERT INTO coolify_app (slug, app_uuid) VALUES (%s, %s) "
            "ON CONFLICT (slug) DO UPDATE SET app_uuid=EXCLUDED.app_uuid",
            (slug, app_uuid))


def delete_coolify_uuid(slug: str) -> None:
    with cursor() as cur:
        cur.execute("DELETE FROM coolify_app WHERE slug=%s", (slug,))
