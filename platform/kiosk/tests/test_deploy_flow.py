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
os.environ.setdefault("PG_ADMIN_URL", os.environ["DATABASE_URL"])

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
    def __init__(self):
        self.calls = []

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
        return []


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
