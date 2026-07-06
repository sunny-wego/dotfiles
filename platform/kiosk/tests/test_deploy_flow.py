"""DB-backed tests for the async-deploy lifecycle fixes.

These need a real Postgres (unlike the no-infra suite): they exercise the
reconciler's stuck-deploy timeout, redeploy-while-deploying, and the
push-failure-is-fatal guard against actual `apps` rows. Point DATABASE_URL at a
throwaway Postgres before importing the app; docker one-liner:

  docker run -d --name kiosk-test-pg -e POSTGRES_USER=kiosk \
    -e POSTGRES_PASSWORD=kiosk -e POSTGRES_DB=kiosk -p 55432:5432 postgres:16-alpine
"""
import os

os.environ.setdefault("DATABASE_URL", "postgresql://kiosk:kiosk@localhost:55432/kiosk")

import pytest  # noqa: E402
import psycopg  # noqa: E402

# These tests need a real Postgres. Skip cleanly (rather than hang on db.init's
# retry loop) when one isn't reachable, so the no-infra suite still runs anywhere.
try:
    psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=2).close()
except Exception as exc:  # noqa: BLE001
    pytest.skip(f"Postgres not reachable ({exc}); skipping db-backed deploy tests",
                allow_module_level=True)

from app import db  # noqa: E402


@pytest.fixture(scope="module", autouse=True)
def _schema():
    db.init()
    yield


@pytest.fixture(autouse=True)
def _clean():
    with db.cursor() as cur:
        cur.execute("DELETE FROM apps")
        cur.execute("DELETE FROM coolify_app")
        cur.execute("DELETE FROM app_cron")
        cur.execute("DELETE FROM tenant_db")
    yield


def _seed(slug, status="deploying", image="registry:5000/tenant-x:1700", port=8000):
    db.upsert_app(slug, slug.title(), "me@wego.com", {})
    db.set_app_status(slug, status, image=image, port=port)


# ── #6: reconciler advances / times out "deploying" apps ─────────────────────
def test_reconcile_advances_to_running(monkeypatch):
    from app import monitor
    _seed("live")
    monkeypatch.setattr("app.deployer.deploy_status", lambda slug: "running")
    monitor._reconcile_deploys()
    assert db.get_app("live")["status"] == "running"


def test_reconcile_leaves_fresh_deploying_alone(monkeypatch):
    from app import monitor
    _seed("fresh")
    monkeypatch.setattr("app.deployer.deploy_status", lambda slug: "deploying")
    monitor._reconcile_deploys()
    assert db.get_app("fresh")["status"] == "deploying"


def test_reconcile_fails_a_stuck_deploying_app(monkeypatch):
    from app import monitor
    _seed("stuck")
    # Age the row past the timeout so it counts as stuck.
    with db.cursor() as cur:
        cur.execute("UPDATE apps SET updated_at = now() - interval '2 hours' "
                    "WHERE slug='stuck'")
    monkeypatch.setattr("app.deployer.deploy_status", lambda slug: "deploying")
    escalated = []
    monkeypatch.setattr("app.slack.escalate", lambda *a, **k: escalated.append(a))
    monitor._reconcile_deploys()
    assert db.get_app("stuck")["status"] == "failed"
    assert escalated, "a stuck deploy should escalate"


# ── #7: redeploy proceeds while an app is still "deploying" ──────────────────
class _FakeClient:
    def __init__(self, existing_tasks=None):
        self.calls = []
        self.existing_tasks = existing_tasks or []
        self.deleted_tasks = []
        self.created_tasks = []

    def _rec(self, name):
        self.calls.append(name)

    def create_image_app(self, **k):
        self._rec("create"); return "uuid-new"

    def replace_envs(self, *a, **k):
        self._rec("replace_envs")

    def update_app(self, *a, **k):
        self._rec("update_app")

    def deploy(self, *a, **k):
        self._rec("deploy")

    def list_scheduled_tasks(self, uuid):
        return self.existing_tasks

    def create_scheduled_task(self, uuid, *, name, command, frequency):
        self.created_tasks.append(name)

    def update_scheduled_task(self, uuid, task_uuid, *, name, command, frequency):
        self._rec("update_task")

    def delete_scheduled_task(self, uuid, task_uuid):
        self.deleted_tasks.append(task_uuid)


