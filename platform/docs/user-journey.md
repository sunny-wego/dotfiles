# User journey — a stock Node.js app using ALL features

Status: **planning**. End-to-end walkthrough for the canonical case: a **Next.js**
app (client + backend) that uses **every** capability — database, cron, Google
auth + RBAC, LLM, secrets, custom domain — deployed on the single box (Colima
locally, EC2 remotely) under the adversarial isolation model.

## The app
A Next.js internal tool where staff log in with Google, see role-gated pages,
read/write their org's data, ask an LLM to summarize it, and get a nightly email
report. Its bundle contains: `package.json` (deps incl. `next`, `@libsql/client`,
`openai`), `.env.example` (`STRIPE_KEY`), `app/` routes incl. an `/admin` page.

## Actors
- **Creator** — the non-engineer who built it with LLM help.
- **End users** — staff who use the deployed app (Admin / Editor / Viewer).

---

## Phase 1 — Create (creator, in the kiosk)

1. **Sign in** to the kiosk with Google (Authelia). Lands in their tenant.
2. **New App → name it** (`acme-tool`) → choose source: **drag & drop ZIP**.
3. Upload → the **kiosk** unzips it in a working dir and **detects**:
   - runtime **Node / Next.js**, build `next build`, start `next start`, port `3000`;
   - **LLM app** (imports `openai`);
   - **DB usage** (`@libsql/client`);
   - **required secret name** `STRIPE_KEY` (from `.env.example`) — value not yet known;
   - a hard-coded key in source → flagged for stripping.
4. **Dockerfile generated** (hardened `node-next` template: pinned base, multi-stage,
   non-root, `EXPOSE 3000`) → **build-verify-heal loop** builds it (with a build
   timeout) until the health check passes (app boots and serves).
5. Kiosk shows a **plain-English summary** + toggles, pre-filled from detection:
   - **Database: ON** (detected).
   - **LLM: ON** (detected) → pick tier (e.g. `standard`).
   - **Auth (Google): ON** → LLM proposes roles from the route map: **Admin /
     Editor / Viewer**; `/admin/*` → Admin only, writes → Admin+Editor, rest → all.
   - **Cron: ON** → creator adds “nightly report, 09:00”.
   - **Secrets** → form asks for `STRIPE_KEY`; creator pastes it (masked).
   - **Custom domain** (optional) → `acme.tools.internal`.
6. **Deploy.**

## Phase 2 — Provision (control-plane saga, invisible to creator)

Idempotent, resumable steps (kiosk logic + Coolify API):
1. **Build** the image (build-verify-heal, with a build timeout) → **push to registry**
   (immutable artifact).
2. **DB** — create the tenant's **sqld namespace**; get `DATABASE_URL`.
3. **LLM** — mint a **LiteLLM virtual key** (tier `standard`: budget + rpm/tpm +
   model allowlist + `metadata.tenant_id`).
4. **Secrets** — detect/flag any hard-coded key; collect `STRIPE_KEY`.
5. **Coolify: create app from image** in the tenant's **Destination** (network
   isolation), and set **env** via the API = `DATABASE_URL` + LiteLLM key +
   `STRIPE_KEY` (Coolify's encrypted store).
6. **Coolify: configure** — custom domain, per-app **CPU/memory limits**, a
   **Scheduled Task** (09:00 cron), and **custom Traefik labels** attaching the
   Authelia forward-auth middleware.
7. **Coolify: deploy** (`/applications/{uuid}/start`) → build/run → health-check →
   TLS → routed, gated by Authelia.
8. **Record** — `tenant → app → {namespace, virtual key, domain, roles, manifest}`
   in the metadata Postgres.

Result shown to creator: **live URL + invite link + streaming logs.**

## Phase 3 — Invite & roles (creator)
Creator invites staff by email and assigns **Admin / Editor / Viewer**. No code.

## Phase 4 — End-user runtime
```
staff browser → Coolify Traefik (TLS, host route)
             → authelia (logged in? role allowed on this path?) → inject Remote-User/Groups
             → acme-tool container (Next.js)
                 ├─ reads/writes its OWN sqld namespace (DATABASE_URL)
                 └─ calls the LLM via OPENAI_BASE_URL → litellm (virtual key,
                    per-tenant budget + tenant-scoped cache) → OpenRouter
```
- A **Viewer** hitting `/admin` is blocked by Authelia **before** the app sees it.
- The app can't reach other tenants (its own **Coolify Destination**); can't reach
  IMDS (hop-limit 1); trusts `Remote-*` only from Coolify's Traefik.

## Phase 5 — Scheduled work
At 09:00 the app's **Coolify Scheduled Task** runs the report command inside the
container (same env, same sqld namespace, same LLM virtual key), sends the email,
exits. Run history + logs in Coolify.

## Phase 6 — Maintain (creator)
- **Update**: drop a new ZIP → rebuild → verify (boots/serves) → zero-downtime swap.
- **Rollback**: pick a prior immutable image.
- **Rotate `STRIPE_KEY`**: update value → redeploy.
- **Logs / metrics / cron history / DB browse / user management / custom domain**:
  all in the kiosk.
- **Offboard**: export data → delete the Coolify app + Destination, sqld namespace,
  virtual key (revoked), secrets, domain.

---

## Feature → component map (traceability)
| Feature | Delivered by |
|---|---|
| Host a Node app | generated Dockerfile → image → Coolify deploy-from-image |
| Client + backend | Next.js (fullstack) |
| Database | sqld namespace + injected `DATABASE_URL` |
| Cron | Coolify Scheduled Task |
| Google auth | Authelia |
| End-user RBAC | Authelia forward-auth (role→path) via custom labels, roles proposed by LLM |
| LLM app | LiteLLM virtual key + injected `OPENAI_/ANTHROPIC_` env |
| Secrets | Coolify encrypted env store, injected at deploy |
| Custom domain | Coolify (Traefik + TLS) |
| Isolation (accident-hardened) | per-app limits + Destination-per-tenant + IMDS hop-limit + default-deny RBAC + LLM budgets |
| Parity | same Coolify local (Colima) and EC2; only `.env` differs |
