"""The provisioning saga — idempotent, re-runnable, single entry point.

M1 saga (lean-v1 add-ons like per-tenant DB / cron / LLM key hang off the same
seam later):

    create → safe-unzip → detect → redact → build-verify-heal → deploy → record

Each app's progress is tracked in an in-memory job (live log for the UI) and the
durable status/catalog rows in Postgres. Re-running the same slug is safe: the
deployer replaces the container and the audit trail simply appends.
"""

from __future__ import annotations

import re
import shutil
import threading
from dataclasses import dataclass, field

from . import audit, db, deployer, egress, provision_db, slack, tenant_env
from .builder import Builder
from .config import config
from .detect import collect_manifests, detect, tree
from .llm import LLMSession
from .redact import redact
from .zipsafe import find_project_root, safe_extract


@dataclass
class Job:
    slug: str
    name: str
    actor: str
    status: str = "pending"          # pending|building|deploying|running|failed
    url: str = ""
    lines: list[str] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def log(self, msg: str) -> None:
        with self.lock:
            self.lines.append(msg)
        print(f"[{self.slug}] {msg}", flush=True)


_jobs: dict[str, Job] = {}
_jobs_lock = threading.Lock()


def get_job(slug: str) -> Job | None:
    with _jobs_lock:
        return _jobs.get(slug)


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")
    return (s or "app")[:40]


def start(name: str, actor: str, work_root: str, zip_path: str) -> Job:
    slug = slugify(name)
    job = Job(slug=slug, name=name, actor=actor)
    with _jobs_lock:
        _jobs[slug] = job
    t = threading.Thread(target=_run, args=(job, work_root, zip_path), daemon=True)
    t.start()
    return job


def _run(job: Job, work_root: str, zip_path: str) -> None:
    slug = job.slug
    try:
        audit.record(job.actor, "app.create", app=slug, detail={"name": job.name})

        # 1. Safe extract.
        job.log("unzipping (safe extraction) …")
        extract_dir = f"{work_root}/src"
        safe_extract(zip_path, extract_dir, config.MAX_UNZIP_MB * 1024 * 1024)
        root = find_project_root(extract_dir)

        # 2. Detect.
        d = detect(root)
        job.log(f"detected: {d.summary()}")
        db.upsert_app(slug, job.name, job.actor, d.__dict__ | {"notes": d.notes})
        audit.record(job.actor, "detect", app=slug, detail={"summary": d.summary()})

        # 3. Redact everything the LLM will see.
        job.log("redacting secrets before any LLM call …")
        manifests = collect_manifests(root, redact)
        dir_tree = redact(tree(root))

        # 4. Provision per-tenant resources FIRST, so the verify boot (step 5)
        #    can inject the real DATABASE_URL/secrets — apps that read their env
        #    at import must survive the probe. Idempotent + reused on retry.
        job.status = "building"
        db.set_app_status(slug, "building")
        job.log("provisioning per-tenant database …")
        provision_db.ensure_tenant_db(slug, job.log)
        audit.record(job.actor, "provision.db", app=slug)
        egress.regenerate_allowlist(job.log)
        env = tenant_env.build_env(slug, job.log)

        # 5. Build-verify-heal (verify boots with the tenant env from step 4).
        llm = LLMSession()
        job.log(f"LLM mode = {llm.mode}; token budget = {llm.budget}")
        builder = Builder(slug, root, d, llm, job.log)
        outcome = builder.run(manifests=manifests, tree=dir_tree, verify_env=env)

        audit.record(job.actor, "build", app=slug, detail={
            "ok": outcome.ok, "attempts": outcome.attempts,
            "reason": outcome.reason, "tokens": llm.tokens_used,
            "pushed": outcome.pushed,
        })
        if outcome.ok and outcome.push_error:
            slack.escalate(
                job.actor, slug,
                "Registry push FAILED (not a benign 'registry down' error). App "
                "deploys from the local image but won't be pullable on a "
                "recreate/remote deploy.",
                {"detail": outcome.push_error})

        if not outcome.ok:
            job.status = "failed"
            db.set_app_status(slug, "failed")
            job.log(f"BUILD FAILED: {outcome.reason}")
            slack.escalate(
                job.actor, slug,
                f"Build could not be healed: {outcome.reason}",
                {"attempts": outcome.attempts},
            )
            return

        job.log(f"build ok after {outcome.attempts} attempt(s)")

        # 6. Deploy on the internal tenant network, behind auth + allow-list.
        job.status = "deploying"
        db.set_app_status(slug, "deploying", image=outcome.image, port=outcome.port)
        ok, url, msg = deployer.deploy(slug, outcome.image, outcome.port, env=env)
        if not ok:
            job.status = "failed"
            db.set_app_status(slug, "failed")
            job.log(f"DEPLOY FAILED: {msg}")
            slack.escalate(job.actor, slug, f"Deploy failed: {msg}")
            return

        # 7. Record the deploy. Coolify deploys asynchronously, so the app is
        #    "deploying" (accepted, not yet live); the monitor reconciler polls
        #    Coolify's real state and advances it to running/failed. Claiming
        #    "running" here would show a false green if the async deploy fails.
        job.status = "deploying"
        job.url = url
        db.set_app_status(slug, "deploying", url=url)
        audit.record(job.actor, "deploy", app=slug, detail={"url": url, "image": outcome.image})
        job.log(f"deploy accepted — {url} ({msg}); finishing on Coolify")

        # Reclaim disk: drop older builds of this slug, keeping the live image.
        try:
            deployer.prune_old_images(slug, keep=outcome.image)
        except Exception:  # noqa: BLE001 — housekeeping must never fail a deploy
            pass

    except Exception as e:  # noqa: BLE001 — saga must fail closed, not crash the worker
        job.status = "failed"
        try:
            db.set_app_status(slug, "failed")
        except Exception:  # noqa: BLE001
            pass
        job.log(f"ERROR: {e}")
        slack.escalate(job.actor, slug, f"Unhandled provisioning error: {e}")
    finally:
        # The built image is the artifact; the extracted source + raw upload are
        # only build input. Remove them so /work (and any unredacted secrets in
        # the raw ZIP) don't accumulate on the box.
        shutil.rmtree(work_root, ignore_errors=True)
