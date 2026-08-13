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

## The one-liner

```
make local        # first run: Colima + Coolify + certs + identity edge; then stops
                  #   for ONE browser step (create admin + API token)
# → open the printed Coolify URL, create the admin, make an API token, and paste
#   COOLIFY_BASE_URL + COOLIFY_API_TOKEN into local/.env.local  (~30 seconds)
make local        # second run: auto-provisions project/env/server, builds the
                  #   kiosk, self-hosts the control plane on Coolify
make parity-local # (optional) drive the deploy engine end-to-end + the 403 check
```

`make local` is **idempotent** — run it, do the one browser step, run it again.
It brings up only the identity edge (`oauth2-proxy` + mock OIDC) in compose; the
kiosk + backing services self-host on Coolify. First time on a fresh Mac, install
Coolify into the VM with `./local/local.sh --install-coolify` (or let it run once
via `local/up.sh --install-coolify`).

Why the one manual step can't be scripted: Coolify's **first-run admin + API
token** are created in the browser (no API exists until a token does). Everything
after the token — project, environment, server UUIDs — is auto-provisioned by
`coolify/provision.py`.

The individual targets still exist if you want to step through it: `make local-up`,
`make local-certs`, `make build`, `make bootstrap`, `make parity-local`.

### Where each piece runs (Option C — the identity edge is environment-provided)

The **kiosk + its backing services** self-host on Coolify (`make bootstrap` →
[`../coolify/platform-stack.yml`](../coolify/platform-stack.yml)). The **identity
edge — `oauth2-proxy` + the mock OIDC issuer — stays in the local compose**
(`make local-up`), sharing `COOLIFY_TENANT_NETWORK` so Coolify's Traefik resolves
`forward-auth` for the kiosk's router. Because oauth2-proxy stays in compose, the
front-/back-channel issuer wiring is the one the base compose already solves
(`auth.<domain> → host-gateway`) — **there is no cross-boundary seam**, and no
local hack leaks into the shipped stack. In prod, the same `forward-auth` slot is
filled by `oauth2-proxy` against Google (external issuer, no wrinkle).

So a full local run is: `make local-up` (Colima + Coolify + oauth2-proxy + mock),
`make local-certs`, `make build`, `make bootstrap` (kiosk + backing services onto
Coolify), then `make parity-local`.

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
