# Internal App Platform — Design & Plan

> **One-line:** a self-serve platform where non-engineers **drop a ZIP and get a hosted internal app** — with database, cron, Google login, per-app RBAC, and optional LLM access — built on **Coolify** as the engine, running the same on a laptop (Colima) and an internal EC2 box.

**Status:** planning / design (docs only) · **Trust model:** trusted-internal, accident-hardened · **Purpose:** alignment, stakeholder buy-in, discovery.

**Two planes (core principle):** **Creators (non-engineers) only ever use the Kiosk** (user-facing). **Operators (engineers) use the Coolify dashboard as the admin/ops console.** The Kiosk drives Coolify through its API on the creator's behalf; nobody non-technical touches Coolify.

**Day-0 vs sequencing:** everything here is the **Day-0 scope commitment** (what v1 must include). It is *not* a claim that it's small — the Kiosk is the hard, novel, multi-engineer-month part. **§7 sequences the build** (walking-skeleton first) with pilots and success metrics.

---

## TL;DR

People keep vibe-coding useful internal tools and hit the same wall: **nowhere proper to run something with a backend, a database, or per-user access.** This removes that wall.

| A creator does | The platform does automatically |
|---|---|
| Sign in with company Google | Authenticates via oauth2-proxy (company domain only) |
| Name app, **drop a ZIP** | Redacts secrets, detects stack, LLM-generates a **Dockerfile**, builds + scans, **classifies data** |
| Flip toggles (DB/Cron/Auth/RBAC/LLM/Storage/Email) | Provisions per-tenant DB, LLM key, bucket, mail creds; wires cron + RBAC |
| Paste keys, confirm roles + any public/webhook paths | Stores secrets encrypted, deploys via Coolify, assigns URL + TLS, **backs up** |
| — | Live URL + invite link + **logs/health in the Kiosk** |

---

## High-level diagram — two planes, three audiences

```
                          PEOPLE
  Creators (non-eng)        Operators (eng)          End users + machines
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
     ├▶ BROWSER users  → oauth2-proxy (Google, company-only; inject identity)
     │                  → authz (per-app manifest rules, default-deny) → app
     └▶ MACHINE clients → allowlisted public/webhook path (signed-token verify)
        (Stripe/Slack/    or machine token → authz (machine policy) → app
         cron/CLI)

── CONTROL PLANE :: KIOSK  (itself a Coolify app, behind oauth2-proxy) ──────
   Web UI ─ Orchestrator/API ─ Reconciler ─ Build workers(+allowlist+Trivy)
          ─ Detect/LLM (redact→LiteLLM) ─ Catalog ─ Lifecycle ─ Audit ─ Obs agg
                              │ drives (least-priv token)
                              ▼  Coolify REST API

── COOLIFY ENGINE ───────────────────────────────────────────────────────────
   build/deploy-from-image · cron · env/secret store · CPU/mem limits ·
   rollback · TLS/domains · multi-server placement · DB backups ·
   notifications · ADMIN DASHBOARD (operators)   [state itself is backed up]

── SHARED SERVICES (Coolify-deployed, governed, per-tenant-scoped) ───────────
   LiteLLM ──▶ OpenRouter (ZDR)   Postgres cluster (db-per-tenant, DEFAULT)
   (also: the Kiosk's OWN          + libSQL (lightweight option)
    LLM calls, redacted)          Metadata Postgres (HA) + Redis
   MinIO / S3 (backups+buckets)   Email relay ──▶ SES / Postal
   Observability: Uptime-Kuma · Grafana+Loki · GlitchTip

── PER TENANT (provisioned by the Kiosk) ────────────────────────────────────
   Coolify Destination (isolated net) · own database · LLM virtual key ·
   object bucket · SMTP creds · confirmed manifest (roles→routes + public paths)
   · owner+team
```

---

## 1. Why — problem, workloads & pilots

Real internal apps, by *shape*:

