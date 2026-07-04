# Internal App Platform — Design & Plan

> **One-line:** a self-serve platform where non-engineers **drop a ZIP and get a hosted internal app** — with database, cron, Google login, per-app RBAC, and optional LLM access — built on **Coolify** as the engine, running the same on a laptop (Colima) and an internal EC2 box.

**Status:** planning / design (docs only, no implementation yet) · **Trust model:** trusted-internal, accident-hardened · **Purpose of this doc:** alignment, stakeholder buy-in, discovery.

Detailed per-topic decision records live in [`legacy/`](./legacy) — this document supersedes and combines them.

---

## TL;DR (read this first)

People keep vibe-coding useful internal tools (often with an LLM) and hit the same wall: **nowhere proper to run something that has a backend, a database, or per-user access.** This platform removes that wall with a self-serve kiosk on top of Coolify.

| A creator does | The platform does (automatically) |
|---|---|
| Sign in with company Google | Authenticates via oauth2-proxy (company domain only) |
| Name the app, **drop a ZIP** | Detects the stack (Node/Python), generates a hardened **Dockerfile** via LLM, builds + scans the image |
| Flip toggles (DB / Cron / Auth / RBAC / LLM) | Provisions a per-tenant DB, mints a scoped LLM key, wires cron, sets up RBAC roles |
| Paste any API keys, confirm roles | Stores secrets encrypted, deploys via Coolify, assigns a URL + TLS |
| — | Gives back a **live URL + invite link + logs** |

**Everything the creator doesn't do, the platform does.** No infra knowledge required.

---

## 1. Why — the problem & the workloads

Real internal apps people have already built or are trying to ship (what matters is the *shape*, not the app):

| App | Shape / needs |
|---|---|
| AI Literacy Learning Hub | frontend+API, DB, SSO, custom domain |
| ADM Tracker (debit-memo) | DB, **per-user RBAC**, self-deploy, ⚠️ booking/PNR (customer) data |
| AI Engineering Leaderboard | DB, cron, internal-network access |
| hbow agent (Claude Agent SDK) | long-running **agent/container**, process forking |
| Wego Translation Manager | DB, SSO, scaling |
| EnzoBot & self-hosts | a **blessed home** to end off-platform hosting; data governance |

The gap is **structural, not one-off** (e.g. a crisis-time app that stalled because it needed an engineer to deploy). This platform is the blessed path.

**Use cases** (by persona): platform operators define templates & policy; **non-engineer creators** self-serve provision, deploy, invite users, schedule jobs, manage secrets; **end users** log in with Google and see only what their role permits.

---

## 2. What we support

- **Runtimes:** Node.js and Python.
- **App shapes:** static client · fullstack (Next.js, FastAPI/Streamlit, …) · backend API · worker/agent (long-running, forking — a strength of the container model).
- **Add-ons (toggles):** per-tenant Database · Cron · Google auth · per-app RBAC · LLM access.
- **Delivery:** drop a ZIP (or connect a git repo). A **Dockerfile is always the contract** — generated for the creator, never hand-written.

<details>
<summary><b>Feature → component map</b></summary>

| Feature | Delivered by |
|---|---|
| Host a Node/Python app | generated Dockerfile → image → Coolify deploy-from-image |
| Database | libSQL/sqld namespace + injected `DATABASE_URL` |
| Cron | Coolify Scheduled Task |
| Google login | oauth2-proxy (company domain only) |
| End-user RBAC | oauth2-proxy (authN) + manifest-driven authz service (authZ) |
| LLM app | LiteLLM per-tenant virtual key + injected `OPENAI_/ANTHROPIC_` env |
| Secrets | Coolify encrypted env store |
| Custom domain + TLS | Coolify (Traefik) |
| Isolation | per-app limits + Destination-per-tenant + default-deny RBAC + LLM budgets |
</details>

---

## 3. Architecture at a glance

```
┌─ Kiosk (ours) ── ZIP-drop · detect+probe · LLM Dockerfile+heal · build+scan image
│                   · mint LLM key · provision DB · drive Coolify API
├─ Coolify (engine) ── ingress/TLS/domains · deploy-from-image · CRON · env/secrets
│                       · resource limits · rollback · multi-server placement
├─ Platform services (run on Coolify) ── LiteLLM · oauth2-proxy · authz · sqld · Postgres · Redis
└─ Tenant apps ── deployed FROM image · 1 Coolify Destination per tenant · auth mw via labels
```

