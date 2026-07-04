# Internal App Platform — Design & Plan

> **One-line:** a self-serve platform where non-engineers **drop a ZIP and get a hosted internal app** — with database, cron, Google login, per-app RBAC, and optional LLM access — built on **Coolify** as the engine, running the same on a laptop (Colima) and an internal EC2 box.

**Status:** planning / design (docs only) · **Trust model:** trusted-internal, accident-hardened · **Purpose:** alignment, stakeholder buy-in, discovery.

**Two planes (core principle):** **Creators (non-engineers) only ever use the Kiosk** (user-facing). **Operators (engineers) use the Coolify dashboard as the admin/ops console.** The Kiosk drives Coolify through its API on the creator's behalf; nobody non-technical touches Coolify.

Everything here is **Day-0 scope** (including backups, observability, audit, lifecycle).

---

## TL;DR

People keep vibe-coding useful internal tools and hit the same wall: **nowhere proper to run something with a backend, a database, or per-user access.** This removes that wall.

| A creator does | The platform does automatically |
|---|---|
| Sign in with company Google | Authenticates via oauth2-proxy (company domain only) |
| Name app, **drop a ZIP** | Detects stack, LLM-generates a **Dockerfile**, builds + scans, **classifies data** |
| Flip toggles (DB/Cron/Auth/RBAC/LLM/Storage/Email) | Provisions per-tenant DB, LLM key, bucket, mail creds; wires cron + RBAC |
| Paste keys, confirm roles | Stores secrets encrypted, deploys via Coolify, assigns URL + TLS, **backs up** |
| — | Live URL + invite link + **logs/health in the Kiosk** |

---

## High-level diagram — two planes, three audiences

```
                          PEOPLE
  Creators (non-eng)        Operators (eng)          End users
        │ use                    │ admin                 │ use apps
        ▼                        ▼                        ▼
 ┌───────────────┐       ┌────────────────┐      ┌──────────────────┐
 │   KIOSK       │       │ COOLIFY         │      │  Tenant apps     │
 │ (USER PLANE)  │──API─▶│ dashboard       │      │  (behind auth)   │
 │ ZIP → app,    │       │ (ADMIN PLANE)   │      │                  │
 │ logs, catalog │       │ infra/ops/debug │      └────────▲─────────┘
 └──────┬────────┘       └───────┬─────────┘               │
        │  drives                 │ is the engine           │ serves
        └─────────────┬───────────┴─────────────────────────┘
                      ▼
             COOLIFY ENGINE  (builds, deploys, routes everything)
```
Creators see **only** the Kiosk. Operators use **only** Coolify (admin). End users see **only** their app URL.

---

## System diagram — how the pieces compose

```
── INGRESS (Coolify-managed Traefik) ───────────────────────────────────────
   https://<app>.apps.internal
        └▶ oauth2-proxy  (Google login, company domain only; inject identity)
             └▶ authz service  (per-app manifest rules, default-deny)
                  └▶ tenant app container

── CONTROL PLANE :: KIOSK  (itself a Coolify app, behind oauth2-proxy) ──────
   Web UI ─ Orchestrator/API ─ Build workers(+allowlist+Trivy) ─ Detect/LLM
          ─ Catalog ─ Lifecycle ─ Audit ─ Observability aggregator
                              │ drives (least-priv token)
                              ▼  Coolify REST API

── COOLIFY ENGINE ───────────────────────────────────────────────────────────
   build/deploy-from-image · cron (Scheduled Tasks) · env/secret store ·
   per-app CPU/mem limits · rollback · TLS/domains · multi-server placement ·
   scheduled DB backups · deploy notifications · ADMIN DASHBOARD (operators)

── SHARED SERVICES (Coolify-deployed, governed, per-tenant-scoped) ───────────
   LiteLLM ───▶ OpenRouter        sqld/libSQL (DB namespaces) ──▶ S3 replication
   Postgres (metadata + audit)    Redis (cache/limits)
   MinIO / S3  (DB backups + per-app buckets)     Email relay ──▶ SES / Postal
   Observability: Uptime-Kuma · Grafana+Loki · GlitchTip (errors)

── PER TENANT (provisioned by the Kiosk) ────────────────────────────────────
   Coolify Destination (isolated network) · DB namespace · LLM virtual key ·
   object bucket · SMTP creds · confirmed manifest (roles→routes) · owner+team
```

