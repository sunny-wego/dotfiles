"""Per-tenant database provisioning — Coolify-managed PostgreSQL.

Each app gets its own Coolify-managed PostgreSQL *resource* (a dedicated
container Coolify runs, monitors and backs up), rather than a database on a
shared cluster the kiosk administers. The kiosk asks Coolify to create it,
reads back the connection URL, configures a native scheduled backup, and injects
the URL into the tenant container. This keeps the deploy engine the single owner
of runtime infrastructure (README §3): Coolify owns lifecycle + backups, the
kiosk owns identity + wiring.

Trade-off vs the old shared-cluster db-per-tenant model: one container per app
(less dense) in exchange for real isolation, per-app resource limits enforced by
Coolify, and native backups/retention — no kiosk-side pg_dump, admin superuser,
or size-quota loop. Backups + DB size are observed in the Coolify dashboard.

Idempotent + re-runnable: the Coolify database UUID and connection URL are stored
(URL encrypted) in tenant_db and reused on re-deploy, so a re-provision never
recreates the database or drops tenant data.
"""

from __future__ import annotations

from . import crypto, db
from .backends.coolify.client import CoolifyClient, CoolifyError
from .config import config

_client: CoolifyClient | None = None


def _c() -> CoolifyClient:
    # Lazy singleton so importing this module never requires Coolify creds; a
    # not-configured client raises CoolifyError only when a call is made.
    global _client
    if _client is None:
        _client = CoolifyClient(
            config.COOLIFY_BASE_URL, config.COOLIFY_API_TOKEN,
            timeout=config.COOLIFY_TIMEOUT_S)
    return _client


def _ident(slug: str, prefix: str) -> str:
    return prefix + slug.replace("-", "_")


def ensure_tenant_db(slug: str, log) -> str:
    """Create (or reuse) the tenant's Coolify-managed Postgres; return the
    injected DATABASE_URL. Safe to re-run: an existing database is reused and its
    stored URL returned without touching data."""
    row = db.get_tenant_db(slug)
    if row and row.get("coolify_db_uuid"):
        uuid = row["coolify_db_uuid"]
        if row.get("dburl_enc"):
            log(f"[db] reusing Coolify database {uuid}")
            return crypto.decrypt(row["dburl_enc"])
        # Row exists but URL wasn't persisted (a prior run died mid-provision):
        # finish the job against the existing resource instead of orphaning it.
        log(f"[db] completing provision of existing Coolify database {uuid}")
        return _finish(slug, uuid, log)

    dbname = _ident(slug, "d_")
    dbuser = _ident(slug, "t_")
    password = crypto.random_token(24)
    log(f"[db] creating Coolify-managed PostgreSQL for {slug}")
    uuid = _c().create_postgres(
        project_uuid=config.COOLIFY_PROJECT_UUID,
        server_uuid=config.COOLIFY_SERVER_UUID,
        environment_name=config.COOLIFY_ENVIRONMENT,
        environment_uuid=config.COOLIFY_ENVIRONMENT_UUID,
        destination_uuid=config.COOLIFY_DESTINATION_UUID,
        name=f"tenant-{slug}-db", db_name=dbname, db_user=dbuser,
        db_password=password,
        limits_cpus=config.COOLIFY_CPU_LIMIT,
        limits_memory=config.COOLIFY_MEMORY_LIMIT)
    # Persist the UUID before reading the URL / configuring the backup, so a crash
    # in the next step is recoverable (reuse branch above) rather than orphaning.
    db.put_tenant_db(slug, dbname, dbuser, crypto.encrypt(password),
                     coolify_db_uuid=uuid)
    return _finish(slug, uuid, log)


def _finish(slug: str, uuid: str, log) -> str:
    """Read the connection URL back from Coolify and configure a native scheduled
    backup, then persist both. The DB is usable once the URL is known; the backup
    is best-effort so a backup-API hiccup doesn't fail the whole provision."""
    url = _c().database_url(uuid)
    backup_uuid = None
    try:
        if not _c().list_backups(uuid):
            backup_uuid = _c().create_backup(
                uuid, frequency=config.COOLIFY_BACKUP_FREQUENCY,
                save_s3=bool(config.COOLIFY_BACKUP_S3_STORAGE_UUID),
                s3_storage_uuid=config.COOLIFY_BACKUP_S3_STORAGE_UUID,
                retention_days_locally=config.COOLIFY_BACKUP_RETENTION_DAYS)
            log(f"[db] native daily backup configured ({config.COOLIFY_BACKUP_FREQUENCY})")
    except CoolifyError as e:
        log(f"[db] scheduled backup not configured (set it in Coolify): {e}")
    db.update_tenant_db(slug, dburl_enc=crypto.encrypt(url), backup_uuid=backup_uuid)
    return url


def database_url(slug: str) -> str | None:
    """The tenant DATABASE_URL from the stored (encrypted) Coolify URL. No I/O to
    Coolify — used on every deploy to rebuild the env bundle."""
    row = db.get_tenant_db(slug)
    if not row or not row.get("dburl_enc"):
        return None
    return crypto.decrypt(row["dburl_enc"])


def drop_tenant_db(slug: str, log) -> None:
    """Delete the tenant's Coolify database (container, volume and its scheduled
    backups) and forget it. Best-effort on the Coolify side."""
    row = db.get_tenant_db(slug)
    if not row:
        return
    uuid = row.get("coolify_db_uuid")
    if uuid:
        log(f"[db] deleting Coolify database {uuid}")
        try:
            _c().delete_database(uuid)
        except CoolifyError as e:
            log(f"[db] Coolify delete failed (prune it in the dashboard): {e}")
    db.delete_tenant_db(slug)
