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

import psycopg
from psycopg.rows import dict_row

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
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
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


def _connect(retries: int = 30) -> psycopg.Connection:
    last: Exception | None = None
    for _ in range(retries):
        try:
            return psycopg.connect(config.DATABASE_URL, autocommit=True,
                                   row_factory=dict_row)
        except psycopg.OperationalError as e:  # noqa: PERF203
            last = e
            time.sleep(1)
    raise RuntimeError(f"cannot reach postgres: {last}")


_conn: psycopg.Connection | None = None


def init() -> None:
    global _conn
    _conn = _connect()
    with _conn.cursor() as cur:
        cur.execute(_SCHEMA)


@contextmanager
def cursor():
    assert _conn is not None, "db.init() not called"
    if _conn.closed:
        init()
    with _conn.cursor() as cur:
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
