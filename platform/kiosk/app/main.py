"""Kiosk web plane — the creator's only surface.

FastAPI app: ZIP-drop UI, the provisioning endpoint, per-app status/logs, and a
small catalog. Every request is identified + company-domain-checked via
`auth.identity`; the kiosk sits behind forward-auth in Traefik.
"""

from __future__ import annotations

import asyncio
import os
import secrets
import shutil
import time
from pathlib import Path

# Unambiguous alphabet for the human-entered device code (no 0/O/1/I).
_USER_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

from fastapi import FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from . import (access, audit, crypto, db, deployer, egress,
               monitor, orchestrator, secrets_store)
from .auth import identity
from .config import config

app = FastAPI(title="Internal App Platform — Kiosk (v1)")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

_CSRF_COOKIE = "kiosk_csrf"


@app.middleware("http")
async def _csrf_cookie(request: Request, call_next):
    """Issue a double-submit CSRF cookie to browsers. Readable by same-origin JS
    (SOP still stops a cross-site attacker reading it) so both server-rendered
    forms and fetch() calls can echo it back. `request.state.csrf` is the value
    templates embed in hidden fields."""
    token = request.cookies.get(_CSRF_COOKIE) or secrets.token_urlsafe(24)
    request.state.csrf = token
    response = await call_next(request)
    if _CSRF_COOKIE not in request.cookies:
        https = (request.headers.get("x-forwarded-proto", "").lower() == "https"
                 or request.url.scheme == "https")
        response.set_cookie(_CSRF_COOKIE, token, samesite="strict",
                            secure=https, path="/")
    return response


def _same_origin_ok(request: Request) -> bool:
    """Defense-in-depth: if an Origin/Referer is present it must be this host."""
    origin = request.headers.get("origin") or request.headers.get("referer") or ""
    if not origin:
        return True
    from urllib.parse import urlparse
    return urlparse(origin).netloc == request.headers.get("host", "")


def _enforce_csrf(request: Request, submitted: str = "") -> None:
    """CSRF guard for state-changing browser requests. Bearer-token (CLI) callers
    are exempt: a Bearer header is never sent ambiently by a browser, so those
    requests can't be forged cross-site — and the CLI has no cookie to submit.
    Browser (cookie) requests must double-submit the token (hidden form field or
    X-CSRF-Token header must equal the kiosk_csrf cookie) and be same-origin."""
    if request.headers.get("authorization", "")[:7].lower() == "bearer ":
        return
    token = submitted or request.headers.get("x-csrf-token", "")
    cookie = request.cookies.get(_CSRF_COOKIE, "")
    if not (token and cookie and secrets.compare_digest(token, cookie)) \
            or not _same_origin_ok(request):
        raise HTTPException(403, "CSRF check failed — reload the page and retry")


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
    egress.regenerate_allowlist_async()  # don't block boot on the squid reload
    # Cron runs as Coolify Scheduled Tasks and per-tenant databases are
    # Coolify-managed resources with native scheduled backups — the kiosk runs no
    # in-process scheduler and no pg_dump loop (README §3).
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


@app.get("/ops/backups")
def ops_backups(request: Request):
    """Point operators at where backups now live. Per-tenant databases are
    Coolify-managed resources; their scheduled backups, executions and restore
    are handled in the Coolify dashboard, not by the kiosk."""
    identity(request)
    return JSONResponse({
        "managed_by": "coolify",
        "note": "Per-tenant databases and their scheduled backups are managed in "
                "the Coolify dashboard (Database → Backups). Restores run there.",
        "dashboard": config.COOLIFY_BASE_URL or None,
    })


# ── identity + personal API tokens (the CLI / agent surface) ──────────────────
@app.get("/me")
def whoami(request: Request):
    return JSONResponse({"email": identity(request)})


@app.post("/tokens")
def create_token(request: Request, label: str = Form("")):
    who = identity(request)
    _enforce_csrf(request)
    token = "ksk_" + crypto.random_token(24)
    db.create_api_token(who, token, label.strip())
    audit.record(who, "token.create", detail={"label": label.strip()})
    # Shown once — the server stores only its hash.
    return JSONResponse({"token": token, "label": label.strip(),
                         "note": "store this now; it will not be shown again"})


@app.get("/tokens")
def list_tokens(request: Request):
    who = identity(request)
    return JSONResponse({"tokens": [
        {"id": t["id"], "label": t["label"],
         "created_at": t["created_at"].isoformat() if t["created_at"] else None,
         "last_used_at": t["last_used_at"].isoformat() if t["last_used_at"] else None}
        for t in db.list_api_tokens(who)]})


@app.post("/tokens/{token_id}/revoke")
def revoke_token(request: Request, token_id: int):
    who = identity(request)
    _enforce_csrf(request)
    ok = db.revoke_api_token(who, token_id)
    if not ok:
        raise HTTPException(404, "no such token")
    audit.record(who, "token.revoke", detail={"id": token_id})
    return JSONResponse({"ok": True})


