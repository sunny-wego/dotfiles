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
Default: **envelope encryption in the platform Postgres.**
- A per-app data key (DEK) encrypts the values; the DEK is wrapped by a KEK held
  outside Postgres.
- **KEK source is env-gated** (`KEK_PROVIDER`): `age` key file locally, AWS
  **KMS** on EC2. Same store, different key origin — only `.env` differs.
- Plaintext exists only briefly in control-plane memory at launch, and in the
  running container.

Graduation: self-hosted **Infisical** or **Vault** when you need versioning,
rotation, audit trails, or dynamic secrets.

## Fetch / inject
Default: **decrypt-and-inject-as-env at container launch.** The control-plane
decrypts the app's secrets, merges them with the platform-injected env, and
passes them via `--env-file` (tmpfs, never baked into the image). The app reads
`process.env` / `os.environ` normally — **zero code change** (essential for
vibe-coded apps).

```
creator form ─┐
              ├─► control-plane ─► envelope-encrypt ─► Postgres (at rest)
platform vars ┘            │  (at launch)
                           ▼
        decrypt (KEK: age|kms) ─► --env-file (tmpfs) ─► tenant container
```

**Scoping (adversarial):** the control-plane injects each app *only its own*
secrets — apps hold no broad fetch token, so there's no cross-tenant access even
if an app is hostile. Env is visible via `docker inspect`, but tenants have no
socket access, so that surface is closed.

**Rotation:** update stored value + redeploy (restart with new env). Fine for
infrequent rotation.

## Graduation trigger → fetch-at-runtime
When you need rotate-without-redeploy, or to keep secrets out of the container
env entirely: inject a **short-lived tenant token** at launch and have a
sidecar/init pull secrets from Vault/Infisical and template them in. More secure,
but more than a non-technical app wires itself — hence the scale step, not the
default.

## Env keys (see `.env.example`)
- `TENANT_RUNTIME` — `runsc` (parity) or `runc` (fast local iteration).
- `KEK_PROVIDER` — `age` (local) | `kms` (EC2).
- `AGE_KEY_FILE` — local KEK path (gitignored).
- `KMS_KEY_ID` — EC2 KEK.