def _backend_with_fake_client():
    from app.backends.coolify.backend import CoolifyBackend
    b = CoolifyBackend.__new__(CoolifyBackend)  # skip __init__ (no real client)
    b._client = _FakeClient()
    return b


def test_redeploy_proceeds_when_deploying(monkeypatch):
    monkeypatch.setattr("app.tenant_env.build_env", lambda slug, log=lambda *_: None: {})
    _seed("mid", status="deploying")
    db.put_coolify_uuid("mid", "uuid-1")
    b = _backend_with_fake_client()
    ok, _, msg = b.redeploy("mid")
    assert ok is True, msg
    assert "deploy" in b._client.calls
    # Reused the existing app (no create), applied env + settings.
    assert "create" not in b._client.calls
    assert "replace_envs" in b._client.calls


def test_redeploy_noop_before_first_build():
    db.upsert_app("nobuild", "NoBuild", "me@wego.com", {})  # no image/port
    b = _backend_with_fake_client()
    ok, _, msg = b.redeploy("nobuild")
    assert ok is False
    assert "nothing to redeploy" in msg
    assert b._client.calls == []


# ── #5: a failed registry push fails the provision (Coolify pulls the image) ──
class _Detect:
    notes = ""
    runtime = "python"

    def summary(self):
        return "python app"


class _Outcome:
    ok = True
    attempts = 1
    reason = ""
    pushed = False
    push_error = "registry unreachable"
    image = "registry:5000/tenant-pushfail:1700"
    port = 8000


def test_push_failure_fails_provision_and_skips_deploy(monkeypatch, tmp_path):
    from app import orchestrator

    monkeypatch.setattr("app.orchestrator.safe_extract", lambda *a, **k: None)
    monkeypatch.setattr("app.orchestrator.find_project_root", lambda d: d)
    monkeypatch.setattr("app.orchestrator.detect", lambda root: _Detect())
    monkeypatch.setattr("app.orchestrator.collect_manifests", lambda root, red: {})
    monkeypatch.setattr("app.orchestrator.tree", lambda root: "")
    monkeypatch.setattr("app.orchestrator.redact", lambda s: s)
    monkeypatch.setattr("app.orchestrator.provision_db.ensure_tenant_db",
                        lambda slug, log: None)
    monkeypatch.setattr("app.orchestrator.egress.regenerate_allowlist",
                        lambda log=lambda *_: None: None)
    monkeypatch.setattr("app.orchestrator.tenant_env.build_env",
                        lambda slug, log=lambda *_: None: {})

    class _LLM:
        mode = "stub"; budget = 0; tokens_used = 0
    monkeypatch.setattr("app.orchestrator.LLMSession", _LLM)

    class _Builder:
        def __init__(self, *a, **k): pass
        def run(self, **k): return _Outcome()
    monkeypatch.setattr("app.orchestrator.Builder", _Builder)

    deployed = []
    monkeypatch.setattr("app.orchestrator.deployer.deploy",
                        lambda *a, **k: (deployed.append(1), ("t", "u", "m"))[1])
    monkeypatch.setattr("app.orchestrator.slack.escalate", lambda *a, **k: None)

    job = orchestrator.Job(slug="pushfail", name="PushFail", actor="me@wego.com")
    orchestrator._run(job, str(tmp_path), str(tmp_path / "upload.zip"))

    assert job.status == "failed"
    assert db.get_app("pushfail")["status"] == "failed"
    assert deployed == [], "deploy must not be triggered when the push failed"


# ── cron removal propagates (db + Coolify reconcile) ─────────────────────────
def test_delete_cron_removes_row():
    _seed("cronapp")
    db.add_cron("cronapp", "nightly", "0 9 * * *", "python x.py")
    assert any(c["name"] == "nightly" for c in db.list_cron("cronapp"))
    db.delete_cron("cronapp", "nightly")
    assert db.list_cron("cronapp") == []