| App | Needs | Pilot role |
|---|---|---|
| AI Engineering Leaderboard | DB, cron, internal-network | **Pilot 1** (easy: no RBAC complexity) |
| ADM Tracker | DB, **per-user RBAC**, **email reports**, ⚠️ booking/PNR data | **Pilot 2** (exercises RBAC + email + classification + hardened-tier gate) |
| AI Literacy Learning Hub | frontend+API, DB, SSO, custom domain | later |
| hbow agent | long-running **agent/container**, forking | later |
| Translation Manager | DB, SSO, scaling | later |
| EnzoBot & self-hosts | a **blessed home**; governance/visibility | ongoing |

The gap is **structural** (apps stall waiting for an engineer). Two named pilots validate the easy path and the hard path respectively before broad rollout.

---

## 2. What we support

- **Runtimes:** Node.js, Python. **Shapes:** static · fullstack · backend API · worker/agent.
- **Add-ons (toggles):** Database · Cron · Google auth · per-app RBAC · LLM · Object storage · Email.
- **Contract:** a **Dockerfile is always the artifact** — LLM-generated for the creator, never hand-written. **It is reused across updates and regenerated only when detection changes** — so "reproducible" holds and updates don't re-roll the LLM.

<details>
<summary><b>Feature → component map</b></summary>

| Feature | Delivered by |
|---|---|
| Host Node/Python app | generated Dockerfile → image → Coolify deploy-from-image |
| Database | **Postgres db-per-tenant (default)** / libSQL (light option) + injected `DATABASE_URL` |
| Cron | Coolify Scheduled Task (overlap-guard, timezone, retry, creator alerts) |
| Google login | oauth2-proxy (company domain only) |
| Machine/webhook access | manifest public-path allowlist + signed-webhook verify / machine token |
| End-user RBAC | oauth2-proxy (authN) + manifest-driven authz (authZ) |
| LLM | LiteLLM per-tenant virtual key + injected env |
| Object storage | per-app MinIO/S3 bucket (or Coolify volume) |
| Email | shared relay, injected SMTP creds |
| Secrets | Coolify encrypted env store (redacted before any LLM sees the ZIP) |
| Custom domain + TLS | Coolify (Traefik) |
| Backups | per-tenant Postgres/db backups + Coolify state backup |
| Isolation | Destination-per-tenant + per-app limits + default-deny RBAC + budgets |
</details>

<details>
<summary><b>Supported combinations</b> — runtime × shape × add-ons</summary>

| Runtime | Static client | Fullstack | Backend API | Worker / agent |
|---|---|---|---|---|
| **Node.js** | React, Vue, Svelte, Astro | **Next.js**, Nuxt, Remix, SvelteKit | Express, Fastify, NestJS, Hono | plain Node |
| **Python** | — | **Streamlit, Gradio, Dash** | FastAPI, Flask, Django | plain Python |

Add-on validity by shape: fullstack/backend get all; static gets auth + UI-only RBAC (DB via edge); worker gets DB/cron/LLM/storage (no interactive auth). ~7 base recipes; add-ons are independent toggles.
</details>

<details>
<summary><b>Database compatibility matrix</b> — why Postgres is the default</summary>

Vibe-coded apps use mainstream ORMs that assume Postgres or file-SQLite. **Detection routes each app to the engine its code can actually talk to** (default Postgres); libSQL is offered only where the driver is happy.

| Access layer | Postgres (default) | libSQL (light) | file-SQLite |
|---|---|---|---|
| Prisma | ✅ | partial | ✅ (file) |
| Drizzle | ✅ | ✅ (libsql driver) | ✅ |
| SQLAlchemy | ✅ | limited | ✅ |
| Django ORM | ✅ | ✗ (no happy path) | dev-only |
| raw SQL / libsql client | ✅ | ✅ | ✅ |

**Postgres db-per-tenant on one shared cluster** is the default because it buys the mainstream ecosystem, **RLS without a second engine**, and **one backup story** — while still being cheap (a database, not an instance, per tenant). libSQL is the lightweight option for tiny/edge cases, not the default.
</details>

---

## 3. Deviations & extensions from native Coolify (and why)

We lean on Coolify for everything it does well, and **only build what it genuinely lacks.**

