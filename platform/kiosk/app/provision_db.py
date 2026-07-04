"""Per-tenant database provisioning on the shared Postgres cluster.

db-per-tenant (README default): one database + one login role per app on the
one shared cluster — cheap, mainstream-ORM-compatible, one backup story. The
kiosk connects as the cluster superuser to create them, then injects a scoped
DATABASE_URL into the tenant container.

Shared-cluster guards (the README's "one runaway query must not affect
neighbours"): per-role CONNECTION LIMIT, a statement_timeout, and a size quota
enforced by the monitor loop (Postgres has no native per-db quota).

Idempotent + re-runnable: creds are stored (encrypted) in tenant_db and reused
on re-deploy, so a re-provision never drops tenant data.
"""

from __future__ import annotations

import psycopg
from psycopg import sql

from . import crypto, db
from .config import config


def _ident(slug: str, prefix: str) -> str:
    return prefix + slug.replace("-", "_")


def _admin():
    # autocommit: CREATE DATABASE can't run in a transaction block.
    return psycopg.connect(config.PG_ADMIN_URL, autocommit=True)


def ensure_tenant_db(slug: str, log) -> str:
    """Create (or reuse) the tenant DB + role; return the injected DATABASE_URL."""
    existing = db.get_tenant_db(slug)
    if existing:
        password = crypto.decrypt(existing["dbpassword_enc"])
        dbname, dbuser = existing["dbname"], existing["dbuser"]
        log(f"[db] reusing existing database {dbname}")
    else:
        dbname = _ident(slug, "d_")
        dbuser = _ident(slug, "t_")
        password = crypto.random_token(18)
        _create(dbname, dbuser, password, log)
        db.put_tenant_db(slug, dbname, dbuser, crypto.encrypt(password))

    return (f"postgresql://{dbuser}:{password}@"
            f"{config.PG_TENANT_HOST}:{config.PG_TENANT_PORT}/{dbname}")


def database_url(slug: str) -> str | None:
    """Reconstruct the tenant DATABASE_URL from stored creds (no creation)."""
    row = db.get_tenant_db(slug)
    if not row:
        return None
    password = crypto.decrypt(row["dbpassword_enc"])
    return (f"postgresql://{row['dbuser']}:{password}@"
            f"{config.PG_TENANT_HOST}:{config.PG_TENANT_PORT}/{row['dbname']}")


def _create(dbname: str, dbuser: str, password: str, log) -> None:
    log(f"[db] creating role {dbuser} + database {dbname}")
    with _admin() as conn, conn.cursor() as cur:
        # Role (idempotent). If it already exists (e.g. a prior run created the
        # role but died before persisting the tenant_db row), re-sync the
        # password to the value we are about to store/inject — otherwise the
        # stored password and the actual role password diverge and the tenant
        # can never authenticate.
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (dbuser,))
        if cur.fetchone():
            cur.execute(
                sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {} CONNECTION LIMIT {}").format(
                    sql.Identifier(dbuser),
                    sql.Literal(password),
                    sql.Literal(config.TENANT_DB_CONN_LIMIT),
                ))
        else:
            cur.execute(
                sql.SQL("CREATE ROLE {} LOGIN PASSWORD {} CONNECTION LIMIT {}").format(
                    sql.Identifier(dbuser),
                    sql.Literal(password),
                    sql.Literal(config.TENANT_DB_CONN_LIMIT),
                ))
        cur.execute(
            sql.SQL("ALTER ROLE {} SET statement_timeout = {}").format(
                sql.Identifier(dbuser),
                sql.Literal(config.TENANT_DB_STATEMENT_TIMEOUT),
            ))
        # Database (idempotent).
        cur.execute("SELECT 1 FROM pg_database WHERE datname=%s", (dbname,))
        if not cur.fetchone():
            cur.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(
                sql.Identifier(dbname), sql.Identifier(dbuser)))
            cur.execute(sql.SQL("ALTER DATABASE {} CONNECTION LIMIT {}").format(
                sql.Identifier(dbname), sql.Literal(config.TENANT_DB_CONN_LIMIT)))
    # Lock down: revoke public, ensure the tenant owns its schema.
    with psycopg.connect(_admin_db_url(dbname), autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("REVOKE ALL ON DATABASE " + _q(dbname) + " FROM PUBLIC")
        cur.execute(sql.SQL("GRANT ALL ON SCHEMA public TO {}").format(
            sql.Identifier(dbuser)))


def _admin_db_url(dbname: str) -> str:
    # Same admin creds, targeting the tenant DB (for schema grants).
    base = config.PG_ADMIN_URL.rsplit("/", 1)[0]
    return f"{base}/{dbname}"


def _q(ident: str) -> str:
    return '"' + ident.replace('"', '""') + '"'


def db_size_mb(slug: str) -> float | None:
    row = db.get_tenant_db(slug)
    if not row:
        return None
    with _admin() as conn, conn.cursor() as cur:
        cur.execute("SELECT pg_database_size(%s)", (row["dbname"],))
        got = cur.fetchone()
        return round(got[0] / 1024 / 1024, 1) if got else None


def drop_tenant_db(slug: str, log) -> None:
    row = db.get_tenant_db(slug)
    if not row:
        return
    dbname, dbuser = row["dbname"], row["dbuser"]
    log(f"[db] dropping database {dbname} + role {dbuser}")
    with _admin() as conn, conn.cursor() as cur:
        cur.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                    "WHERE datname=%s", (dbname,))
        cur.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(sql.Identifier(dbname)))
        cur.execute(sql.SQL("DROP ROLE IF EXISTS {}").format(sql.Identifier(dbuser)))
    db.delete_tenant_db(slug)
