# Sample tenant apps

Minimal, dependency-free stand-ins — one per candidate app in the requirements
(README §1) — used to **test-drive the platform's support** for each app's shape.
`make samples` zips every directory here into `dist/*.zip` for drag-and-drop into
the Kiosk (or POST to `/apps`).

Each app is intentionally tiny (mostly Python stdlib / Node built-ins, no pip/npm
deps) so builds never hinge on package installs. Apps that "need a DB" prove the
platform's guarantee — a per-tenant `DATABASE_URL` is injected and the database is
reachable — with a socket check, rather than pulling a driver.

## Candidate app → representative → what it proves

| Requirement app (README §1) | Sample | Runtime | Capabilities exercised | Not covered (why) |
|---|---|---|---|---|
| **AI Engineering Leaderboard** (Pilot 1) | `leaderboard` | Python | per-tenant **DB** + **cron** (recompute) | — |
| **ADM Tracker** (Pilot 2) | `adm-tracker` | Python | **DB** reachability, whole-app **invite-only access**, **secret** (`REPORT_WEBHOOK`), **cron** (`report.py`), **egress** allow-list | per-route **RBAC** (Viewer/Editor/Admin) → **M3**; email = egress+secret to a mail API |
| **AI Literacy Learning Hub** | `learning-hub` | Node | **frontend + JSON API** in one container, **DB**, **SSO** (company Google, whole-app) | **custom domain** → target-arch (v1 serves a platform subdomain) |
| **hbow agent** | `hbow-agent` | Python | **long-running** background loop + status endpoint (platform keeps it up + monitors) | forking/multi-worker orchestration → target-arch |
| **Translation Manager** | `translation-manager` | Python | **DB**, **SSO** | **scaling/HA** → target-arch (v1 is one box) |
| **EnzoBot & self-hosts** | `enzobot` | Python | **secret** (`BOT_TOKEN`), **egress** allow-list, governance (catalog + owner + audit) | — |

Two trivial smoke apps also ship: `node-hello`, `python-hello` — used by the
Coolify parity gate (see [`../coolify/README.md`](../coolify/README.md)) to prove
the raw Node/Python build→verify→deploy path.

## How each was verified (stub LLM mode, real Docker)

All five new representatives deploy to **running** and serve behind login; the
headline capability of each was exercised live:

- **DB**: `adm-tracker`, `learning-hub`, `translation-manager` all report the
  injected `DATABASE_URL` as reachable (`postgres:5432`).
- **Access**: `adm-tracker` set to invite-only → owner `200`, a company
  non-invitee `403`, and `200` again after being invited.
- **Secret**: `adm-tracker` (`REPORT_WEBHOOK`) and `enzobot` (`BOT_TOKEN`) show the
  value injected after the config-change redeploy.
- **Egress**: adding a domain to `enzobot` injected `HTTPS_PROXY=http://egress-proxy:3128`.
- **Cron**: a schedule registered on `adm-tracker` (`python report.py`).
- **Long-running**: `hbow-agent` work-ticks increment across requests.

## What these do NOT prove

These are **shape** stand-ins, not the real apps. They deliberately avoid heavy
dependencies, so they don't exercise a real ORM, migrations, or a production
frontend build. Pilot 2 (`adm-tracker`) approximates its needs on v1 controls —
**per-route RBAC, native email, data-classification enforcement, and custom
domains are target-architecture (M3+), not v1**.