---

## 1. Why — problem & workloads

Real internal apps, by *shape*:

| App | Needs |
|---|---|
| AI Literacy Learning Hub | frontend+API, DB, SSO, custom domain |
| ADM Tracker | DB, **per-user RBAC**, **email reports**, ⚠️ booking/PNR (customer) data |
| AI Engineering Leaderboard | DB, cron, internal-network access |
| hbow agent | long-running **agent/container**, process forking |
| Translation Manager | DB, SSO, scaling |
| EnzoBot & self-hosts | a **blessed home**; data governance/visibility |

The gap is **structural** (apps stall waiting for an engineer). This is the blessed path, self-serve.

---

## 2. What we support

- **Runtimes:** Node.js, Python. **Shapes:** static · fullstack · backend API · worker/agent.
- **Add-ons (toggles):** Database · Cron · Google auth · per-app RBAC · LLM · **Object storage** · **Email**.
- **Contract:** a **Dockerfile is always the artifact** — LLM-generated for the creator, never hand-written.

<details>
<summary><b>Feature → component map</b></summary>

| Feature | Delivered by |
|---|---|
| Host Node/Python app | generated Dockerfile → image → Coolify deploy-from-image |
| Database | libSQL/sqld namespace + injected `DATABASE_URL` |
| Cron | Coolify Scheduled Task |
| Google login | oauth2-proxy (company domain only) |
| End-user RBAC | oauth2-proxy (authN) + manifest-driven authz (authZ) |
| LLM | LiteLLM per-tenant virtual key + injected env |
| Object storage | per-app MinIO/S3 bucket (or Coolify volume) |
| Email | shared relay, injected SMTP creds |
| Secrets | Coolify encrypted env store |
| Custom domain + TLS | Coolify (Traefik) |
| Backups | sqld→S3 replication + Coolify DB backups |
| Isolation | Destination-per-tenant + per-app limits + default-deny RBAC + budgets |
</details>

<details>
<summary><b>Supported combinations</b> — runtime × shape × add-ons</summary>

Frameworks per runtime × shape:

| Runtime | Static client | Fullstack | Backend API | Worker / agent |
|---|---|---|---|---|
| **Node.js** | React, Vue, Svelte, Astro | **Next.js**, Nuxt, Remix, SvelteKit | Express, Fastify, NestJS, Hono | plain Node (cron/agent) |
| **Python** | — | **Streamlit, Gradio, Dash** (data-apps) | FastAPI, Flask, Django | plain Python (cron/agent) |

Which add-ons apply to which shape:

| Shape | DB | Cron | Auth | RBAC | LLM | Storage | Email |
|---|---|---|---|---|---|---|---|
| Static client | via edge/proxy | opt | ✅ | UI-only | opt | opt | opt |
| Fullstack | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Backend API | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Worker / agent | ✅ | ✅ (it *is* the schedule) | — | — | ✅ | ✅ | ✅ |

The kiosk surfaces ~7 base recipes (each runtime × valid shape) with the add-ons as independent toggles — not the raw cartesian.
</details>

---

## 3. Deviations & extensions from native Coolify (and why)

We lean on Coolify for everything it does well, and **only build what it genuinely lacks.**

