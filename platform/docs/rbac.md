# Per-app RBAC

Status: **planning**. How end-user access control works for each deployed tenant
app — enforced at the proxy, zero app code, fail-closed.

## Two scopes (don't conflate)
| Scope | Who | Where |
|---|---|---|
| Platform RBAC | the **creator** managing their app | kiosk / Coolify dashboard |
| **End-user RBAC** ← this doc | the **people using the deployed app** | proxy in front of the tenant app |

## Auth tool: oauth2-proxy (NOT Authelia)
Login must use **company Google accounts**. Authelia can't broker Google — it's an
OIDC *provider*, not a *relying party* (verified). So authN uses **oauth2-proxy**,
which logs users in via Google OIDC and restricts to the company domain
(`--email-domain=wego.com` / Google `hd`). Per-app authorization is NOT done by the
auth tool (static rules don't scale per-tenant) — it's a separate service.

## Design: split authN from authZ (middleware chain)
Each tenant app gets a **forward-auth middleware chain** attached via Coolify
`custom_labels` (API-confirmed settable):

```
request → [oauth2-proxy]        → [platform-authz]              → tenant app
          authN via Google        per-app authZ (manifest-driven)
          (@company only), inject  host → manifest rules → user
          X-Auth-Request-Email     → allow/deny (default-deny)
```

1. **oauth2-proxy = authentication only.** Google login (company domain only),
   session, injects `X-Auth-Request-Email` (+ groups if configured). One instance,
   all apps, **no per-app config changes.**
2. **`platform-authz` = small manifest-driven authz service** in the chain. Per
   request: resolve **app** (host header) → load its **confirmed manifest**
   (role→path/method rules + default-deny, from metadata DB) → read **user identity**
   (oauth2-proxy header) → map email→role for this app → **allow/deny**. Manifests
   cached in memory; a pure, **deterministic** lookup (no LLM in the request path —
   the LLM only *generated* the manifest offline). New app = new manifest row.

## What each app gets
- **Roles** (Admin/Editor/Viewer) — LLM-proposed from the route map, creator-confirmed.
- **Per-path + per-method rules** — e.g. `/admin/*`→Admin; writes→Admin+Editor;
  reads→any member; everything else→**deny**.
- **Membership** — per-app user→role stored in the metadata DB; kiosk invite/assign UI.
- **Default-deny floor** — a route the detector missed stays closed (fail-closed).

## Confirmed vs open
- **Authn + coarse per-app authZ (path/method/role, default-deny):** enforced at the
  proxy, **zero app code**. Middleware attach is API-confirmed (`custom_labels`).
- **Fine-grained (row-level, "only my own rows"):** the app must convey *who is
  calling* to the data layer — the one irreducible cooperation. Design below makes
  everything else no-code (e.g. ADM Tracker).

## Row-level — as no-code as possible
Row-level = access control on individual records (vs route/method). The one thing
that can't be zero-code: the app must tell the data layer who's calling, per request.
Everything else is made no-code:

1. **Only where needed.** Most apps are fine with per-tenant isolation + coarse role
   gating (100% no-code). Row-level is opt-in per app.
2. **DB-enforced (Postgres RLS), not app filter code.** The DB returns only the
   caller's rows for a plain `SELECT *`; the app writes no filter logic and can't
   leak other rows even if buggy. (Use **Postgres** for these apps — libSQL/SQLite
   lack RLS.)
3. **Creator declares, doesn't code.** A kiosk toggle "records are private to each
   user" + confirm the LLM-proposed **owner column**. Platform generates + applies
   the RLS policy.
4. **The identity link, no-code-first:**
   - *Zero app code:* injected `DATABASE_URL` points at an **identity-aware data
     gateway** that stamps the request's user into the PG session (`SET LOCAL
     app.user`), so RLS filters automatically.
   - *Near-zero fallback:* an **LLM-generated, creator-confirmed one-liner** (read
     identity header → set session user) for connection-pooling apps. Approved in
     plain English, not hand-written; it's a requested feature, not silent codemod.
5. **Fail-closed:** RLS returns **no rows** when `app.user` is unset — a broken
   identity link leaks nothing (empty), never everything.

**Ceiling:** filter logic is eliminated (DB does it), the creator's part is a
toggle + confirm, and the "who's calling" link is at worst a confirmed one-liner.

## Auth tool alternatives
- **oauth2-proxy** (recommended) — Google login + company-domain restriction +
  forward-auth; lean, exactly fits "just Google login + gate."
- **traefik-forward-auth** — even more minimal (Google + `--domain`).
- **Zitadel / Keycloak** — full self-hosted IdPs that broker Google *and* give
  richer self-serve orgs/user management; adopt if per-tenant org management
  outgrows a flat email→role map. (Clerk is **not** an option — SaaS-only + SDK-
  embedded, breaks the proxy model and residency; see the Clerk discussion.)

## Ties to other docs
- Rules come from the **confirmed manifest** — see `app-contract-and-detection.md`.
- Google login via oauth2-proxy, attached as a forward-auth middleware via Coolify
  custom labels — see `coolify-evaluation.md`.
- Enforcement is **deterministic**; the LLM is offline (generates the manifest, not
  per-request decisions).
