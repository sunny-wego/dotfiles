# Internal App Platform — Design & Plan

> **One-line:** a self-serve platform where non-engineers **drop a ZIP and get a hosted internal app** — with database, cron, Google login, per-app RBAC, and optional LLM access — built on **Coolify** as the engine, running the same on a laptop (Colima) and an internal EC2 box.

**Status:** design doc + **implemented M1 & Lean v1** on **Coolify** (the engine — the Kiosk drives it via REST; see [`coolify/README.md`](./coolify/README.md)); pipeline/security detail in [`M1.md`](./M1.md) / [`v1.md`](./v1.md), set-up in [`SETUP.md`](./SETUP.md) · **Trust model:** trusted-internal, accident-hardened · **Purpose:** alignment, stakeholder buy-in, discovery.

**Two planes (core principle):** **Creators (non-engineers) only ever use the Kiosk** (user-facing). **Operators (engineers) use the Coolify dashboard as the admin/ops console.** The Kiosk drives Coolify through its API on the creator's behalf; nobody non-technical touches Coolify.

**Scope commitment:** the actual v1 commitment is the **lean core + trigger table in the next section** — *not* all of §2–6. §2–6 are the **target architecture** (where each piece goes when demand pulls it in); v1 ships only what is the product itself or protects against irreversible loss, and defers the rest to documented triggers.

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

## Scope — lean v1, target architecture, triggers

**The commitment is the lean v1 below + the trigger table — not all of §2–6.** §2–6 describe the *target architecture* (where each piece goes when demand pulls it in). v1 keeps only what is *the product itself* or *protects against irreversible loss*, and converts the rest from a Day-0 commitment into a documented trigger.

**Irreducible core — what we actually want:**
1. **ZIP → hosted app with no engineer** — the LLM Dockerfile + build-verify-heal loop (this *is* the product).
2. **Google login + "only the right people can open this app."**
3. **A database, secrets, cron, and an LLM key per app.**
4. **Can't leak by accident, can't lose data** — private by default, egress-deny, backups.

**Lean v1 — one box, ~8 containers:**
```
coolify (traefik → oauth2-proxy → tenant apps + per-app Postgres)
kiosk (UI + orchestrator + build worker + audit)
postgres (kiosk metadata only; tenant DBs are Coolify-managed resources)
litellm · registry · uptime-kuma
```
Deliberate simplifications (still **fail-closed** — coarser, not weaker):
- **Access = whole-app, not per-route.** oauth2-proxy per app with an allow-list (emails or a Google Group) — "who can open this app," full stop. Deletes the authz service, manifest role rules, route detection, role proposal, and the server-action hybrid *entirely*. Most internal tools need exactly "my team can see this."
- **Data governance = policy + attestation + egress-deny, no scanning.** "No customer/PNR data on this tier" as a rule + a deploy checkbox + default-deny egress (the load-bearing *structural* boundary stays). Drops the classification LLM pass, detector eval harness, and red-team corpus.
- **Backups = Coolify native scheduled backups, one per tenant database (daily, with retention; optional S3).** RPO of a day — honest and adequate for internal tools; a scheduled dump, not WAL shipping. (Since the deploy engine owns each DB resource, it also owns its backups + restore — the kiosk runs no `pg_dump`.)
- **Observability = Kiosk-surfaced logs + Uptime-Kuma + a disk alert.** Nothing else.
- **Keep the cheap hygiene** (nearly free, prevents irreversible mistakes): safe ZIP extraction · secret redaction before any LLM call · base-image allowlist · apps private by default · an append-only audit table · the Slack escalation channel. **And keep the provisioning saga idempotent/re-runnable**, so a partial failure is recoverable by hand (the reconciler just automates this later).

