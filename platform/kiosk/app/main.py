"""Kiosk web plane — the creator's only surface.

FastAPI app: ZIP-drop UI, the provisioning endpoint, per-app status/logs, and a
small catalog. Every request is identified + company-domain-checked via
`auth.identity`; the kiosk sits behind forward-auth in Traefik.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import time
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from . import (access, audit, backup, crypto, db, deployer, egress,
               monitor, orchestrator, secrets_store)
from .auth import identity
from .config import config

app = FastAPI(title="Internal App Platform — Kiosk (v1)")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


@app.on_event("startup")
def _startup() -> None:
    # Fail fast on an insecure key in prod (crypto is the enforcing chokepoint);
    # warn once in dev where the default is tolerated.
    crypto.assert_key_secure()
    if config.SECRET_KEY in ("", config.INSECURE_SECRET_KEY):
        print("[WARN] KIOSK_SECRET_KEY is the insecure dev default — "
              "secrets at rest are NOT protected. Set a real key for real use.",
              flush=True)
    db.init()
    egress.regenerate_allowlist()
    # Cron runs as Coolify Scheduled Tasks (no in-process scheduler); the kiosk
    # keeps the nightly per-tenant pg_dump (README §3).
    backup.start_nightly()
    monitor.start()
    print("[startup] deploy engine = coolify", flush=True)


@app.get("/healthz")
def healthz() -> JSONResponse:
    return JSONResponse({"ok": True, "auth_mode": config.AUTH_MODE})


@app.get("/internal/authz")
def internal_authz(request: Request) -> Response:
    """Second forward-auth hop for tenant apps: whole-app allow-list.

    Called directly by Traefik (bypasses the kiosk's own router auth). Stage-1
    (oauth2-proxy) has already set the identity header; here we enforce that the
    identity may open THIS specific app. Fail-closed: any gap -> 403.

    SECURITY: the app slug MUST come from X-App-Slug, which each tenant router
    sets server-side (Set-overwrites, so a client value can't win) and
    strip-auth-in clears on ingress. We deliberately do NOT derive it from
    X-Forwarded-Host — that is client-influenceable, and trusting it would let a
    caller be authorized against app A while Traefik routes them to app B
    (auth-bypass / IDOR).
    """
    email = request.headers.get("x-auth-request-email", "")
    slug = request.headers.get("x-app-slug", "").strip()
    if slug and access.can_open(slug, email):
        return Response(status_code=200)
    return Response(status_code=403, content=f"not authorized for {slug or '?'}")


@app.post("/ops/backup")
def ops_backup(request: Request):
    identity(request)  # any company user may trigger an on-demand backup
    return JSONResponse(backup.backup_all(print))


@app.get("/ops/restore-drill")
def ops_restore_drill(request: Request):
    identity(request)
    return JSONResponse(backup.restore_drill(log=print))


def _owner_guard(slug: str, who: str) -> dict:
    record = db.get_app(slug)
    if record is None:
        raise HTTPException(404, "no such app")
    if (record.get("owner") or "").lower() != who.lower():
        raise HTTPException(403, "only the app owner can manage this app")
    return record


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    who = identity(request)
    return templates.TemplateResponse("index.html", {
        "request": request,
        "who": who,
        "apps": db.list_apps(),
        "audit": db.recent_audit(20),
        "domain": config.PLATFORM_DOMAIN,
    })


@app.post("/apps")
async def create_app(request: Request, name: str = Form(...),
                     zipfile: UploadFile = File(...)):
    who = identity(request)
    if not name.strip():
        raise HTTPException(400, "app name is required")
    if not (zipfile.filename or "").lower().endswith(".zip"):
        raise HTTPException(400, "please upload a .zip")

    slug = orchestrator.slugify(name)
    # Re-uploading an existing app replaces its code in place; only the owner may
    # do that. (First upload of a new slug is open to any company user.)
    existing = db.get_app(slug)
    if existing and (existing.get("owner") or "").lower() != who.lower():
        raise HTTPException(
            403, f"'{slug}' is owned by {existing.get('owner')}; only the owner can redeploy it")
    work_root = os.path.join(config.WORK_DIR, f"{slug}-{int(time.time())}")
    os.makedirs(work_root, exist_ok=True)
    zip_path = os.path.join(work_root, "upload.zip")
    with open(zip_path, "wb") as out:
        shutil.copyfileobj(zipfile.file, out)

    orchestrator.start(name.strip(), who, work_root, zip_path)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.get("/apps/{slug}", response_class=HTMLResponse)
def app_page(request: Request, slug: str):
    who = identity(request)
    record = db.get_app(slug)
    job = orchestrator.get_job(slug)
    if record is None and job is None:
        raise HTTPException(404, "no such app")
    is_owner = record is not None and (record.get("owner") or "").lower() == who.lower()
    return templates.TemplateResponse("app.html", {
        "request": request,
        "who": who,
        "slug": slug,
        "record": record,
        "job_status": job.status if job else (record or {}).get("status"),
        "is_owner": is_owner,
        "config_domain": config.COMPANY_EMAIL_DOMAIN,
        "access": db.list_access(slug) if record else [],
        "secret_keys": secrets_store.secret_keys(slug) if record else [],
        "egress": db.list_egress(slug) if record else [],
        "crons": db.list_cron(slug) if record else [],
    })


# ── management (owner-only) ───────────────────────────────────────────────────
@app.post("/apps/{slug}/visibility")
def set_visibility(request: Request, slug: str, visibility: str = Form(...)):
    who = identity(request)
    _owner_guard(slug, who)
    if visibility not in ("invite-only", "all-staff"):
        raise HTTPException(400, "bad visibility")
    access.set_visibility(slug, visibility)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/access")
def add_access(request: Request, slug: str, email: str = Form(...),
               remove: str = Form("")):
    who = identity(request)
    _owner_guard(slug, who)
    if remove:
        access.remove_access(slug, email)
    else:
        access.add_access(slug, email)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/secrets")
def set_secret(request: Request, slug: str, key: str = Form(...),
               value: str = Form(""), remove: str = Form("")):
    who = identity(request)
    _owner_guard(slug, who)
    if remove:
        secrets_store.delete_secret(slug, key)
    else:
        if not value:
            raise HTTPException(400, "value required")
        secrets_store.set_secret(slug, key, value)
    # Secrets are injected as env at container start, so apply on the live app
    # (off the request path — a recreate takes seconds).
    deployer.redeploy_async(slug)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/egress")
def add_egress(request: Request, slug: str, domain: str = Form(...)):
    who = identity(request)
    _owner_guard(slug, who)
    db.add_egress(slug, domain.strip())
    egress.regenerate_allowlist()
    # Egress proxy env is injected at start; redeploy (off the request path) so
    # the running app can reach the new domain, not just squid permitting it.
    deployer.redeploy_async(slug)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/cron")
def add_cron(request: Request, slug: str, name: str = Form(...),
             schedule: str = Form(...), command: str = Form(...)):
    who = identity(request)
    _owner_guard(slug, who)
    db.add_cron(slug, name.strip(), schedule.strip(), command.strip())
    # Reconcile Coolify Scheduled Tasks off the request path (the round-trips
    # shouldn't block the redirect); no-op until the app has been deployed, when
    # deploy() re-syncs.
    deployer.sync_cron_async(slug)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/rollback")
def rollback_app(request: Request, slug: str):
    who = identity(request)
    _owner_guard(slug, who)
    ok, url, msg = deployer.rollback(slug)
    audit.record(who, "rollback", app=slug, detail={"ok": ok, "msg": msg})
    return JSONResponse({"ok": ok, "url": url, "message": msg})


@app.get("/apps/{slug}/status")
def app_status(request: Request, slug: str):
    identity(request)
    job = orchestrator.get_job(slug)
    record = db.get_app(slug)
    if job is None and record is None:
        raise HTTPException(404, "no such app")
    # The DB row is the source of truth once it exists — the saga writes it at
    # every phase AND the monitor reconciler advances "deploying"→running/failed
    # there. Fall back to the in-memory job only for the pre-detect phase before
    # a row exists. (Reading job.status would pin the UI at "deploying".)
    status = (record or {}).get("status") or (job.status if job else None)
    url = (record or {}).get("url") or (job.url if job else None)
    return JSONResponse({
        "slug": slug,
        "status": status,
        "url": url,
        "lines": (job.lines if job else []),
    })


@app.get("/apps/{slug}/logs", response_class=HTMLResponse)
async def app_logs(request: Request, slug: str):
    identity(request)
    if db.get_app(slug) is None:
        raise HTTPException(404, "no such app")
    # Offload the blocking Coolify logs GET to the bounded off-path pool so a
    # slow/hung Coolify can't tie up FastAPI's shared sync-route worker pool.
    loop = asyncio.get_running_loop()
    logs = await loop.run_in_executor(deployer.pool(), deployer.app_logs, slug, 300)
    return templates.TemplateResponse("logs.html", {
        "request": request, "slug": slug, "logs": logs,
    })