**Division of labor:** Coolify owns the undifferentiated plumbing (~60–70%); the **kiosk + LLM + RBAC** layer is our differentiator. The kiosk drives Coolify entirely through its **REST API**; we build tenant images ourselves and Coolify deploys them (immutable).

<details>
<summary><b>Component roles</b></summary>

| Component | Role | Ours / Coolify |
|---|---|---|
| **Kiosk** | self-serve UI, detection, LLM Dockerfile gen + heal, drives Coolify API | ours |
| **Coolify** | proxy/TLS, build, lifecycle, cron, env, limits, rollback, multi-server | engine |
| **LiteLLM** | LLM gateway: per-tenant virtual keys, budgets, tenant-scoped cache, one OpenRouter master key | ours (on Coolify) |
| **oauth2-proxy** | authN — Google login restricted to company domain, forward-auth | ours (on Coolify) |
| **authz service** | authZ — per-app role→path/method from the manifest, default-deny | ours (on Coolify) |
| **sqld (libSQL)** | per-tenant DB namespaces (cheap) | ours (on Coolify) |
| **Postgres** | platform metadata (tenant↔app↔db, manifests, roles) + RLS for row-level apps | ours (on Coolify) |
| **Registry** | immutable tenant images | ours |
</details>

---

## 4. How it works — user journey

**Create:** sign in (Google) → name app → **drop ZIP** → kiosk detects stack, generates Dockerfile, runs a **build-verify-heal** loop → shows a plain-English summary + toggles (DB/LLM/Auth/RBAC/Cron) with LLM-proposed roles → **Deploy**.

**Provision (invisible saga):** build+scan image → push to registry → create DB namespace → mint LiteLLM key → set env/domain/limits/cron via Coolify API → attach auth middleware chain via custom labels → deploy in the tenant's Destination → record mapping + manifest.

**Use:** end users hit `Traefik → oauth2-proxy (Google) → authz (role check) → app → its own DB + LLM gateway`. **Maintain:** update = new ZIP → rebuild → health-checked swap; rollback = redeploy prior image.

<details>
<summary><b>Deployments, rollback & the migration caveat</b> (coding-agent detail)</summary>

- **Update:** new ZIP (or git push) → kiosk rebuilds a **new image tag** (`:build-id`) → base-image allowlist + Trivy scan → push → kiosk re-checks the RBAC manifest **delta** → Coolify API points the app at the new tag and does a **health-checked, zero-downtime rollout** (old container keeps serving if health fails).
- **Rollback:** redeploy a **prior immutable image tag** — instant, no rebuild.
- **Config/secret change:** update via Coolify env API → redeploy.
- **DB migrations:** platform does **not** auto-migrate — app runs them on startup or via a Scheduled Task. Asymmetry: image rollback reverts **compute**, not **schema** → forward-fix migrations.
- Updates traverse the **same** build→scan→manifest-recheck→deploy pipeline, so no control is bypassed on update.
</details>

---

## 5. Key decisions & rationale (for buy-in)