**Deferred → trigger:**
| Deferred | Bring it back when… |
|---|---|
| Per-route RBAC (authz service, manifest roles, server-action rule) | an app needs Viewer/Editor/Admin (**ADM Tracker** is the known trigger) |
| Webhook / machine-token paths | the first app must receive a webhook (an additive manifest field) |
| Classification scanning + eval harness | you decide to host customer-data apps on this tier at all |
| Preview-before-promote | a bad-but-healthy update first burns someone (rollback covers v1) |
| Email relay, object-storage buckets | the first app that needs them |
| Lifecycle sleep/archive, dup detection, reconciler auto-GC | the catalog exceeds ~15–20 apps (until then: an owner field + a monthly "orphans" report) |
| Grafana/Loki/GlitchTip | Kiosk logs demonstrably stop being enough |
| WAL minute-level backup | losing a day of an app's data actually hurts |
| Multi-server, replica-HA, graduation | a workload actually saturates the box |

**Why deferral is safe, not debt:** every item is *additive*, because the core keeps the two seams that matter — **everything routes through Traefik + oauth2-proxy**, and **every app is an image from a Dockerfile**. Nothing above requires re-architecting to add later.

**Consequence:** the build order collapses to ~2 milestones (walking skeleton → lean v1 → **Pilot 1: Leaderboard**). **Pilot 2 (ADM Tracker) intentionally sits *behind* the per-route-RBAC + classification triggers — it is not a v1 expectation.** Roughly one engineer-month, honestly **part-time-carryable** until adoption proves out — which *un-blocks* (rather than forces) the Path B vs C decision.