| Coolify provides natively (we use as-is) | We extend / add (and why) |
|---|---|
| Ingress, TLS, custom domains | **Kiosk** — self-serve, non-technical ZIP→app UX (Coolify's UI is engineer-facing) |
| Build + deploy-from-image, rollback | **LLM Dockerfile generation + heal + probe detection** (Coolify won't author a Dockerfile for you) |
| Cron (Scheduled Tasks) | **LiteLLM gateway + per-tenant virtual keys** (multi-tenant LLM cost/governance — not a Coolify concept) |
| Env/secret store | **oauth2-proxy + manifest-driven authz** (Coolify RBAC gates *its dashboard*, not *end-users of apps*) |
| Per-app CPU/mem limits | **Per-tenant sqld namespaces + RLS wiring** (Coolify provisions whole DB instances; namespaces are ~50–100× cheaper) |
| Multi-server placement | **Destination-per-tenant orchestration** for network isolation |
| Scheduled DB backups (managed DBs) | **sqld→S3 replication + per-app buckets** (backup for the cheap DB + app file storage) |
| Deploy notifications | **Shared email relay** for apps (governed outbound mail) |
| **Admin dashboard (operators use it)** | **Governance layer** — data classification, lifecycle/sprawl control, actor-attributed audit, creator-facing observability |

**Rule:** native Coolify = the admin/infra plane and the deploy engine; our extensions = the **user plane (Kiosk)** + **multi-tenant governance** Coolify doesn't do.

---

## 4. The Kiosk — design, deployment, monitoring

The Kiosk is the **user plane**. It's the only thing creators see, and it's the brain that turns a ZIP into a governed, hosted app.

### Design (components)
```
Kiosk
 ├─ Web UI ............ ZIP-drop, toggles, catalog, per-app logs/health, invites
 ├─ Orchestrator/API .. idempotent provisioning saga; drives Coolify API
 ├─ Build workers ..... build image + base-image allowlist + Trivy scan; queue+pool
 ├─ Detect + LLM ...... stack detection, LLM Dockerfile gen + heal, probe scripts,
 │                      data-classification pass
 ├─ Catalog + Lifecycle activity tracking, sleep/archive, owner+team, transfer
 ├─ Audit ............. append-only, actor = Google identity
 └─ Observability agg .. surfaces Coolify logs/health; tracks builds, LLM spend
```
State lives in the **metadata Postgres** (tenant↔app↔db, manifests, roles, audit, catalog); UI/API/workers are otherwise stateless.

### Deployment (dogfooded)
- The Kiosk is **itself a Coolify Dockerfile app**, deployed the same way tenant apps are — behind **oauth2-proxy** (company Google), with a **least-privilege Coolify token**.
- **Build workers run isolated** from the token-holding API process (so a bad build can't reach the master tokens).
- **HA:** stateless UI/API scale as replicas behind Coolify's proxy; state is in Postgres.
- Operators manage/troubleshoot the Kiosk (and everything) from the **Coolify admin dashboard**.

### Monitoring — the Kiosk monitors everything
- **Creator-facing:** surfaces each app's Coolify **logs, health, deploy history** in the Kiosk (via API) — creators never open Coolify.
- **Signals it aggregates:** build status, **LLM spend** (LiteLLM), **app activity** (proxy logs → lifecycle), health/uptime, **audit** events.
- **Operator-facing:** Coolify's built-in **deploy-failure notifications** + **Uptime-Kuma** (uptime/alerts) + **Grafana/Loki** (fleet metrics/logs) + **GlitchTip** (app errors). Operators watch these + the Coolify dashboard.

---

## 5. User journey

Worked through with the canonical hard case: a **stock Next.js app that uses *every* feature** — staff log in with Google, see role-gated pages, read/write their org's data, ask an LLM to summarize it, and get a nightly email report. The ZIP has `package.json` (`next`, `@libsql/client`, `openai`), a `.env.example` (`STRIPE_KEY`), and an `/admin` route.

**Phase 1 — Create (what the creator does).**
1. Sign in to the Kiosk with the company Google account.
2. **New App → name it → drag the ZIP.**
3. The Kiosk detects **Next.js**, that it's an **LLM app** (`openai`), that it uses a **DB** (`@libsql/client`), that it needs **`STRIPE_KEY`**, and runs a **data-classification** pass.
4. A hardened **Dockerfile is generated** and run through the **build-verify-heal** loop until it boots and serves.
5. Plain-English summary + toggles, pre-filled from detection: **Database ON**, **LLM ON** (tier), **Auth ON** (LLM proposes **Admin/Editor/Viewer** from the route map, `/admin/*` → Admin only), **Cron** ("nightly 09:00"), **Secrets** (paste `STRIPE_KEY`), **Storage/Email** if needed, optional **custom domain**.
6. Click **Deploy**.

**Phase 2 — Provision (invisible saga).** Build + scan → push image → create DB namespace → mint LLM virtual key → provision bucket + SMTP creds → set env/domain/limits/cron via the Coolify API → attach the auth middleware chain → deploy in the tenant's **Destination** → enable backup → record **owner + manifest + audit**. Creator gets a **live URL + invite link + logs**.

**Phase 3 — Invite & roles.** Creator invites staff by email and assigns Admin/Editor/Viewer. No code.

**Phase 4 — End users use it.**
```
staff browser → Coolify Traefik (TLS, host route)
             → oauth2-proxy  (company Google? inject X-Auth-Request-Email)
             → platform-authz (role allowed on this path/method? default-deny)
             → the app → its OWN DB namespace + the LLM gateway (budgeted, cached)
```
A Viewer hitting `/admin` is blocked **before** the app sees it; the app can't reach other tenants (its own Destination) or IMDS.

**Phase 5 — Scheduled work.** At 09:00 the app's Coolify **Scheduled Task** runs the report (same env, DB, LLM key), sends the email via the relay, exits — with run history in the Kiosk.

**Phase 6 — Maintain.** Update = **new ZIP** → rebuild → health-checked swap. Rollback = redeploy a prior image. Rotate a secret, browse logs/health/cron history, manage users, or offboard (export → tear down) — all in the Kiosk.

<details>
<summary><b>Deployments, rollback & migration caveat</b></summary>

Update = new ZIP/git push → new image tag → allowlist + Trivy scan → manifest **delta** re-check → Coolify **health-checked zero-downtime rollout**. Rollback = redeploy a prior immutable tag. Config change = Coolify env API + redeploy. **DB migrations are the app's job** (startup or Scheduled Task); image rollback reverts compute, **not schema** → forward-fix.
</details>

---

## 6. Operations (Day-0)

<details>
<summary><b>Backup & DR</b> — per-tenant data, sqld SPOF</summary>

**sqld → continuous S3 replication** (libSQL "bottomless") gives per-namespace point-in-time restore *and* turns sqld from a data-loss SPOF into a fast-restore one. **Coolify scheduled backups** cover the metadata Postgres; **source ZIPs + Dockerfiles retained** so images are reproducible. RPO ≈ minutes, RTO = restore-to-new-sqld. (Confirm bottomless + namespaces on the pinned sqld.)
</details>

<details>
<summary><b>Data-classification enforcement</b> — undeclared PII/PNR</summary>

**Attestation + ingest detection:** the Kiosk's analysis pass (LLM/regex over code, schema, `.env`, sample data) scans for customer-data signals; **egress/source signals** flag apps reaching prod/customer systems. **Undeclared-but-detected → block/escalate** to the hardened-tier policy. Catches accidents (the actual threat), not determined evaders. Real enforcement = **tier separation** the flag triggers.
</details>

<details>
<summary><b>Lifecycle, ownership & sprawl</b></summary>

Every app has **owner + team**. **Activity tracking** (proxy logs) drives **flag → sleep (Coolify stop, reclaim resources) → archive (keep data backup) → delete (retention)**. A **fleet catalog** in the Kiosk gives visibility + duplicate detection (the brief's concern). **Offboarding** (Google account disabled) → ownership transfer or archive.
</details>

<details>
<summary><b>Observability</b></summary>

MVP: surface Coolify per-app logs/health in the Kiosk + Coolify's built-in failure alerts. Add **Uptime-Kuma** (uptime/alerts), **Grafana+Loki** (fleet metrics/logs), **GlitchTip** (app error tracking). All self-hosted, lightweight, Coolify-deployed.
</details>

<details>
<summary><b>Audit</b></summary>

Kiosk writes an **append-only, actor-attributed** log (actor = Google identity — Coolify only sees the Kiosk's token, so attribution must happen in the Kiosk) for provision/deploy/role/secret/offboard actions; proxy + authz record access decisions. Retained in Postgres + optionally shipped to object storage (WORM). Underpins PDPL/Nusuk.
</details>

<details>
<summary><b>Object storage & email</b></summary>

**Object storage** (MinIO/S3 — also used for backups): per-app **scoped bucket** via injected env; Coolify volume as zero-config fallback for local-file apps. **Email:** one **shared, governed relay** (SES/Resend or self-hosted Postal), injected as SMTP creds — deliverability (SPF/DKIM on one domain), per-tenant rate limits, outbound audit. Same "central governed gateway" pattern as LiteLLM.
</details>

<details>
<summary><b>Multi-container apps & build UX</b></summary>

**Multi-service:** default single image; genuine multi-service → **multiple linked Coolify apps in one project** (images-not-compose preserved for RBAC labels); permit **compose** when only app-level (not per-path) auth is needed. **Build UX:** queue + scalable worker pool; on heal-failure show a **plain-English diagnosis + suggested fix + escalate-to-human + save-as-draft** — never a raw stack trace.
</details>

<details>
<summary><b>Scaling & growth</b></summary>

- **More powerful app:** raise per-app CPU/mem limits and/or place it on a **beefier server** (Coolify per-resource placement). No replicas needed — this is the axis Coolify does well.
- **Spread load:** add servers to the Coolify fleet.
- **Data:** more sqld nodes → **Turso Cloud**; metadata/object storage → managed RDS / S3.
- **Ceiling:** single-app **replica-HA** isn't native until Coolify v5 → that one app graduates to **Cloud Run / Fly / K8s** (a re-point via the Dockerfile contract). Everything else stays turnkey.
- **Parity:** same Coolify on **Colima (laptop)** and **EC2**; only config differs.
</details>

---

## 7. Key decisions & rationale

| Decision | Why |
|---|---|
| Coolify as engine (Apache-2.0) | Removes ~60–70% of plumbing; verified no blocker; **admin plane for operators** |
| Kiosk as user plane | Non-engineers can't use Coolify; the Kiosk is the only surface they see |
| Mandated LLM-generated Dockerfile | One reproducible contract; creator writes nothing |
| Trusted-internal, accident-hardened | Threat is mistakes → keep blast-radius controls, drop gVisor → Coolify stays simple |
| oauth2-proxy + company Google | Users log in with company Google. Not Clerk (SaaS/SDK/residency); not Authelia (can't broker Google) |
| libSQL/sqld namespaces default | ~50–100× cheaper than Postgres-per-tenant; Postgres only when needed (RLS) |
| No source modification | Detection = static + LLM probes + confirmed manifest; code never rewritten |
| Shared governed gateways | LiteLLM (LLM), email relay, object storage — central, per-tenant-scoped, audited |

<details>
<summary><b>Per-app RBAC internals</b></summary>

Chain via Coolify custom labels: `oauth2-proxy (Google, company-only) → authz (host→manifest rules→email→role→allow/deny, default-deny) → app`. Roles LLM-proposed, creator-confirmed into the **manifest** (Postgres). Coarse (path/method) = zero app code, fail-closed. **Row-level** = opt-in Postgres **RLS** (no filter code; non-owner role + `FORCE RLS`; deny-when-unset), identity reaches the DB via an identity-aware gateway (zero code) or a confirmed one-liner.

**Auth-tool alternatives:** oauth2-proxy (default) · traefik-forward-auth (minimal) · **Zitadel/Keycloak** (richer self-hosted orgs, both broker Google). Clerk excluded (SaaS-only, SDK-shaped, residency).
</details>

<details>
<summary><b>Detection & app contract</b> — RBAC applied without touching source</summary>

- **The guarantee is fail-closed default-deny, not perfect detection** — a route the platform *misses* is **denied, not exposed**. Detection accuracy is a friction concern, not a correctness one.
- **Multi-signal:** static route parsing + **LLM-generated ephemeral probe scripts** (run against a throwaway instance) + LLM semantic classification, reconciled; low-confidence items flagged for confirmation.
- **Conventions recommended, not mandated** (12-factor, conventional router, read identity headers, no self-auth); non-conformers still deploy with lower auto-confidence. **No codemods** — the creator's code is never rewritten.
- **Confirmed manifest = source of truth**, re-checked as a **delta** on each redeploy so an update can't silently open a route.
</details>

---

## 8. Security posture

**Verdict:** secure *for the trusted-internal, accident-hardened model* with the fixes below — two "arbitrary code on the shared host" risks **contained, not eliminated** (gVisor excluded), and **customer-data apps kept off this tier by policy**.

**Central tension:** the pipeline feeds **untrusted, LLM-interpreted input** (the ZIP) **into privileged operations** (the build) — so the fixes apply *regardless* of trusting authors, and a dependency-compromised app of even a trusted author is in scope.

**Top fixes (all Coolify-friendly):** base-image allowlist + Trivy scan (build-RCE); network segmentation via **Traefik-hostname platform access** (tenant Destinations hold no datastores); strip inbound `X-Auth-*` + fail-closed authz + path canonicalization.

<details>
<summary><b>Full findings → fixes</b> (🟦 Coolify · 🟩 service config · 🟨 kiosk · 🟥 accepted)</summary>

| Finding | Fix | Where |
|---|---|---|
| Build-time RCE | base-image allowlist + Trivy scan; full sandbox bespoke (deferred) | 🟨+🟥 |
| sqld admin unauth/reachable | admin auth key + per-namespace tokens + internal net | 🟩+🟦 |
| Kiosk master tokens | least-priv token; behind oauth2-proxy; isolate build workers; per-user quotas | 🟦+🟨 |
| Lateral movement | Destination-per-tenant; platform svcs via Traefik hostnames; default-deny egress | 🟦+🟩 |
| Header spoofing | strip inbound `X-Auth-*`; ports unpublished | 🟦 |
| authz fail-open/path bypass | fail-closed; canonicalize; invalidate cache on role change | 🟨 |
| Postgres RLS bypass | non-owner role + `FORCE ROW LEVEL SECURITY` | 🟨 |
| Over-permissive manifest | most-restrictive default; explicit opt-in; loud "public" warning | 🟨 |
| Cross-tenant LLM cache | verify namespace hook; else disable tenant cache | 🟩 |
| Customer data → OpenRouter | provider filtering + ZDR; **policy: not hosted here** | 🟩+🟥 |
| Zip-slip / bomb | safe extract (reject `../`, cap size/ratio/count) | 🟨 |
| Secrets blast radius | least-priv token; block on hard-coded secret; no build args | 🟦+🟨 |

**Accepted/contained (no gVisor):** container escape (contained by segmentation) · build-RCE residual · customer-data apps off-tier (policy).
</details>

---

## 9. Open items (genuinely still open)

| Item | Status |
|---|---|
| Coolify Destination **creation** via API | assignment confirmed + immutable; **creation path** = spike (pool / register / MCP) |
| Tenant-scoped LLM cache hook | verify (two-tenant identical-prompt test) |
| Auth smoke test | add when built (unauth request must not 200) |
| sqld bottomless + namespaces | confirm on pinned version |
| Fine-grained row-level | designed as-no-code-as-possible; the app-cooperative edge |
| gVisor / build sandbox | excluded for simplicity → contained risks; reopen for adversarial/internet-facing |

---

## Glossary

- **Kiosk** — user-facing control plane; creators' only surface; drives Coolify's API.
- **Coolify** — open-source PaaS used as the engine + **admin/ops console** for operators.
- **Destination** — a Coolify Docker-network deployment target; one per tenant = network isolation.
- **Manifest** — confirmed per-app record: routes, role→path rules, port, secrets, cron.
- **forward-auth** — proxy middleware that authN/authZ a request before it reaches the app (zero app code).
- **Virtual key** — per-tenant, budgeted LiteLLM key mapped to the OpenRouter master key.
- **RLS** — Postgres Row-Level Security; row-level access enforced by the database.
- **Bottomless** — libSQL continuous replication to S3 for backup/PITR.
