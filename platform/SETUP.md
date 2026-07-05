# Setup — local & remote

One box, one command. The **core steps are identical** whether you run on a
laptop or an EC2 box; only a handful of `.env` values differ. This doc is the
core spine plus a short delta block for each target.

See also: [`docs/AUTH.md`](./docs/AUTH.md) (dev stub vs Google), [`M1.md`](./M1.md)
(walking-skeleton runbook), [`v1.md`](./v1.md) (the v1 feature set).

## Prerequisites

- **Coolify** — the deploy engine + ingress. Install it first via
  [`coolify/install.sh`](./coolify/install.sh) and do the one-time dashboard
  setup (project / environment / destination / API token) per
  [`coolify/README.md`](./coolify/README.md).
- **Docker** with the Compose plugin (`docker compose`) for the shared services.
- **Make** (optional — every `make` target below maps to a plain
  `docker compose` command if you'd rather run it directly).
- The kiosk builds tenant images via the mounted host Docker socket
  (docker-out-of-docker), then hands the image to Coolify to deploy.

## Core steps (identical local & remote)

```bash
sudo coolify/install.sh     # 0. install Coolify; then set it up (coolify/README.md)
cp .env.example .env        # 1. create config (see the delta blocks below)
#                             2. edit .env — COOLIFY_* + a few values by target
make up                     # 3. start shared services (== docker compose --profile dev up -d --build)
make samples                # 4. build the Node + Python sample zips into ./dist
#                             5. run the parity gate (coolify/README.md)
```

The Kiosk is exposed through Coolify's proxy at `https://kiosk.<PLATFORM_DOMAIN>`.
Open it, sign in, and **upload a sample zip from `./dist`** to deploy your first
app — the Kiosk builds + pushes the image, Coolify deploys it, and it comes back
as a private URL behind login.

`make up` first runs **`make preflight`** — a readiness check (Docker up, `.env`
present, disk headroom, LLM mode vs key, and — in google mode — a real secret key
+ OAuth creds). Ports 80/443 belong to Coolify's proxy, not this stack. Run it
standalone any time with `make preflight`; it blocks `up` only on genuine
blockers, not warnings.

Everyday targets: `make logs` (tail kiosk), `make down` (stop, keep data),
`make clean` (stop **and delete volumes** — destructive), `make check`
(no-Docker syntax + compose validation), `make test` (fast behaviour/contract
unit tests — no Docker; `pip install -r kiosk/requirements-dev.txt` once).

## What differs by target

Only these `.env` values (and, remotely, DNS/TLS). Everything else in
`.env.example` has a working default.

| `.env` key | Local (laptop / CI) | Remote (EC2 / staging / prod) |
|---|---|---|
| `AUTH_MODE` | `dev` (identity stub, no Google) | `google` |
| `PLATFORM_DOMAIN` | `apps.localhost` (resolves to 127.0.0.1, no DNS) | your internal zone, e.g. `apps.internal` |
| `KIOSK_SECRET_KEY` | dev default is fine (logs a warning) | **required** — a real key; startup refuses the default in google mode |
| `OPENROUTER_API_KEY` | optional (see LLM note) | set for the AI Dockerfile path |
| `OAUTH2_PROXY_*` | unused | client id / secret / `openssl rand -base64 32` cookie |
| registry push | skipped on one box (fine) | add `registry:5000` to `insecure-registries` or TLS-front it |

### Local

The defaults in `.env.example` are already the local profile. After
`cp .env.example .env` you can run `make up` as-is:

- `AUTH_MODE=dev` uses the dev-auth stub — no Google, no TLS/DNS fuss.
  `DEV_USER_EMAIL` is the signed-in identity; point it at a non-company address
  (e.g. `intruder@gmail.com`) to exercise the denial path. The company-domain
  check still runs in both modes.
- `PLATFORM_DOMAIN=apps.localhost` resolves to `127.0.0.1` on most systems with
  no DNS setup, so `https://kiosk.apps.localhost` and `https://<app>.apps.localhost`
  just work (self-signed TLS — expect a browser warning).

### Remote (EC2)

Same core steps; change the values above, then `make up PROFILE=google`.

1. Point wildcard DNS `*.<PLATFORM_DOMAIN>` at the box and provide a wildcard
   TLS cert (or terminate TLS at Traefik with your own cert).
2. Set a real `KIOSK_SECRET_KEY` (`openssl rand -base64 32`). This is
   **enforced**: in `google` mode the kiosk refuses to start — and refuses to
   encrypt/decrypt — under the shipped default key.
3. Configure Google OAuth per [`docs/AUTH.md`](./docs/AUTH.md#company-google-auth_modegoogle)
   (`OAUTH2_PROXY_CLIENT_ID/SECRET/COOKIE_SECRET`, and a redirect URI
   `https://kiosk.<PLATFORM_DOMAIN>/oauth2/callback`).
4. `make up PROFILE=google`.

Growing one box → a fleet later is additive, not a migration: apps address the
platform through Traefik hostnames + the Dockerfile contract, so nothing above
the image contract changes.

## LLM path (both targets)

The kiosk's own Dockerfile generation + self-heal call an LLM through LiteLLM.

- **With a model:** set `OPENROUTER_API_KEY` and keep `KIOSK_LLM_MODE=llm` (the
  product path). Per-tenant virtual keys are minted automatically.
- **Offline / no key:** set `KIOSK_LLM_MODE=stub` — a deterministic Dockerfile
  is templated from detection instead of calling the model. Detect → build →
  verify → deploy all still work; only generation/heal are stubbed.

## Troubleshooting

- **Registry push "FAILED"/"skipped".** On a single box the daemon already holds
  the built image, so deploy works without a successful push. To make push
  succeed (needed for a remote/multi-box deployer), add `registry:5000` to the
  daemon's `insecure-registries` in `/etc/docker/daemon.json` and restart Docker,
  or front the registry with TLS. A skipped push never fails a provision.
- **Build can't reach the network.** If tenant image builds must use the host
  network (e.g. to reach an internal mirror/proxy), set `KIOSK_BUILD_NETWORK=host`.
- **Parity gate fails on auth.** Confirm `COMPANY_EMAIL_DOMAIN` matches the
  identity (`DEV_USER_EMAIL` in dev mode); a non-company address is denied by
  design.
- **Docker Engine 29 label routing.** Already handled — the committed compose
  pins `traefik:v3.6`, which negotiates the Docker API version. Older Traefik
  (≤ v3.5) pinned API 1.24 and could not read labels on Docker 29.
