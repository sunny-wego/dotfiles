# Local parity on macOS (Colima) — run the real thing on a laptop

The [parity gate](../coolify/README.md) isn't EC2-specific; it just needs a
**real Coolify**. This harness stands one up on a Mac via Colima and runs the
platform behind a **real oauth2-proxy** against a **mock OIDC issuer**, so the
only things that differ from production are:

- the **OIDC issuer** (`http://auth.<domain>:8080` mock ↔ `https://accounts.google.com`)
  and its client credentials,
- the **domain** (`*.apps.127.0.0.1.nip.io` ↔ your internal zone), and
- the **TLS cert issuer** (mkcert local CA ↔ Let's Encrypt).

Everything *inside* the platform boundary — the deploy engine (Coolify), the
`create_image_app`/env/deploy/scheduled-task/database REST contract, the
`strip-auth-in → slug → forwardauth → appauthz` chain, the kiosk identity path,
per-tenant Coolify Postgres + native backups — is byte-for-byte the prod path.

## Prerequisites

```
brew install colima docker mkcert nss
```

## One run

```
make local-up        # 1: Colima + (opt) Coolify   4: real oauth2-proxy + mock OIDC (compose)
make local-certs     # 3: browser-trusted wildcard cert for *.apps.127.0.0.1.nip.io
# → finish the Coolify dashboard steps up.sh prints, fill local/.env.local
make parity-local    # 5: the parity gate (contract + auth-chain 403) vs local Coolify
```

### Two ways to run the control plane locally

- **Compose (what `make local-up` does today):** the kiosk + a real oauth2-proxy +
  the mock OIDC issuer run from the local compose stack, sharing
  `COOLIFY_TENANT_NETWORK` with Coolify's tenant apps. This is the fully-working
  local path and what `make parity-local` exercises.
- **Self-hosted (`make bootstrap`, the prod topology):** the kiosk + oauth2-proxy
  run *as a Coolify service* ([`../coolify/platform-stack.yml`](../coolify/platform-stack.yml)).
  Locally this adds one wrinkle that needs a live Coolify to pin down: the
  Coolify-run oauth2-proxy must reach the **compose-hosted mock issuer** on the
  host (the same front-/back-channel issuer-URL consistency the base compose
  solves with `auth.<domain> → host-gateway`). Prod doesn't have this wrinkle —
  the issuer is `accounts.google.com`, reachable from anywhere. So on a laptop,
  use the compose path above to exercise the mock; use `make bootstrap` to
  rehearse the *prod* self-hosting flow (against Google, or once the mock wiring
  is validated on your box).

`local/up.sh --install-coolify` also runs Coolify's installer inside the VM
(otherwise install it once yourself: `colima ssh -- sudo bash -c "$(curl -fsSL https://cdn.coollabs.io/coolify/install.sh)"`).

## How each item is realised

| # | Item | Here |
|---|---|---|
| 1 | Coolify engine | installed inside the Colima Linux VM — same binary/REST as EC2 |
| 2 | Faithful DNS | `*.apps.127.0.0.1.nip.io` → 127.0.0.1 (no `/etc/hosts`); Traefik does real host routing |
| 3 | Real TLS | `mkcert` wildcard loaded into Coolify's Traefik (`local/mkcert.sh`) |
| 4 | Auth — swap only the issuer | base `oauth2-proxy` runs generic OIDC; `local/docker-compose.local.yml` adds a `mock-oidc` issuer and points the back-channel at it |
| 5 | The gate | `parity-local.sh` runs `coolify/parity-gate.sh` (which loads `local/.env.local`) and auto-runs the 403 check against a kept probe app |

## Why the mock is faithful, not a stub

`AUTH_MODE=dev` (the [authstub](../authstub/server.py)) skips OIDC entirely — fine
for fast iteration, useless for finding OAuth/redirect/cookie bugs. This harness
instead runs the **actual `oauth2-proxy`** (same image, same flags) against
[`navikt/mock-oauth2-server`](https://github.com/navikt/mock-oauth2-server),
which serves real OIDC discovery/authorize/token/JWKS. `mock-oidc.json` returns a
company-domain `email` claim so `--email-domains` passes exactly as Google would.
Swapping to prod is literally: set `OIDC_ISSUER_URL=https://accounts.google.com`
+ the real client id/secret, register the redirect URIs in Google, and issue
Let's Encrypt certs. No app code changes.

### The one fiddly bit — issuer URL consistency

OIDC requires the browser (front-channel) and oauth2-proxy (back-channel) to see
the **same** issuer URL. `auth.<domain>` is a nip.io name that resolves to
`127.0.0.1` — correct for the browser, but inside the oauth2-proxy container that
would be the container itself. The override maps `auth.<domain>` to
`host-gateway`, where the mock's `:8080` is published, so both channels resolve
to the identical issuer string. (Harmless in prod: the prod issuer is
`accounts.google.com`, not `auth.<domain>`.)

## What still can't match locally (and shouldn't be faked)

Public DNS, Let's Encrypt issuance, and a real Google tenant. Faking those is
where false confidence comes from — they're the genuinely prod-only slice. The
gate covers everything else.