# ── device-authorization flow (browserless `kiosk login`) ─────────────────────
# /device/code and /device/token are pre-auth (the CLI has no token yet) — the
# identity edge exempts them via oauth2-proxy `--skip-auth-regex=^/device/(code|token)$`
# (see docker-compose.yml). The approval pages (/device, /device/approve) require a
# verified browser identity, so they stay behind oauth2-proxy.
def _user_code() -> str:
    raw = "".join(secrets.choice(_USER_CODE_ALPHABET) for _ in range(8))
    return f"{raw[:4]}-{raw[4:]}"


@app.post("/device/code")
def device_code():
    dc = "dev_" + crypto.random_token(24)
    uc = _user_code()
    db.create_device_code(dc, uc, config.DEVICE_CODE_TTL_S)
    # Deliberately NO verification_uri_complete: the user must type the code they
    # see in their OWN terminal, so a crafted link can't one-click-approve an
    # attacker's device against the victim's identity.
    return JSONResponse({
        "device_code": dc,
        "user_code": uc,
        "verification_uri": f"https://{config.PLATFORM_DOMAIN}/device",
        "interval": config.DEVICE_POLL_INTERVAL_S,
        "expires_in": config.DEVICE_CODE_TTL_S,
    })


@app.post("/device/token")
def device_token(device_code: str = Form(...)):
    state = db.device_state(device_code)
    if state == "approved":
        email = db.consume_device_code(device_code)
        if not email:  # lost a race with another poll
            return JSONResponse({"status": "consumed"})
        token = "ksk_" + crypto.random_token(24)
        db.create_api_token(email, token, "cli (device login)")
        audit.record(email, "token.create", detail={"via": "device"})
        return JSONResponse({"token": token})
    return JSONResponse({"status": state})  # pending | expired | consumed | unknown


@app.get("/device", response_class=HTMLResponse)
def device_page(request: Request):
    who = identity(request)
    # No code pre-fill: the user types the code from their own terminal.
    return templates.TemplateResponse("device.html", {
        "request": request, "who": who, "approved": None})


@app.post("/device/approve", response_class=HTMLResponse)
def device_approve(request: Request, user_code: str = Form(...),
                   csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
    approved = db.approve_device_code(user_code.strip(), who)
    if approved:
        audit.record(who, "device.approve", detail={"user_code": user_code.strip()})
    return templates.TemplateResponse("device.html", {
        "request": request, "who": who, "approved": approved})


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
        "tokens": db.list_api_tokens(who),
    })


@app.get("/apps")
def list_apps_json(request: Request):
    """Machine-readable catalog for the CLI / agent skill."""
    identity(request)
    return JSONResponse({"apps": [
        {"slug": a["slug"], "name": a["name"], "owner": a.get("owner"),
         "status": a.get("status"), "url": a.get("url")}
        for a in db.list_apps()]})


@app.post("/apps")
async def create_app(request: Request, name: str = Form(...),
                     zipfile: UploadFile = File(...), csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
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
def set_visibility(request: Request, slug: str, visibility: str = Form(...),
                   csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
    _owner_guard(slug, who)
    if visibility not in ("invite-only", "all-staff"):
        raise HTTPException(400, "bad visibility")
    access.set_visibility(slug, visibility)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/access")
def add_access(request: Request, slug: str, email: str = Form(...),
               remove: str = Form(""), csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
    _owner_guard(slug, who)
    if remove:
        access.remove_access(slug, email)
    else:
        access.add_access(slug, email)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/secrets")
def set_secret(request: Request, slug: str, key: str = Form(...),
               value: str = Form(""), remove: str = Form(""), csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
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
def add_egress(request: Request, slug: str, domain: str = Form(...),
               csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
    _owner_guard(slug, who)
    db.add_egress(slug, domain.strip())
    # Off the request path: the squid reconfigure exec can take up to 30s.
    egress.regenerate_allowlist_async()
    # Egress proxy env is injected at start; redeploy (off the request path) so
    # the running app can reach the new domain, not just squid permitting it.
    deployer.redeploy_async(slug)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/cron")
def add_cron(request: Request, slug: str, name: str = Form(...),
             schedule: str = Form(""), command: str = Form(""),
             remove: str = Form(""), csrf: str = Form("")):
    who = identity(request)
    _enforce_csrf(request, csrf)
    _owner_guard(slug, who)
    if remove:
        db.delete_cron(slug, name.strip())
    else:
        if not schedule.strip() or not command.strip():
            raise HTTPException(400, "schedule and command are required")
        db.add_cron(slug, name.strip(), schedule.strip(), command.strip())
    # Reconcile Coolify Scheduled Tasks off the request path — sync_cron creates,
    # updates AND deletes to match the kiosk's cron rows, so a removal propagates.
    deployer.sync_cron_async(slug)
    return RedirectResponse(url=f"/apps/{slug}", status_code=303)


@app.post("/apps/{slug}/rollback")
def rollback_app(request: Request, slug: str):
    who = identity(request)
    _enforce_csrf(request)
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
    if "application/json" in request.headers.get("accept", ""):
        return JSONResponse({"slug": slug, "logs": logs})
    return templates.TemplateResponse("logs.html", {
        "request": request, "slug": slug, "logs": logs,
    })
