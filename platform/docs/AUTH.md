# Auth — dev stub vs company Google

Two profiles, one middleware. Traefik's `forwardauth` middleware always calls
`http://forward-auth:4180/oauth2/auth`; `forward-auth` is a **network alias**
satisfied by whichever service the active compose profile started. So switching
auth modes never touches Traefik or the tenant labels.

| Mode | Service | When | Command |
|---|---|---|---|
| `dev` | `authstub` | laptop / CI — no Google needed | `make up PROFILE=dev` (default) |
| `google` | `oauth2-proxy` | EC2 / staging / prod | `make up PROFILE=google` |

## Dev stub (`AUTH_MODE=dev`)

[`authstub/server.py`](../authstub/server.py) answers the forward-auth probe with
`202` and injects a fixed identity (`DEV_USER_EMAIL`). This is the README's
"dev-mode identity stub that bypasses Google".

It does **not** weaken the company-domain guarantee: the kiosk
([`auth.py`](../kiosk/app/auth.py)) re-checks the domain on every request. Point
`DEV_USER_EMAIL` at a non-company address (e.g. `intruder@gmail.com`) and the
kiosk returns `403` — exactly the denial Google would trigger (the Coolify
parity gate in [`../coolify/README.md`](../coolify/README.md) checks this).

## Company Google (`AUTH_MODE=google`)

1. In Google Cloud Console create an **OAuth 2.0 Client ID** (Web application).
2. Add the authorized redirect URI for each platform host, e.g.
   `https://kiosk.apps.internal/oauth2/callback` (oauth2-proxy serves
   `/oauth2/*` on every `*.<PLATFORM_DOMAIN>` host via its Traefik router).
3. Fill `.env`:
   ```
   AUTH_MODE=google
   COMPANY_EMAIL_DOMAIN=wego.com
   OAUTH2_PROXY_CLIENT_ID=...
   OAUTH2_PROXY_CLIENT_SECRET=...
   OAUTH2_PROXY_COOKIE_SECRET=$(openssl rand -base64 32)
   ```
4. `make up PROFILE=google`.

oauth2-proxy is started with `--email-domains=$COMPANY_EMAIL_DOMAIN`, so a
non-company Google account is denied at the proxy; the kiosk enforces the same
domain as defense-in-depth. The cookie is scoped to `.<PLATFORM_DOMAIN>` so a
single login works across every app subdomain.

### Local `*.apps.internal` caveat

As the README notes, Google OAuth redirect URIs and `*.apps.internal` TLS/DNS
don't "just work" on a laptop. For a local Google test use **mkcert** for the
cert and **dnsmasq** (or `/etc/hosts`) to resolve the hosts, with a registered
dev redirect URI. On a real EC2 box with internal DNS this drops away. For day-
to-day local work, prefer the dev stub.