> **Do not cut the heal-loop quality bar.** ZIP→app success rate is the entire value proposition; the one place where *under*-engineering kills the project. Spend the saved effort there.

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
     └▶ MACHINE clients → allowlisted public/webhook path (app verifies provider sig)
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
   LiteLLM ──▶ OpenRouter (ZDR)   Per-tenant Postgres (Coolify-managed resource
   (also: the Kiosk's OWN          per app, native backups; DEFAULT)
    LLM calls, redacted)          Metadata Postgres (kiosk state; own backup)
   Email relay ──▶ SES / Postal   Coolify S3 storage (optional off-box backups)
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

> *v1 ships the lean subset (see Scope); the rest of this list is target capability, each pulled in by its trigger.*

<details>
<summary><b>Feature → component map</b></summary>

| Feature | Delivered by |
|---|---|
| Host Node/Python app | generated Dockerfile → image → Coolify deploy-from-image |
| Database | **Coolify-managed Postgres, one resource per tenant (default)** / libSQL (light option) + injected `DATABASE_URL` (from Coolify's `internal_db_url`) |
| Cron | Coolify Scheduled Task (overlap-guard, timezone, retry, creator alerts) |
| Google login | oauth2-proxy (company domain only) |
| Machine/webhook access | manifest public-path allowlist + app-verified provider signature / machine token |
| Outbound egress | manifest **domain allowlist** (default-deny); detection proposes from SDKs/env, creator confirms |
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

**Postgres, one database per tenant** is the default because it buys the mainstream ecosystem, **RLS without a second engine**, and a **uniform backup story** — while staying cheap. libSQL is the lightweight option for tiny/edge cases, not the default.

**v1 implements this as a Coolify-managed Postgres *resource* per app** rather than a database on one kiosk-administered cluster. Since Coolify is the deploy engine and already runs, monitors, backs up and resource-limits database resources, letting it own each tenant DB removes the kiosk-side admin superuser, shared-cluster guard loop, and `pg_dump`/restore code — the engine owns lifecycle + backups, the kiosk owns identity + wiring. The trade-off (accepted): one container per app instead of a database on a shared cluster (less dense), and per-tenant restore granularity comes from Coolify's per-DB backups rather than a custom kiosk drill. Isolation and per-app resource limits come for free with the dedicated resource, so the shared-cluster guards (connection limits, statement timeouts, size quotas) are no longer needed.
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
| Per-app CPU/mem limits + **per-tenant Postgres resources** | **DB credential generation + `DATABASE_URL` wiring + RLS** (Coolify creates the resource; the kiosk scopes + injects it) |
| Multi-server placement | **Destination-per-tenant** orchestration |
| Scheduled DB backups + **its own state backup** | **native per-tenant DB backups (Coolify) + Coolify-state/metadata restore runbook + host-as-code** |
| Deploy notifications | **Shared email relay**, **creator-facing observability**, **escalation queue** |
| **Admin dashboard (operators)** | **Governance** — data classification, lifecycle/sprawl, actor-attributed audit, **reconciler** |

**Rule:** native Coolify = admin/infra plane + deploy engine; our extensions = the **user plane (Kiosk)** + **multi-tenant governance**.

---

## 4. The Kiosk — design, deployment, monitoring

The Kiosk is the **user plane** — creators' only surface, and the brain that turns a ZIP into a governed, hosted app.

> **v1 Kiosk = 4 components:** UI · orchestrator (idempotent saga) · build worker · audit. The reconciler, lifecycle, and detection-heavy pieces below are target architecture pulled in by trigger.

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
- **Operator-facing:** Coolify failure notifications + **Uptime-Kuma** (uptime) + **Grafana/Loki** (fleet metrics/logs) + **GlitchTip** (app errors) + **disk alerting**. **Logs are secret-redacted before aggregation** — an app that accidentally logs a token must not persist it in Loki/GlitchTip.

---

## 5. User journey

> **v1 access is whole-app** (oauth2-proxy allow-list per app — "who can open this"). The per-route RBAC detailed below (roles, the server-action hybrid) is **target architecture**, triggered when an app needs Viewer/Editor/Admin — e.g. ADM Tracker. The journey below shows the full target flow.

Canonical hard case: a **Next.js app using every feature** — staff log in with Google, see role-gated pages, read/write their org's data, ask an LLM to summarize it, get a nightly email report, and **receive Stripe webhooks**.

**Phase 1 — Create.** Sign in (Google) → name → **drop ZIP** → Kiosk **redacts secrets**, detects Next.js + LLM + DB, runs **classification** → hardened **Dockerfile** via build-verify-heal → plain-English summary + toggles (LLM-proposed roles; detected **webhook/machine paths**; and **detected outbound domains to allowlist** — a Stripe SDK ⇒ `api.stripe.com`) → **Deploy**.

**Phase 2 — Provision (saga).** Redact → build + scan → push → create per-tenant **Postgres database** → mint LLM key → bucket + SMTP creds → set env/domain/limits/cron via Coolify API → attach auth chain (+ public-path allowlist + **outbound egress allowlist**) → deploy in the **Destination** → enable backup → record owner + manifest + audit.

**Phase 3 — Invite & roles.** Invite staff, assign Admin/Editor/Viewer. Set default visibility (invite-only vs all-staff). No code.

**Phase 4 — Use it.**
```
BROWSER  → Traefik → oauth2-proxy (company Google) → authz (role/route, default-deny) → app
MACHINE  → Traefik → allowlisted /webhooks/stripe (path allowlist; app verifies sig) ─→ app
```
A Viewer hitting `/admin` (a GET navigation) is blocked before the app sees it. **And because server-action writes would otherwise be Admin-only, at confirm time the creator was flagged and moved mutations to `/api/*` — so Editors can write and Viewers can't.** Stripe's webhook reaches the app because its path is allowlisted; **the app verifies the Stripe signature** (the platform allowlists the path and can verify a few known providers as a bonus).

**Phase 5 — Scheduled work.** 09:00 Coolify Scheduled Task runs the report (overlap-guarded, timezone-declared, retries, **failure alerts the creator**), sends email via the relay, exits.

**Phase 6 — Maintain.** Update = new ZIP → rebuild (Dockerfile reused unless detection changed) → **preview URL → promote** → health-checked swap. **Preview is isolated:** it boots against a **throwaway copy of the tenant DB** (`pg_dump | pg_restore` or a snapshot — a `CREATE DATABASE … TEMPLATE` copy is refused while the live app holds connections; both are fast at internal-tool sizes), with **cron disabled and email in redirect/sandbox mode**, so a startup migration or side effect can't touch prod. **Promote runs migrations against live for the first time** — so preview validates the migration against a *copy*, and minor data-drift between preview and promote is an accepted residual at this scale. **One more residual, stated honestly:** preview still inherits the live **outbound allowlist + secrets**, so it *can* call real external APIs (real Stripe, real LLM spend) and writes to the live object bucket unless given a scratch bucket — acceptable at this scale, but scoped here rather than implied away. Rollback = redeploy a prior image. Manage secrets/logs/users/cron; offboard (export → tear down, reconciler GCs remnants).

<details>
<summary><b>RBAC precision — what it does and doesn't guarantee</b></summary>

- **Guarantees route + method** (path/method → role, default-deny), enforced at the proxy with zero app code. A missed route is denied.
- **Sub-route operations get a hybrid rule.** Server actions, GraphQL (`POST /graphql`), websockets, SSE **multiplex many operations on one route**. **Server-action invocations are deterministically identifiable** (`POST` + `Next-Action` header / action payload), so: normal `GET` navigation and `/api/*` keep **per-path/method role rules** (*a Viewer is still blocked from `/admin`*), while **any action-marked request is held to the highest-privilege role the app defines** — since we can't tell one action from another, all are held to the strictest bar. (To be precise: "strictest" = *highest-privilege role required*, i.e. **Admin-only**, not "any signed-in user.")
- **Consequence — stated, not discovered.** That makes *every* server-action write Admin-only, so in a write-heavy app-router app **Editors can't edit**. At confirm time, detection **flags "server actions + multiple roles"** and offers the off-ramp: **(a)** move mutations to `/api/*` routes (per-path rules distinguish them) · **(b)** cooperate via identity headers for in-app checks · **(c)** accept Admin-only actions. The creator chooses with eyes open — it's never a surprise when Editors' buttons stop working.
- **Opaque single-endpoint multiplexers** (GraphQL, websockets) have no marker → coarse whole-app gate. Detection is a deterministic framework signal; a miss yields the safer behavior.
- **Row-level** and **operation-level** are the same class: fine granularity below the route needs app cooperation (identity headers) or Postgres RLS.
</details>

<details>
<summary><b>Detection reliability — the LLM proposes, structure guarantees</b></summary>

Safety must not rest on LLM recall — a **silent false negative** (missed customer data, undetected server actions) is the dangerous failure. So:
- **Structural defaults hold even at zero recall:** default-deny routes · default-coarse/hybrid RBAC for multiplexing frameworks · the egress boundary for customer data. The LLM only *proposes*; the guarantee is the default. (Zero-recall check: if fingerprinting misses, an action-marked POST lands on a page route whose manifest entry is GET-only → default-deny catches it.)
- **Safety-critical defaults key off deterministic signals** (static route parse, framework fingerprint, high-precision format regex, egress grants) — the LLM augments, never decides the default.
- **Fail toward restrictive:** union of independent detectors; any hit escalates/restricts.
- **Detector eval harness (with the classification tier, when triggered):** a labeled + **red-team** fixture corpus with measured **recall/precision targets**, regression-tested on every model/prompt change; detectors are treated as safety-critical code with coverage, and **confidence is calibrated** so low-confidence detections route to the human queue.
- **Net:** LLM recall affects *friction* (how often a human is pulled in, how coarse the default), **not safety**.
</details>

<details>
<summary><b>Machine clients & webhooks (non-browser)</b></summary>

oauth2-proxy is a browser flow — Stripe/Slack/inbound-email/external-cron/CLI can't complete it. So the manifest carries a **public/webhook path allowlist** (with the same loud "public" warning). **Signature verification is normally the app's job** — Stripe/Slack use provider-specific HMAC schemes their SDKs verify; the platform **allowlists the path** and can verify a **few known providers** as a bonus (the manifest warning says so). Service-to-service calls use a **platform-issued machine token**. Detection proposes the paths *and a matching outbound-domain allowlist* from SDK/env signals; the creator confirms.

**Outbound egress is the same mechanism.** Default-deny egress means the STRIPE_KEY app's call to `api.stripe.com` fails at runtime unless allowlisted — so the outbound domain allowlist is a first-class, creator-confirmed manifest section. It's *also* the egress-grant the classification control relies on: granting an **internal customer-data system** (prod DB, PNR API) is what routes an app to the hardened tier.
</details>

---

## 6. Operations (target architecture — pulled by trigger)

> **v1 keeps only:** Coolify native scheduled backups (one per tenant DB) + a backup of the kiosk's metadata DB · Kiosk-surfaced logs + Uptime-Kuma + a disk alert · the cheap hygiene (safe extract, redaction, allowlist, private-by-default, audit table, Slack escalation) · an owner field + monthly orphans report. Everything else below arrives on its trigger (see Scope).

<details>
<summary><b>Backup & DR</b> — tenant data AND platform state</summary>

- **Tenant DBs:** each is a Coolify-managed Postgres resource with its own **native scheduled backup** (daily + retention, optional S3). Per-tenant restore is native — restore that one database's backup from the Coolify dashboard. Later hardening: WAL/PITR per resource. (libSQL apps: bottomless S3 replication.)
- **Coolify's own state + kiosk metadata** (domains, envs, tasks, destinations, and the apps/access/secrets/cron/audit tables = the deployment state): **data-dir backup + scheduled backup of both Postgres DBs + a restore-tested runbook + host provisioning as code.** Retained ZIPs+Dockerfiles only reproduce apps if the engine that deploys them does too.
- RPO ≈ a day (Coolify daily scheduled backup); RTO = restore engine + data. **A restore drill — restore a tenant DB backup from the Coolify dashboard — measures mean-restore-time.**
</details>

<details>
<summary><b>Availability — no fleet-wide SPOF</b></summary>

- **Metadata Postgres** is in the hot path (authz reads manifests per request). So authz **serves from a local cache with explicit staleness bounds** (invalidated on role change) — "Kiosk DB blip" must not mean "every app down."
- **Honest HA:** on a single EC2 box everything shares fate with the host — so at first the real mitigations are the **authz cache + fast restore**; genuine Postgres **HA arrives with the second server** (don't claim HA the single-box topology can't deliver).
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
- **Roles stay fresh:** brokered to **Google Groups** (or periodic revalidation against the directory) so membership tracks the org chart. **Session revocation:** a **short oauth2-proxy session TTL (or directory re-validation on refresh)** so a disabled Google account loses access in minutes, not at cookie expiry.
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

Default single image; genuine multi-service → **multiple linked Coolify apps in one project**; permit **compose** when only app-level auth is needed. **Build UX:** queue + worker pool; on heal-failure → **plain-English diagnosis + suggested fix + escalate + save-as-draft** (never a raw stack trace). The heal loop is **capped** — a max iteration count *and* a **per-provision token budget** across all Kiosk LLM calls (detection, generation, heal, classification, probes) — so a stuck build can't burn unbounded inference (denial-of-wallet guard on the platform's *own* LLM spend, distinct from tenant budgets). Exceeding the cap escalates to the human queue.
</details>

---

## 7. Delivery — sequencing, pilots, success metrics

**The v1 commitment is milestones 1–2** (→ Pilot 1) — roughly **one engineer-month**. Milestones 3–6 are the *target* sequence, each **pulled in by a trigger** (see Scope), not committed up front. Coolify removes ~60–70% of plumbing; the value and the risk both live in the **build/heal pipeline** (M1), which is why that's the one place not to under-invest.

**Build order (dependency edges → each milestone is shippable):**
1. **Walking skeleton:** ZIP → LLM Dockerfile (redacted→LiteLLM) → build+scan → deploy behind oauth2-proxy. Proves the core loop + two-plane. **Includes a minimal escalation surface (Slack + a table).**
2. **Lean v1:** + per-tenant Coolify-managed Postgres + secret store + **whole-app oauth2-proxy allow-list** + cron + LLM key + Coolify scheduled backups + Uptime-Kuma + disk alert. → **Pilot 1: Leaderboard.** *This is the v1 commitment.*

*Triggered afterward (target sequence, not committed):*
3. **+ Per-route RBAC & machine access** — authz service + manifest roles + server-action hybrid + webhook/machine-token. *(Trigger: an app needs Viewer/Editor/Admin — e.g. Pilot 2, ADM Tracker.)*
4. **+ Data-classification tier** — scanning + eval harness + hardened-tier gate. *(Trigger: hosting customer-data apps.)*
5. **+ Ops depth** — WAL backups/DR drill, authz-cache/HA, reconciler auto-GC, lifecycle, Grafana/Loki. *(Trigger: fleet size / data value.)*
6. **+ Polish** — email, storage, preview-before-promote, rebuild cadence, escalation queue UI. *(Trigger: first app that needs each.)*

### Milestone breakdown (implementation-ready)

*Committed now — build in order:*

**M1 · Walking skeleton** — *depends on: nothing.*
- **Build:** one-box bootstrap (Coolify installer + host-as-code, or `docker compose`) · oauth2-proxy → Google, company-domain-restricted · kiosk skeleton (upload → safe-unzip → detect → LLM Dockerfile gen + **build-verify-heal** + Trivy + push → Coolify app-from-image) · Traefik routing + TLS · LiteLLM up, kiosk's own calls redacted→LiteLLM · Slack escalation + append-only audit table.
- **Done when:** a trivial **Node** ZIP *and* a **Python** ZIP each go drop → live URL behind Google login, Dockerfile LLM-generated, the heal loop recovering ≥1 induced failure; a non-company Google account is denied.

**v1 · Lean v1** *(the commitment)* — *depends on: M1.*
- **Build:** per-tenant **Coolify-managed Postgres** + injected `DATABASE_URL` · **whole-app allow-list** per app (emails / Google Group) · secrets via Coolify env · **cron** (Scheduled Task) · per-tenant **LLM key** · **egress-deny + outbound allowlist** · **Coolify native scheduled backups** (per tenant DB + kiosk metadata) · Kiosk logs/health + Uptime-Kuma + disk alert · owner field + basic catalog.
- **Done when:** **Pilot 1 (Leaderboard)** runs on-platform doing what it did on Vercel, self-served end-to-end by a non-engineer; an unauthorized user is denied; a **restore-from-backup drill passes** (restore a tenant DB backup from Coolify); egress to a non-allowlisted host is blocked.

*Triggered later — author the Definition of Done when the trigger fires (don't pre-plan):* **M3** per-route RBAC + machine access · **M4** classification tier · **M5** ops depth · **M6** polish. Build tasks are sketched in the Scope table + the target sequence above; each becomes a detailed milestone only when its trigger lands.

**Minimal start (one box).** The first footprint is small — one **Colima VM or a small EC2** running **Coolify · oauth2-proxy · the Kiosk · LiteLLM · one Postgres**; that's all M1 needs, and everything else arrives milestone-by-milestone on the *same box*. **Bootstrap:** Coolify's **installer + host-as-code** (`coolify/install.sh`), then `docker compose up` for the shared services the Kiosk drives (see [`coolify/README.md`](./coolify/README.md)) — one VM, one runbook. **Do the dev-auth stub first for local** — it removes the only annoying laptop dependency (Google OAuth + `*.apps.internal` TLS/DNS); a real EC2 with internal DNS drops even that. Growing **one-box → fleet** later is **additive, not a migration**, because apps address the platform through Traefik hostnames + the Dockerfile contract.

**Success metrics:** apps migrated off off-platform hosting · **time-to-first-deploy** (ZIP→live) · **% builds healed without human** · self-serve completion rate (no escalation) · platform uptime · **mean restore time** (from the DR drill).

**Ownership (a sponsor decision, now un-blocked):** the **lean v1 is honestly part-time-carryable** — that's the point of deferring the fleet-scale operational load. So v1 doesn't force the **Path B vs C** question; it lets adoption prove out first. Path C (staffed, on-call, SLA + DR drills) becomes necessary only as the triggered milestones (classification tier, ops depth, multi-server) pull in real operational weight.

---

## 8. Key decisions & rationale

| Decision | Why |
|---|---|
| Coolify as engine (Apache-2.0) | Removes ~60–70% of plumbing; verified no blocker; admin plane for operators |
| Kiosk as user plane | Non-engineers can't use Coolify |
| LLM-generated Dockerfile, **reused across updates** | One reproducible contract; regenerated only on detection change |
| Trusted-internal, accident-hardened | Threat is mistakes → keep blast-radius controls, drop gVisor → Coolify stays simple |
| oauth2-proxy + company Google **+ machine-token/webhook allowlist** | Browser SSO for people; a designed bypass for Stripe/Slack/cron/CLI. Not Clerk/Authelia |
| **Coolify-managed Postgres per tenant (default)**, libSQL optional | Mainstream ORM compatibility for vibe-coded apps + RLS + engine-owned backups/limits; libSQL is the light option |
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
| Server actions defeat path RBAC | hybrid: per-path GET//api + action-marker held to strictest role; coarse only for GraphQL/ws | 🟨 |
| LLM detection silent false-negative | structural defaults (egress boundary, default-coarse) + eval harness w/ recall targets | 🟨 |
| Header spoofing | strip inbound `X-Auth-*`; ports unpublished | 🟦 |
| authz fail-open / path bypass | fail-closed; canonicalize; cache invalidation | 🟨 |
| Metadata-PG SPOF | authz local cache + fast restore; replicate proxy/authz; PG HA at second server | 🟩 |
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
| Auth smoke tests | unauth ≠ 200 · webhook-path bypass · **action-marked POST from a non-admin session ≠ 200** (this enforcement lives in our authz code, not oauth2-proxy) — add when built |
| Machine-token lifecycle | who issues · scope · rotation/revocation — sketch before M3 (the only credential without a lifecycle yet) |
| Server-action / single-endpoint detection | hybrid (per-path + action-marker→strictest role); coarse only for GraphQL/ws |
| Detector eval harness + recall targets | build the labeled + red-team corpus; calibrate confidence |
| Fine-grained row/operation-level RBAC | app-cooperative (identity headers) or RLS |
| gVisor / build sandbox | excluded for simplicity → contained risks; reopen for adversarial/internet-facing |

---

## Glossary

- **Kiosk** — user-facing control plane; creators' only surface; drives Coolify's API.
- **Coolify** — open-source PaaS used as engine + **admin/ops console** for operators.
- **Destination** — a Coolify Docker-network deployment target; one per tenant = network isolation.
- **Manifest** — confirmed per-app record: routes, role→path rules, **public/webhook paths**, **outbound domain allowlist**, port, secrets, cron.
- **Reconciler** — background control loop diffing desired (metadata) vs actual (Coolify), GC-ing orphans.
- **Machine token** — platform-issued credential for non-browser service-to-service calls.
- **db-per-tenant** — one database per tenant (mainstream, RLS-native). v1 realizes this as a Coolify-managed Postgres *resource* per app (engine owns lifecycle + backups) rather than a database on one shared kiosk-run cluster.
- **forward-auth** — proxy middleware that authN/authZ a request before it reaches the app.
- **Virtual key** — per-tenant, budgeted LiteLLM key mapped to the OpenRouter master key.
- **RLS** — Postgres Row-Level Security; row-level access enforced by the database.
