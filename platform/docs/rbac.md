# Per-app RBAC

Status: **planning**. How end-user access control works for each deployed tenant
app — enforced at the proxy, zero app code, fail-closed.

## Two scopes (don't conflate)
| Scope | Who | Where |
|---|---|---|
| Platform RBAC | the **creator** managing their app | kiosk / Coolify dashboard |
| **End-user RBAC** ← this doc | the **people using the deployed app** | proxy in front of the tenant app |

## Why "just use Authelia" isn't enough
Authelia is one shared SSO instance with **static, file-based access-control rules**
that need a **reload/restart** to change. Encoding every tenant app's role→path
rules as Authelia ACL entries means rewriting + restarting Authelia on every
provision — disruptive and non-scaling. So Authelia is the wrong place for *per-app*
authorization.

## Design: split authN from authZ (middleware chain)
Each tenant app gets a **forward-auth middleware chain** attached via Coolify
`custom_labels` (API-confirmed settable):

```
request → [authelia]           → [platform-authz]              → tenant app
          authN + SSO (Google)   per-app authZ (manifest-driven)
          inject Remote-User/     host → manifest rules → user
          Remote-Groups           groups → allow/deny (default-deny)
```

1. **Authelia = authentication only.** Google SSO, session, "logged in?", injects
   `Remote-User` / `Remote-Groups` / `Remote-Email`. One instance, all apps,
   **no per-app config changes.**
2. **`platform-authz` = small manifest-driven authz service** in the chain. Per
   request: resolve **app** (host header) → load its **confirmed manifest**
   (role→path/method rules + default-deny, from metadata DB) → read **user groups**
   (Authelia headers) → **allow/deny**. Manifests cached in memory; a pure,
   **deterministic** lookup (no LLM in the request path — the LLM only *generated*
   the manifest offline). New app = new manifest row, **no Authelia restart**.

## What each app gets
- **Roles** (Admin/Editor/Viewer) — LLM-proposed from the route map, creator-confirmed.
- **Per-path + per-method rules** — e.g. `/admin/*`→Admin; writes→Admin+Editor;
  reads→any member; everything else→**deny**.
- **Membership** — per-app user→role stored in the metadata DB; kiosk invite/assign UI.
- **Default-deny floor** — a route the detector missed stays closed (fail-closed).

## Confirmed vs open
- **Authn + coarse per-app authZ (path/method/role, default-deny):** enforced at the
  proxy, **zero app code**. Middleware attach is API-confirmed (`custom_labels`).
- **Fine-grained (row/field-level, "only my own rows"):** **app-cooperative** — the
  app reads `Remote-Groups` and filters. The one open item (e.g. ADM Tracker). The
  platform provides coarse rules + identity; the app does the row filter.

## Alternative (small fleets)
Generate **Authelia ACL rules per app-domain** and reload Authelia on provision.
Authelia can express domain + path-regex + method + group + default-deny, but you
pay a config-reload per app. Fine for a handful of apps; the authz-service scales
better for a dynamically-provisioned fleet.

## Ties to other docs
- Rules come from the **confirmed manifest** — see `app-contract-and-detection.md`.
- Identity/SSO via Authelia — see `coolify-evaluation.md` (attached via custom labels).
- Enforcement is **deterministic**; the LLM is offline (generates the manifest, not
  per-request decisions).
