# App secrets & env — define, store, fetch

Status: **planning**. How environment variables and secrets are declared, stored,
and delivered to tenant apps. Default is the least-over-engineered path; the
graduation trigger to a fetch-based model is noted at the end.

## Two kinds of value

| Kind | Examples | Provided by |
|---|---|---|
| **Platform-injected** | `DATABASE_URL` (sqld namespace), `OPENAI_/ANTHROPIC_BASE_URL` + virtual key | Automatic — creator never sees these |
| **Creator-provided** | third-party keys the app needs (e.g. `STRIPE_KEY`) | Creator, via the kiosk form |

## Define
Reuse the ZIP analysis done for Dockerfile generation to detect required env
**names** (never values): from `.env.example` and `process.env.X` / `os.environ`
references. The kiosk shows a masked form for the creator-provided ones.
`sanitizeHardcodedKeys` (see `control-plane/src/provisionLlmApp.ts`) strips any
key the creator hard-coded and re-homes it here.

**Hard rule:** secrets are **runtime-only, never build args** (build `ARG`s bake
into image layers). Only non-secret config may be a build arg.

## Store
Default: **Coolify's own encrypted env/secret store**, set per app via the Coolify
API. Coolify encrypts env values at rest, supports build-time vs runtime scoping,
and injects them into the container — so we no longer hand-roll envelope encryption
/ KEK / age / KMS. (That machinery is retired under the Coolify + trusted-internal
model.)

Graduation: self-hosted **Infisical** or **Vault** if you later need versioning,
rotation, audit trails, or dynamic secrets beyond what Coolify provides.

## Fetch / inject
The kiosk sets the app's env via the Coolify API (`/applications/{uuid}/envs`) —
platform-injected values (DB URL, LiteLLM virtual key) + creator secrets — and
Coolify injects them at runtime. The app reads `process.env` / `os.environ`
normally — **zero code change** (essential for vibe-coded apps). Secrets are never
baked into the image (runtime env, not build args).

```
creator form ─┐
              ├─► kiosk ─► Coolify API (/applications/{uuid}/envs, encrypted at rest)
platform vars ┘                     │  (at deploy)
                                    ▼
                     Coolify injects env ─► tenant container
```

**Scoping:** the kiosk sets each app *only its own* env via Coolify — no broad
fetch token, so no cross-tenant access.

**Rotation:** update the value via the Coolify API + redeploy. Fine for infrequent
rotation.

## Graduation trigger → fetch-at-runtime
When you need rotate-without-redeploy, or to keep secrets out of the container env
entirely: a **short-lived tenant token** at launch + a sidecar pulling from
Vault/Infisical. More secure, more than a vibe-coded app wires itself — a scale
step, not the default.

## Env keys (kiosk config, see `.env.example`)
- `COOLIFY_BASE_URL` / `COOLIFY_API_TOKEN` — the engine the kiosk drives.
- `REGISTRY_URL` / `REGISTRY_USER` / `REGISTRY_PASSWORD` — where tenant images are
  pushed; Coolify deploys from here.
- App secrets themselves live in **Coolify's encrypted env store**, not in our
  `.env`.
