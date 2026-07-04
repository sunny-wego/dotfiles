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
3. Upload → stored in **MinIO**. Control-plane unzips in a sandbox and **detects**:
   - runtime **Node / Next.js**, build `next build`, start `next start`, port `3000`;
   - **LLM app** (imports `openai`);
   - **DB usage** (`@libsql/client`);
   - **required secret name** `STRIPE_KEY` (from `.env.example`) — value not yet known;
   - a hard-coded key in source → flagged for stripping.
4. **Dockerfile generated** (hardened `node-next` template: pinned base, multi-stage,
   non-root, `EXPOSE 3000`) → **build-verify-heal loop** builds it in the sandboxed
   rootless builder until the health check passes **under `runsc`** (compat proven).
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

Idempotent, resumable steps:
1. **Build** image via sandboxed rootless BuildKit; push to local registry.
2. **DB** — create the tenant's **sqld namespace**; get `DATABASE_URL` + token.
3. **LLM** — mint a **LiteLLM virtual key** (tier `standard`: budget + rpm/tpm +
   model allowlist + `metadata.tenant_id`); build `OPENAI_/ANTHROPIC_` env.
4. **Secrets** — `sanitizeHardcodedKeys` strips the hard-coded key; `STRIPE_KEY`
   is **envelope-encrypted** into Postgres (KEK via `age` locally / `kms` on EC2).
5. **Assemble container env** = platform-injected (`DATABASE_URL`,
   `OPENAI_BASE_URL`, virtual key) + decrypted creator secrets (`STRIPE_KEY`).
6. **Network** — create a per-tenant Docker network; multi-home `litellm` + `sqld`
   onto it (no other tenant, no datastores).
7. **Launch** with the sandbox profile:
   - `--runtime=runsc` (`$TENANT_RUNTIME`), `--cpus/--memory/--pids-limit`,
     `--cap-drop=ALL`, `--security-opt=no-new-privileges`, read-only rootfs +
     tmpfs, `--env-file` (tmpfs), **no published ports**;
   - Traefik labels → `Host(acme.tools.internal)` + `authelia@docker` middleware;
   - Ofelia label → the 09:00 cron job.
8. **Verify** — boot/health-check under `runsc` (compat confirmed).
9. **Route** — Traefik auto-discovers the labels; issues TLS; Authelia gates it.
10. **Record** — `tenant → app → {namespace, virtual key, encrypted secrets,
    domain, roles}` persisted in Postgres.

Result shown to creator: **live URL + invite link + streaming logs.**

## Phase 3 — Invite & roles (creator)
Creator invites staff by email and assigns **Admin / Editor / Viewer**. No code.

## Phase 4 — End-user runtime
```
staff browser → traefik (TLS, host route)
             → authelia (logged in? role allowed on this path?) → inject Remote-User/Groups
             → acme-tool container (Next.js)
                 ├─ reads/writes its OWN sqld namespace (DATABASE_URL)
                 └─ calls the LLM via OPENAI_BASE_URL → litellm (virtual key,
                    per-tenant budget + tenant-scoped cache) → OpenRouter
```
- A **Viewer** hitting `/admin` is blocked by Authelia **before** the app sees it.
- The app can't reach other tenants or datastores (per-tenant network); can't hit
  IMDS or internal IPs (nftables); trusts `Remote-*` only from Traefik.

## Phase 5 — Scheduled work
At 09:00 **Ofelia** launches the report job as a container with the **same env +
same sandbox profile + same sqld namespace + same LLM virtual key**, sends the
email via the configured secret, exits.

## Phase 6 — Maintain (creator)
- **Update**: drop a new ZIP → rebuild → verify under `runsc` → zero-downtime swap.
- **Rollback**: pick a prior immutable image.
- **Rotate `STRIPE_KEY`**: update value → redeploy.
- **Logs / metrics / cron history / DB browse / user management / custom domain**:
  all in the kiosk.
- **Offboard**: export data → tear down container, sqld namespace, virtual key
  (revoked), secrets, network, domain.

---

## Feature → component map (traceability)
| Feature | Delivered by |
|---|---|
| Host a Node app | Dockerfile (generated) + Docker + Traefik |
| Client + backend | Next.js (fullstack) |
| Database | sqld namespace + injected `DATABASE_URL` |
| Cron | Ofelia job (same env/sandbox) |
| Google auth | Authelia |
| End-user RBAC | Authelia forward-auth (role→path), roles proposed by LLM |
| LLM app | LiteLLM virtual key + injected `OPENAI_/ANTHROPIC_` env |
| Secrets | envelope-encrypted in Postgres, injected as env at launch |
| Custom domain | Traefik + TLS |
| Isolation | sandbox profile (`runsc`, limits, caps) + net-per-tenant + nftables |
| Parity | same compose local (Colima+`runsc`) and EC2; only `.env` differs |