# ── per-tenant DB is a Coolify-managed resource (create once, reuse, backup) ──
class _FakeDBClient:
    def __init__(self, existing_dbs=None):
        self.created = []
        self.backups = []
        self.deleted = []
        self.existing_dbs = existing_dbs or []

    def list_databases(self):
        return self.existing_dbs

    def create_postgres(self, **k):
        self.created.append(k)
        return "db-uuid"

    def database_url(self, uuid):
        return f"postgresql://t:pw@{uuid}-host:5432/d"

    def list_backups(self, uuid):
        return list(self.backups)

    def create_backup(self, uuid, **k):
        self.backups.append(k)
        return "bk-uuid"

    def delete_database(self, uuid):
        self.deleted.append(uuid)


def test_ensure_tenant_db_creates_reuses_and_backs_up(monkeypatch):
    from app import provision_db
    fake = _FakeDBClient()
    monkeypatch.setattr(provision_db, "_c", lambda: fake)

    url1 = provision_db.ensure_tenant_db("dbapp", lambda *_: None)
    assert url1 == "postgresql://t:pw@db-uuid-host:5432/d"
    assert len(fake.created) == 1          # created the Coolify resource
    assert len(fake.backups) == 1          # configured a native scheduled backup
    row = db.get_tenant_db("dbapp")
    assert row["coolify_db_uuid"] == "db-uuid"
    assert row["dburl_enc"] and row["dburl_enc"] != url1  # stored encrypted

    # Re-provision is idempotent: reuse the resource, no second create/backup.
    url2 = provision_db.ensure_tenant_db("dbapp", lambda *_: None)
    assert url2 == url1
    assert len(fake.created) == 1
    assert len(fake.backups) == 1
    # database_url() reconstructs from stored creds without touching Coolify.
    assert provision_db.database_url("dbapp") == url1


def test_ensure_tenant_db_adopts_orphaned_coolify_db(monkeypatch):
    """A prior run created the Coolify DB but died before persisting the row:
    the next provision must ADOPT the existing resource, not create a duplicate."""
    from app import provision_db
    fake = _FakeDBClient(existing_dbs=[{"name": "tenant-orphan-db", "uuid": "db-old"}])
    monkeypatch.setattr(provision_db, "_c", lambda: fake)

    url = provision_db.ensure_tenant_db("orphan", lambda *_: None)
    assert fake.created == []                       # adopted, not recreated
    assert db.get_tenant_db("orphan")["coolify_db_uuid"] == "db-old"
    assert url == "postgresql://t:pw@db-old-host:5432/d"


def test_ensure_tenant_db_recovers_from_partial_provision(monkeypatch):
    """UUID persisted but URL never stored (a prior run died mid-provision):
    finish against the existing resource, don't create a duplicate."""
    from app import provision_db
    fake = _FakeDBClient()
    monkeypatch.setattr(provision_db, "_c", lambda: fake)
    db.put_tenant_db("halfdb", "d_h", "t_h", "enc", coolify_db_uuid="db-uuid")

    url = provision_db.ensure_tenant_db("halfdb", lambda *_: None)
    assert url == "postgresql://t:pw@db-uuid-host:5432/d"
    assert fake.created == []              # existing resource reused, not recreated
    assert db.get_tenant_db("halfdb")["dburl_enc"]


def test_sync_cron_creates_missing_and_deletes_removed():
    from app.backends.coolify.backend import CoolifyBackend
    _seed("recon")
    db.put_coolify_uuid("recon", "uuid-1")
    db.add_cron("recon", "keep", "0 1 * * *", "cmd-keep")
    b = CoolifyBackend.__new__(CoolifyBackend)
    # Coolify has a stale "old" task (its kiosk row is gone) but not "keep".
    b._client = _FakeClient(existing_tasks=[{"name": "old", "uuid": "t-old"}])
    b.sync_cron("recon")
    assert "keep" in b._client.created_tasks    # kiosk row with no task → created
    assert "t-old" in b._client.deleted_tasks   # task with no kiosk row → deleted
