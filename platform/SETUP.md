# Setup — local & remote

One box, one command. The **core steps are identical** whether you run on a
laptop or an EC2 box; only a handful of `.env` values differ. This doc is the
core spine plus a short delta block for each target.

See also: [`docs/AUTH.md`](./docs/AUTH.md) (dev stub · local OIDC mock · Google),
[`local/README.md`](./local/README.md) (**run it on a Mac via Colima**),
[`M1.md`](./M1.md) (walking-skeleton runbook), [`v1.md`](./v1.md) (the v1 feature set).

## Prerequisites

- **Coolify** — the deploy engine + ingress. Coolify runs on Linux; install it
  first via [`coolify/install.sh`](./coolify/install.sh) (on macOS it installs
  inside the Colima VM — see below) and do the one-time dashboard setup
  (project / environment / destination / API token) per
  [`coolify/README.md`](./coolify/README.md).
- **Docker** with the Compose plugin (`docker compose`) for the shared services.
  On macOS use **Colima** (`brew install colima docker`), which provides the
  Linux VM both Docker and Coolify run in.
- **Make** (optional — every `make` target below maps to a plain
  `docker compose` command if you'd rather run it directly).
- The kiosk builds tenant images via the mounted host Docker socket
  (docker-out-of-docker), then pushes the image to the registry; **Coolify
  deploys by pulling that image**, so the registry must be reachable/pushable.

## Core steps (identical local & remote)

```bash
sudo coolify/install.sh     # 0. install Coolify; then set it up (coolify/README.md)
cp .env.example .env        # 1. create config (see the delta blocks below)
#                             2. edit .env — COOLIFY_* + a few values by target
make build                  # 3. build the kiosk image
make bootstrap              # 4. self-host the control plane ON Coolify (kiosk as a Coolify service)
make samples                # 5. build the Node + Python sample zips into ./dist
make parity                 # 6. run the parity gate against the live Coolify
```

**Topology:** the Kiosk + its backing services run **as a Coolify service** (the
platform hosts itself) — `make bootstrap` deploys
[`coolify/platform-stack.yml`](./coolify/platform-stack.yml) via Coolify's API, so
Coolify owns the Kiosk's domain/TLS/auth chain, and then deploys tenant apps on
the same network. The **identity edge (`oauth2-proxy`) is run separately** and
answers the `forward-auth` alias on that network: `make up PROFILE=google`
(compose) or your own resource in prod; the compose `local` profile + mock issuer
locally. See [`coolify/README.md`](./coolify/README.md#self-hosting-the-control-plane-make-bootstrap).

**On a Mac (Colima), one command:** `make local` — idempotent: it stands up
Colima + Coolify + certs + the identity edge (real oauth2-proxy + mock OIDC),
stops for one ~30-second browser step (create the Coolify admin + an API token,
paste into `local/.env.local`), then on a second `make local` auto-provisions the
UUIDs, builds the kiosk, and self-hosts the control plane. See
[`local/README.md`](./local/README.md).

**Faster local path (no self-host):** for quick iteration you can instead run the
shared services from the root compose behind the dev-auth stub —
`make up PROFILE=dev` — and skip `make bootstrap`.

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

Three ways to run it. Coolify is the deploy engine in **all** of them — the only
things that change are the auth issuer, the domain, and TLS. Everything else in
`.env.example` has a working default.

| `.env` value | `dev` (fastest laptop/CI) | `local` parity (Mac/Colima) | `google` (EC2 / prod) |
|---|---|---|---|
| auth | dev stub, no OIDC | **real oauth2-proxy + mock OIDC** | real oauth2-proxy + company Google |
| `AUTH_MODE` / profile | `dev` | `local` (`make local-up`) | `google` |
| `OIDC_ISSUER_URL` | — | mock (`local/.env.local`) | `https://accounts.google.com` |
| `PLATFORM_DOMAIN` | `apps.localhost` (→127.0.0.1) | `apps.127.0.0.1.nip.io` (→127.0.0.1) | your internal zone |
| TLS | self-signed (browser warning) | mkcert wildcard (trusted) | Let's Encrypt / your cert |
| `KIOSK_SECRET_KEY` | dev default OK (warns) | dev default OK (warns) | **required** real key |
| `OPENROUTER_API_KEY` | optional (LLM note) | optional (LLM note) | set for the AI path |
| `OAUTH2_PROXY_*` | unused | dummy creds (mock accepts any) | real Google client + cookie |
| registry push | **required** — Coolify pulls the image (see troubleshooting) | same | same |

### Local — dev stub (fastest)

The defaults in `.env.example` are this profile. `cp .env.example .env`, install
Coolify, then `make up`:

- `AUTH_MODE=dev` uses the dev-auth stub — no OIDC at all. `DEV_USER_EMAIL` is the
  signed-in identity; point it at a non-company address (e.g. `intruder@gmail.com`)
  to exercise the denial path. The company-domain check runs in every mode.
- `PLATFORM_DOMAIN=apps.localhost` resolves to `127.0.0.1`, so
  `https://kiosk.apps.localhost` works with self-signed TLS (expect a warning).

Use this when you don't care about the OAuth flow. When you *do* — to trust the
auth chain end-to-end on a laptop — use the Colima parity harness below.

### Local parity — Mac/Colima (real oauth2-proxy, mock issuer)

`make local-up` stands up Colima + Coolify + the shared stack behind the real
oauth2-proxy against a local OIDC mock, with mkcert TLS and nip.io DNS — so the
only differences from prod are the issuer URL, its client creds, and the cert
issuer. Full walkthrough: [`local/README.md`](./local/README.md). Then
`make parity-local`.

### Remote (EC2)

Same core steps; change the values above, then `make up PROFILE=google`.

1. Point wildcard DNS `*.<PLATFORM_DOMAIN>` at the box and provide a wildcard
   TLS cert (Coolify can issue Let's Encrypt, or terminate with your own cert).
2. Set a real `KIOSK_SECRET_KEY` (`openssl rand -base64 32`). This is
   **enforced**: in `google` mode the kiosk refuses to start — and refuses to
   encrypt/decrypt — under the shipped default key.
3. Configure Google OAuth per [`docs/AUTH.md`](./docs/AUTH.md#company-google-auth_modegoogle)
   (`OAUTH2_PROXY_CLIENT_ID/SECRET/COOKIE_SECRET`, and a redirect URI
   `https://kiosk.<PLATFORM_DOMAIN>/oauth2/callback`). Prod and local parity are
   the same oauth2-proxy — only `OIDC_ISSUER_URL` + client creds differ.
4. `make up PROFILE=google`.

Growing one box → a fleet later is additive, not a migration: apps address the
platform through Coolify's Traefik hostnames + the Dockerfile contract, so
nothing above the image contract changes.

## LLM path (both targets)

The kiosk's own Dockerfile generation + self-heal call an LLM through LiteLLM.

- **With a model:** set `OPENROUTER_API_KEY` and keep `KIOSK_LLM_MODE=llm` (the
  product path). Per-tenant virtual keys are minted automatically.
- **Offline / no key:** set `KIOSK_LLM_MODE=stub` — a deterministic Dockerfile
  is templated from detection instead of calling the model. Detect → build →
  verify → deploy all still work; only generation/heal are stubbed.

## Troubleshooting

- **Registry push "FAILED".** This now **fails the provision** — Coolify deploys
  by *pulling* the image from the registry, so an unpushable image can't deploy
  (unlike the old local-daemon path). Make push succeed: add `registry:5000` to
  the daemon's `insecure-registries` in `/etc/docker/daemon.json` and restart
  Docker (on Colima: `colima ssh -- sudo ...` then `colima restart`), or front
  the registry with TLS.
- **Build can't reach the network.** If tenant image builds must use the host
  network (e.g. to reach an internal mirror/proxy), set `KIOSK_BUILD_NETWORK=host`.
- **Parity gate fails on auth.** Confirm `COMPANY_EMAIL_DOMAIN` matches the
  identity (`DEV_USER_EMAIL` in dev mode; the mock's `email` claim in `local`
  mode — see `local/mock-oidc.json`); a non-company address is denied by design.
- **Coolify exposes an app without the auth chain (403 check fails).** Coolify
  may publish its own domain router alongside the kiosk's auth-chain router.
  Enable the app's "Readonly labels" toggle, or drop its Coolify domain so only
  the custom-label chain serves it (see `coolify/parity-gate.sh`).
- **Ingress/TLS.** Ports 80/443 belong to **Coolify's proxy**, not this compose
  stack — the stack publishes no ports. Route the kiosk + tenant apps through
  Coolify's Traefik (see the network/routing notes in `coolify/README.md`).