| Decision | Why |
|---|---|
| **Coolify as the engine** (Apache-2.0, self-hosted) | Removes ~60–70% of plumbing (ingress, build, cron, lifecycle, env, scaling). Verified: full REST API, per-tenant network isolation via Destinations, deploy-from-image, custom labels. **No blocker.** |
| **Mandated Dockerfile, LLM-generated** | One uniform contract → simple, reproducible, portable hosting. Creator never writes it. |
| **Trust model: trusted-internal, accident-hardened** | Threat is *mistakes*, not malice → keep blast-radius controls, drop expensive anti-malice hardening (gVisor). Standard `runc` → trivial parity, Coolify stays simple. |
| **Auth: oauth2-proxy + company Google** | Yes, users log in with their **company Google account**. Not Clerk (SaaS-only, SDK-shaped, breaks the proxy model + residency). Not Authelia (can't broker Google). |
| **DB: libSQL/sqld namespaces (default)** | ~**50–100× cheaper RAM** than a Postgres instance per tenant. Postgres only for apps needing it (e.g. row-level security). |
| **No source modification (no codemods)** | Detection uses static + LLM-generated **probe scripts** + a confirmed manifest; the creator's code is never rewritten. |
| **RBAC = authN split from authZ** | oauth2-proxy authenticates; a small **manifest-driven authz service** does per-app authorization (dynamic, no per-app config reloads). |

<details>
<summary><b>Per-app RBAC internals</b> (authN/authZ split, middleware chain, row-level)</summary>

**Chain (attached per app via Coolify custom labels):**
```
request → oauth2-proxy (Google, company-only; inject X-Auth-Request-Email)
        → platform-authz (host → manifest rules → email→role → allow/deny; default-deny)
        → app
```
- **Roles** (Admin/Editor/Viewer) LLM-proposed from the route map, creator-confirmed into the **manifest** (source of truth in Postgres). Deterministic lookup — **LLM is offline**, never in the request path.
- **Coarse (path/method/role) = zero app code**, proxy-enforced, fail-closed. A missed route is denied.
- **Row-level ("only my own rows") — as no-code as possible:** opt-in per app; **Postgres RLS** enforces at the DB (no filter code, can't leak even if buggy); creator **declares** ownership (toggle + confirm owner column); identity reaches the DB via an **identity-aware gateway** (zero code) or a confirmed one-liner; **fail-closed** (no rows if user unset). Requires non-owner role + `FORCE ROW LEVEL SECURITY`.
</details>

<details>
<summary><b>Detection & app contract</b> (how RBAC is applied without restricting authoring)</summary>

- **Guarantee = fail-closed default-deny**, not perfect detection — a missed route is denied, not exposed.
- **Multi-signal detection:** static route parsing + **LLM-generated ephemeral probe scripts** run against a throwaway instance + LLM semantic classification, reconciled; low-confidence items flagged for confirmation.
- **Conventions recommended, not mandated** (12-factor, conventional router, read identity headers, no self-auth); non-conformers still deploy with lower auto-confidence. **No codemods.**
- **Confirmed manifest** = source of truth; re-checked as a **delta** on each redeploy.
</details>

<details>
<summary><b>Secrets & LLM specifics</b></summary>

- **Secrets:** detected by name (never value), pasted in the kiosk, stored in **Coolify's encrypted env store**, injected at deploy. Hard-coded keys are **detected + flagged** (not rewritten). Kiosk config keys: `COOLIFY_*`, `REGISTRY_*`, `OPENROUTER_API_KEY`, `LITELLM_MASTER_KEY`.
- **LLM:** one OpenRouter master key lives only in LiteLLM; each tenant gets a **scoped virtual key** (budget + rate limit + model allowlist + `tenant_id`), injected as `OPENAI_/ANTHROPIC_` env so any SDK routes through governance. **Tenant-scoped cache** (verify the namespace hook, else disable on tenant keys). OpenRouter provider-filtering + ZDR for data governance.
</details>

<details>
<summary><b>Scaling & parity</b></summary>

- **More powerful app:** raise per-app CPU/mem limits and/or place it on a **beefier server** in the Coolify fleet (per-resource placement). No replicas needed.
- **Spread load:** add servers to the fleet.
- **Ceiling:** single-app **replica-HA** isn't native until Coolify v5 → that one app graduates to Cloud Run/Fly/K8s (a re-point via the Dockerfile contract).
- **Cheap-DB scale:** more sqld nodes → Turso Cloud. **Parity:** same Coolify on Colima (laptop) and EC2; only config differs.
</details>

---

## 6. Security posture

**Verdict:** secure *for the trusted-internal, accident-hardened model* once the fixes below land — with two "arbitrary code on the shared host" risks **contained, not eliminated** (gVisor excluded to keep Coolify simple), and **customer-data apps kept off this tier by policy.**

**Central tension:** the pipeline feeds **untrusted, LLM-interpreted input** (the ZIP) **into privileged operations** (build). So fixes apply regardless of trusting authors.

**Highest-leverage fixes (do first, all Coolify-friendly):**
1. **Base-image allowlist + Trivy scan** — mitigates the worst hole (build-time RCE).
2. **Network segmentation** — expose LLM gateway + each app's DB as **Traefik hostnames** so tenant Destinations hold no datastores; default-deny egress.
3. **Hardened ingress** — strip inbound `X-Auth-*`, fail-closed authz, path canonicalization.

<details>
<summary><b>Full findings → fixes table</b> (by where the fix lives)</summary>

🟦 Coolify-native · 🟩 config on a service we run · 🟨 kiosk logic · 🟥 accepted/contained

| Finding | Fix | Where |
|---|---|---|
| Build-time RCE (LLM Dockerfile, unsandboxed build) | base-image allowlist + Trivy scan; full sandbox is bespoke (deferred) | 🟨 + 🟥 |
| sqld admin unauth/reachable → cross-tenant DB | admin auth key + per-namespace-scoped tokens + internal net | 🟩 + 🟦 |
| Kiosk holds master tokens | least-priv Coolify token; behind oauth2-proxy; per-user quotas | 🟦 + 🟨 |
| Relaxed egress → lateral movement | Destination-per-tenant; platform svcs via Traefik hostnames; default-deny egress | 🟦 + 🟩 |
| `X-Auth-*` header spoofing | Traefik strips inbound auth headers; ports unpublished | 🟦 |
| authz fail-open / path bypass / stale | fail-closed; canonicalize paths; invalidate cache on role change | 🟨 |
| Postgres RLS owner bypass | non-owner role + `FORCE ROW LEVEL SECURITY`; deny when unset | 🟨 |
| Over-permissive manifest (rubber-stamp) | most-restrictive default; explicit opt-in; loud "public" warning | 🟨 |
| Cross-tenant LLM cache leak | verify namespace hook (two-tenant test); else disable tenant cache | 🟩 |
| Customer data → OpenRouter / wrong tier | provider filtering + ZDR; **policy: not hosted here** | 🟩 + 🟥 |
| Zip-slip / zip-bomb | safe extract (reject `../`, cap size/ratio/count) | 🟨 |
| Secrets blast radius | least-priv token; block deploy on hard-coded secret; no build args | 🟦 + 🟨 |
| Probe scripts mutate/leak | disposable verify instance + throwaway DB | 🟨 |

**Nothing needs new infrastructure** — Coolify features, config on services we already run, or kiosk logic.
</details>

<details>
<summary><b>Accepted / contained risks</b></summary>

- **Container escape** (shared kernel, no gVisor) → contained by network segmentation; eliminate only with gVisor (reopens the Coolify-simplicity trade).
- **Build-time RCE on the build host** → mitigated by allowlist + scan; same class as escape.
- **Customer/regulated-data apps** (PNR) → **not hosted on this tier** (policy); kiosk flags & blocks/escalates. They stay off-platform or move to a hardened tier.
- **Single-box availability** → mitigated by snapshots + fast declarative rebuild.
</details>

---

## 7. Open items & decisions needed

| Item | Status |
|---|---|
| Custom Traefik labels settable via API (RBAC attach) | ✅ confirmed (`custom_labels`) — verify persistence on the pinned version |
| Creating a Coolify **Destination per tenant** via API | ⚠️ assignment confirmed + immutable; **creation path** needs a spike (pre-create pool / register network / MCP client) |
| Tenant-scoped LLM **cache** hook | ⚠️ verify with two-tenant identical-prompt test |
| **Auth smoke test** (unauth request must not 200) | to add when built |
| **Fine-grained row-level** RBAC | designed as-no-code-as-possible; the one app-cooperative edge |
| **gVisor / build sandbox** | excluded for simplicity → the two contained risks; reopen only for adversarial/customer-data/internet-facing apps |
| **Customer-data policy** | decided: not on this tier |

---

## Glossary

- **Kiosk** — the self-serve control-plane app creators use; drives Coolify's API.
- **Coolify** — open-source PaaS used as the deployment engine.
- **Destination** — a Coolify Docker-network deployment target; one per tenant = network isolation.
- **Manifest** — the confirmed per-app record of routes, role→path rules, port, secrets, cron.
- **forward-auth** — a proxy middleware that authenticates/authorizes a request before it reaches the app (zero app code).
- **Virtual key** — a per-tenant, budgeted LiteLLM key mapped to the OpenRouter master key.
- **RLS** — Postgres Row-Level Security; row-level access enforced by the database.