| Coolify provides (use as-is) | We extend / add (and why) |
|---|---|
| Ingress, TLS, custom domains | **Kiosk** — self-serve, non-technical ZIP→app UX |
| Build + deploy-from-image, rollback | **LLM Dockerfile generation + heal + probe detection** |
| Cron (Scheduled Tasks) | **LiteLLM gateway + per-tenant virtual keys** (multi-tenant AI governance) |
| Env / secret store | **oauth2-proxy + manifest authz + machine-token/webhook escape hatch** (Coolify RBAC gates its dashboard, not app end-users *or* machine callers) |
| Per-app CPU/mem limits | **Postgres db-per-tenant + RLS** wiring (Coolify provisions whole instances) |
| Multi-server placement | **Destination-per-tenant** orchestration |
| Scheduled DB backups + **its own state backup** | **per-tenant DB backups + Coolify-state restore runbook + host-as-code** |
| Deploy notifications | **Shared email relay**, **creator-facing observability**, **escalation queue** |
| **Admin dashboard (operators)** | **Governance** — data classification, lifecycle/sprawl, actor-attributed audit, **reconciler** |

**Rule:** native Coolify = admin/infra plane + deploy engine; our extensions = the **user plane (Kiosk)** + **multi-tenant governance**.

---

## 4. The Kiosk — design, deployment, monitoring

The Kiosk is the **user plane** — creators' only surface, and the brain that turns a ZIP into a governed, hosted app.

### Design (components)
```
Kiosk
 ├─ Web UI ............ ZIP-drop, toggles, catalog, per-app logs/health, invites
 ├─ Orchestrator/API .. idempotent provisioning saga; drives Coolify API
 ├─ Reconciler ........ background loop: diff desired (metadata) vs actual
 │                      (Coolify) → GC orphaned namespaces/keys/buckets
 ├─ Build workers ..... build + base-image allowlist + Trivy; queue+pool
 ├─ Detect + LLM ...... detection, probe scripts, Dockerfile gen + heal,
 │                      classification — ALL via LiteLLM after secret redaction
 ├─ Catalog+Lifecycle . activity, sleep/archive, owner+team, transfer, escalations
 ├─ Audit ............. append-only, actor = Google identity
 └─ Observability agg .. surfaces Coolify logs/health; tracks builds, LLM spend
```
State lives in the **metadata Postgres**; UI/API/workers are otherwise stateless.

