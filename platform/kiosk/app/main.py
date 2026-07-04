"""Kiosk web plane — the creator's only surface.

FastAPI app: ZIP-drop UI, the provisioning endpoint, per-app status/logs, and a
small catalog. Every request is identified + company-domain-checked via
`auth.identity`; the kiosk sits behind forward-auth in Traefik.
"""

from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from . import db, deployer, orchestrator
from .auth import identity
from .config import config

app = FastAPI(title="Internal App Platform — Kiosk (M1)")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))


@app.on_event("startup")
def _startup() -> None:
    db.init()


@app.get("/healthz")
def healthz() -> JSONResponse:
    return JSONResponse({"ok": True, "auth_mode": config.AUTH_MODE})


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
    return templates.TemplateResponse("app.html", {
        "request": request,
        "who": who,
        "slug": slug,
        "record": record,
        "job_status": job.status if job else (record or {}).get("status"),
    })


@app.get("/apps/{slug}/status")
def app_status(request: Request, slug: str):
    identity(request)
    job = orchestrator.get_job(slug)
    record = db.get_app(slug)
    if job is None and record is None:
        raise HTTPException(404, "no such app")
    return JSONResponse({
        "slug": slug,
        "status": (job.status if job else record.get("status")),
        "url": (job.url if job and job.url else (record or {}).get("url")),
        "lines": (job.lines if job else []),
    })


@app.get("/apps/{slug}/logs", response_class=HTMLResponse)
def app_logs(request: Request, slug: str):
    identity(request)
    if db.get_app(slug) is None:
        raise HTTPException(404, "no such app")
    logs = deployer.app_logs(slug, tail=300)
    return templates.TemplateResponse("logs.html", {
        "request": request, "slug": slug, "logs": logs,
    })