### Deployment (dogfooded)
- The Kiosk is **itself a Coolify Dockerfile app**, behind **oauth2-proxy** (company Google), with a **least-privilege Coolify token**.
- **Build workers run isolated** from the token-holding API process.
- **HA:** stateless UI/API replicas; oauth2-proxy and authz are **replicated, not singletons** (they're in the hot path of every request).
- Operators manage/troubleshoot everything from the **Coolify admin dashboard**.

### Monitoring — the Kiosk monitors everything
- **Creator-facing:** each app's Coolify logs, health, deploy history surfaced in the Kiosk (creators never open Coolify).
- **Aggregates:** build status, LLM spend, app activity (→ lifecycle), health/uptime, audit.
- **Operator-facing:** Coolify failure notifications + **Uptime-Kuma** (uptime) + **Grafana/Loki** (fleet metrics/logs) + **GlitchTip** (app errors) + **disk alerting**.

---

## 5. User journey

Canonical hard case: a **Next.js app using every feature** — staff log in with Google, see role-gated pages, read/write their org's data, ask an LLM to summarize it, get a nightly email report, and **receive Stripe webhooks**.

**Phase 1 — Create.** Sign in (Google) → name → **drop ZIP** → Kiosk **redacts secrets**, detects Next.js + LLM + DB, runs **classification** → hardened **Dockerfile** via build-verify-heal → plain-English summary + toggles (LLM-proposed roles; **and detected webhook/machine paths to allowlist**) → **Deploy**.

**Phase 2 — Provision (saga).** Redact → build + scan → push → create per-tenant **Postgres database** → mint LLM key → bucket + SMTP creds → set env/domain/limits/cron via Coolify API → attach auth chain (+ public-path allowlist) → deploy in the **Destination** → enable backup → record owner + manifest + audit.

**Phase 3 — Invite & roles.** Invite staff, assign Admin/Editor/Viewer. Set default visibility (invite-only vs all-staff). No code.

**Phase 4 — Use it.**
```
BROWSER  → Traefik → oauth2-proxy (company Google) → authz (role/route, default-deny) → app
MACHINE  → Traefik → allowlisted /webhooks/stripe (signed-token verify) ─────────────→ app
```
A Viewer hitting `/admin` is blocked before the app sees it; Stripe's webhook reaches the app because that path is explicitly allowlisted and signature-verified.

**Phase 5 — Scheduled work.** 09:00 Coolify Scheduled Task runs the report (overlap-guarded, timezone-declared, retries, **failure alerts the creator**), sends email via the relay, exits.

**Phase 6 — Maintain.** Update = new ZIP → rebuild (Dockerfile reused unless detection changed) → **preview URL → promote** → health-checked swap. Rollback = redeploy a prior image. Manage secrets/logs/users/cron; offboard (export → tear down, reconciler GCs remnants).

<details>
<summary><b>RBAC precision — what it does and doesn't guarantee</b></summary>

- **Guarantees route + method** (path/method → role, default-deny), enforced at the proxy with zero app code. A missed route is denied.
- **Does NOT guarantee sub-route operations.** Server actions, GraphQL (`POST /graphql`), websockets, and SSE **multiplex many operations on one route** — path/method can't tell "Viewer clicked a safe button" from "Viewer invoked the admin mutation." **The default is the safe one:** any framework that *can* multiplex (detected by a **deterministic signal** — `next` + app router, a GraphQL/ws dependency — not LLM judgment) gets a **coarse whole-app role gate**; per-path/method RBAC is claimed *only* where routes map 1:1 to operations. A detection miss yields the **coarser, safer** behavior, never a falsely-fine one, and the UI states the level plainly ("gated by role, not individual buttons; per-button control needs the app to read the identity header").
- **Row-level** and **operation-level** are the same class: fine granularity below the route needs app cooperation (identity headers) or Postgres RLS.
</details>

<details>
<summary><b>Detection reliability — the LLM proposes, structure guarantees</b></summary>

Safety must not rest on LLM recall — a **silent false negative** (missed customer data, undetected server actions) is the dangerous failure. So:
- **Structural defaults hold even at zero recall:** default-deny routes · default-coarse RBAC for multiplexing frameworks · the egress boundary for customer data. The LLM only *proposes*; the guarantee is the default.
- **Safety-critical defaults key off deterministic signals** (static route parse, framework fingerprint, high-precision format regex, egress grants) — the LLM augments, never decides the default.
- **Fail toward restrictive:** union of independent detectors; any hit escalates/restricts.
- **Detector eval harness (Day-0):** a labeled + **red-team** fixture corpus with measured **recall/precision targets**, regression-tested on every model/prompt change; detectors are treated as safety-critical code with coverage, and **confidence is calibrated** so low-confidence detections route to the human queue.
- **Net:** LLM recall affects *friction* (how often a human is pulled in, how coarse the default), **not safety**.
</details>

<details>
<summary><b>Machine clients & webhooks (non-browser)</b></summary>

oauth2-proxy is a browser flow — Stripe/Slack/inbound-email/external-cron/CLI can't complete it. So the manifest carries a **public/webhook path allowlist** (with the same loud "public" warning as any public rule): those paths bypass the browser login and are protected by **signed-webhook verification** (provider signature) or a **platform-issued machine token** for service-to-service calls. Detection proposes these paths from signals like a Stripe/Slack SDK; the creator confirms.
</details>

---

## 6. Operations (Day-0)

<details>
<summary><b>Backup & DR</b> — tenant data AND platform state</summary>

- **Tenant DBs:** per-tenant Postgres database backups (Coolify-scheduled / cluster WAL to S3) → point-in-time restore, one backup story. (libSQL apps: bottomless S3 replication.)
- **Coolify's own state** (domains, envs, tasks, destinations = the deployment state): **data-dir backup + a restore-tested runbook + host provisioning as code.** Retained ZIPs+Dockerfiles only reproduce apps if the engine that deploys them does too.
- RPO ≈ minutes; RTO = restore engine + data. **A DR drill (measure mean-restore-time) is a Day-0 exercise.**
</details>

<details>
<summary><b>Availability — no fleet-wide SPOF</b></summary>

- **Metadata Postgres** is in the hot path (authz reads manifests per request). So: authz **serves from a local cache with explicit staleness bounds** (invalidated on role change), and the metadata Postgres runs **HA with a stated restore posture**. "Kiosk DB blip" must not mean "every app down."
- **oauth2-proxy + authz are replicated**, not singletons.
</details>

<details>
<summary><b>Disk & capacity (single-box Coolify's classic failure)</b></summary>

**Image GC/prune policy + per-app volume quotas + disk alerting** — images/build-cache/volumes filling the disk take the whole fleet down. **Capacity planning:** an apps-per-box heuristic gives "add a server" a concrete trigger.
</details>

<details>
<summary><b>Image freshness — nothing rots</b></summary>

Trivy at build time is not enough. **Periodic re-scan of deployed images → rebuild behind the health-checked rollout, notifying the owner** (never a blind auto-redeploy that could break a vibe-coded app). Plus a **base-image update cadence** and a **Coolify upgrade/pinning policy** (Coolify moves fast; we're already eyeing v5 for replicas).
</details>

<details>
<summary><b>Data-classification — structural boundary first, detection second</b></summary>

**Primary control is structural, not content-detection.** Apps are **default-deny egress**; reaching a **customer-data system** (prod DB, PNR API) requires an **explicit granted allowlist entry** — and that grant *is* the deterministic classification signal, routing the app to the hardened-tier gate. So a **classification miss can't cause exposure** — the app structurally can't reach the data.

**Content scan is defense-in-depth:** attestation + an ingest scan (LLM/regex over code, schema, sample data, **after secret redaction**) + runtime egress signals, re-run on **every redeploy and schema drift**. Fail-toward-restrictive: any signal → escalate.

**Honest residual:** the egress boundary closes "app *pulls* from customer systems," not "a user *pastes* PNR into a form" — for that, attestation + content scan are the weaker net (arguably a training/policy issue more than a platform control).
</details>

<details>
<summary><b>Lifecycle, ownership, audit, storage & email</b></summary>

- **Lifecycle:** owner+team per app; activity → flag → sleep (Coolify stop) → archive → delete; fleet **catalog** for visibility + duplicate detection; **offboarding** transfers or archives.
- **Roles stay fresh:** brokered to **Google Groups** (or periodic revalidation against the directory) so membership tracks the org chart.
- **Audit:** append-only, **actor = Google identity** (Kiosk attributes it — Coolify only sees the token); underpins PDPL/Nusuk.
- **Storage/email:** per-app object bucket (shared with backups); one governed **email relay** injected as SMTP creds.
- **Residency (PDPL):** **S3 replication targets and SES pinned to approved regions** — backups' geography is where residency actually bites.
</details>

<details>
<summary><b>Escalation queue (the human surface)</b></summary>

"Escalate to human" is a **named, staffed surface** — a Kiosk queue + Slack channel with an SLA — receiving classification blocks, heal-failure escalations, and hardened-tier approvals. Without it, self-serve breaks for exactly the hard cases.
</details>

<details>
<summary><b>Scaling & growth</b></summary>

- **More powerful app:** raise per-app limits and/or place it on a **beefier server** (per-resource placement). No replicas needed.
- **Spread load:** add servers to the fleet.
- **Data:** more Postgres capacity / read replicas; libSQL → Turso Cloud.
- **Ceiling:** single-app **replica-HA** isn't native until Coolify v5 → that app graduates to **Cloud Run / Fly / K8s** (a re-point via the Dockerfile contract).
- **Parity:** same Coolify on **Colima** and **EC2**; only config differs. **Dev-auth caveat:** Google OAuth redirect URIs and `*.apps.internal` TLS/DNS don't "just work" on a laptop — the local story is **mkcert + dnsmasq (or `/etc/hosts`) + a registered dev redirect URI, or a dev-mode identity stub** that bypasses Google. Documented so "same on laptop" survives first contact.
</details>

<details>
<summary><b>Multi-container apps & build UX</b></summary>

Default single image; genuine multi-service → **multiple linked Coolify apps in one project**; permit **compose** when only app-level auth is needed. **Build UX:** queue + worker pool; on heal-failure → **plain-English diagnosis + suggested fix + escalate + save-as-draft** (never a raw stack trace).
</details>

---

## 7. Delivery — sequencing, pilots, success metrics

**Reconciliation with Day-0:** Day-0 defines the *scope* (§2–6); this section defines the *build order*. **The Kiosk is several engineer-months** — Coolify removes ~60–70% of plumbing, but the remaining 30–40% (orchestrator + reconciler, build/heal pipeline, detection/probes, authz + manifest, catalog/lifecycle, audit, observability) is the hard, novel part. Stakeholders approve a scope *and* a cost; this makes both explicit.

**Build order (dependency edges → each milestone is shippable):**
1. **Walking skeleton:** ZIP → LLM Dockerfile (redacted→LiteLLM) → build+scan → deploy behind oauth2-proxy. *No RBAC/DB/lifecycle.* Proves the core loop + two-plane.
2. **+ Data & secrets:** per-tenant Postgres + Coolify secret store. → **Pilot 1: Leaderboard.**
3. **+ RBAC & machine access:** authz service + manifest + webhook/machine-token escape hatch + server-action downgrade detection.
4. **+ AI governance:** LiteLLM per-tenant keys (Kiosk already routes through it from step 1).
5. **+ Day-0 ops:** backup/DR (+drill), HA/authz-cache, disk GC/quotas, reconciler, classification, audit, lifecycle. → **Pilot 2: ADM Tracker** (RBAC+email+classification+hardened-tier gate).
6. **+ Polish:** cron semantics, email, storage, preview-before-promote, rebuild cadence, escalation queue.

**Success metrics:** apps migrated off off-platform hosting · **time-to-first-deploy** (ZIP→live) · **% builds healed without human** · self-serve completion rate (no escalation) · platform uptime · **mean restore time** (from the DR drill).

---

## 8. Key decisions & rationale

| Decision | Why |
|---|---|
| Coolify as engine (Apache-2.0) | Removes ~60–70% of plumbing; verified no blocker; admin plane for operators |
| Kiosk as user plane | Non-engineers can't use Coolify |
| LLM-generated Dockerfile, **reused across updates** | One reproducible contract; regenerated only on detection change |
| Trusted-internal, accident-hardened | Threat is mistakes → keep blast-radius controls, drop gVisor → Coolify stays simple |
| oauth2-proxy + company Google **+ machine-token/webhook allowlist** | Browser SSO for people; a designed bypass for Stripe/Slack/cron/CLI. Not Clerk/Authelia |
| **Postgres db-per-tenant (default)**, libSQL optional | Mainstream ORM compatibility for vibe-coded apps + RLS + one backup story; libSQL is the light option |
| No source modification | Detection = static + LLM probes + confirmed manifest; code never rewritten |
| **Kiosk LLM calls governed like tenants'** | Its own inference goes through LiteLLM (ZDR) after redaction |
| **LLM proposes, structure guarantees** | Safety rests on deterministic defaults (default-deny, default-coarse RBAC, egress boundary) + a detector eval harness — an LLM miss changes friction, not safety |

---

## 9. Security posture

**Verdict:** secure *for the trusted-internal, accident-hardened model* with the fixes below — two "arbitrary code on the shared host" risks **contained, not eliminated** (gVisor excluded), and **customer-data apps kept off this tier by policy**.

**Central tension:** the pipeline feeds **untrusted, LLM-interpreted input** (the ZIP) into **privileged operations** (the build) — so the fixes apply regardless of trusting authors, and a dependency-compromised app of a trusted author is in scope.

**The Kiosk's own LLM pipeline is a governed egress path:** the platform sends source, schemas, and sample data to an LLM for generation/classification/probes. So **secrets are scanned and redacted before any LLM sees the ZIP**, and the Kiosk's own calls go through **LiteLLM pinned to a ZDR/approved provider** — closing a blind spot that would otherwise ship a hard-coded key or PNR sample to a third party *before classification even runs*.

**Top fixes (all Coolify-friendly):** redact-before-LLM; base-image allowlist + Trivy scan; network segmentation via **Traefik-hostname platform access** (tenant Destinations hold no datastores); strip inbound `X-Auth-*` + fail-closed authz + path canonicalization.

<details>
<summary><b>Full findings → fixes</b> (🟦 Coolify · 🟩 service config · 🟨 kiosk · 🟥 accepted)</summary>

| Finding | Fix | Where |
|---|---|---|
| Kiosk LLM egress of tenant code/secrets | redact before LLM; route Kiosk calls via LiteLLM (ZDR) | 🟨+🟩 |
| Build-time RCE | base-image allowlist + Trivy scan; full sandbox deferred | 🟨+🟥 |
| Cross-tenant DB | per-tenant DB creds; RLS (`FORCE`) for intra-app; internal net | 🟩 |
| Kiosk master tokens | least-priv token; behind oauth2-proxy; isolate build workers; quotas | 🟦+🟨 |
| Lateral movement | Destination-per-tenant; platform svcs via Traefik hostnames; default-deny egress | 🟦+🟩 |
| Webhooks/machine clients blocked or over-exposed | manifest public-path allowlist + signed-webhook/machine-token | 🟨 |
| Server actions defeat path RBAC | deterministic-signal → default coarse gate; LLM only proposes finer | 🟨 |
| LLM detection silent false-negative | structural defaults (egress boundary, default-coarse) + eval harness w/ recall targets | 🟨 |
| Header spoofing | strip inbound `X-Auth-*`; ports unpublished | 🟦 |
| authz fail-open / path bypass | fail-closed; canonicalize; cache invalidation | 🟨 |
| Metadata-PG SPOF | authz local cache w/ staleness; PG HA; replicate proxy/authz | 🟩 |
| Over-permissive manifest | most-restrictive default; explicit opt-in; loud "public" | 🟨 |
| Customer data → OpenRouter | provider filtering + ZDR; policy: not hosted here | 🟩+🟥 |
| Coolify state loss | state backup + restore runbook + host-as-code | 🟩 |
| Disk exhaustion | image GC/prune + volume quotas + alerting | 🟦+🟩 |
| Zip-slip / bomb · secrets in image | safe extract; block hard-coded secret; no build args | 🟨 |

**Accepted/contained (no gVisor):** container escape (contained by segmentation) · build-RCE residual · customer-data apps off-tier (policy).
</details>

---

## 10. Open items

| Item | Status |
|---|---|
| Coolify Destination **creation** via API | assignment confirmed + immutable; creation path = spike (pool/register/MCP) |
| Coolify custom-label persistence on pinned version | verify |
| Tenant-scoped LLM cache hook | verify (two-tenant identical-prompt test) |
| Metadata-PG HA + authz cache staleness bounds | design + test |
| Auth smoke test (unauth ≠ 200) & webhook-path bypass test | add when built |
| Server-action / single-endpoint detection | deterministic detector → default-coarse gate |
| Detector eval harness + recall targets | build the labeled + red-team corpus; calibrate confidence |
| Fine-grained row/operation-level RBAC | app-cooperative (identity headers) or RLS |
| gVisor / build sandbox | excluded for simplicity → contained risks; reopen for adversarial/internet-facing |

---

## Glossary

- **Kiosk** — user-facing control plane; creators' only surface; drives Coolify's API.
- **Coolify** — open-source PaaS used as engine + **admin/ops console** for operators.
- **Destination** — a Coolify Docker-network deployment target; one per tenant = network isolation.
- **Manifest** — confirmed per-app record: routes, role→path rules, **public/webhook paths**, port, secrets, cron.
- **Reconciler** — background control loop diffing desired (metadata) vs actual (Coolify), GC-ing orphans.
- **Machine token** — platform-issued credential for non-browser service-to-service calls.
- **db-per-tenant** — one database per tenant on a shared Postgres cluster (cheap, mainstream, RLS-native).
- **forward-auth** — proxy middleware that authN/authZ a request before it reaches the app.
- **Virtual key** — per-tenant, budgeted LiteLLM key mapped to the OpenRouter master key.
- **RLS** — Postgres Row-Level Security; row-level access enforced by the database.
</content>
