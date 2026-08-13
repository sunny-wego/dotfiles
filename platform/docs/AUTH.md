# Auth — dev stub vs company Google

Two profiles, one middleware. Traefik's `forwardauth` middleware always calls
`http://forward-auth:4180/oauth2/auth`; `forward-auth` is a **network alias**
satisfied by whichever service the active compose profile started. So switching
auth modes never touches Traefik or the tenant labels.

| Mode | Service | When | Command |
|---|---|---|---|
| `dev` | `authstub` | laptop / CI — no OIDC at all | `make up PROFILE=dev` (default) |
| `local` | `oauth2-proxy` + `mock-oidc` | laptop parity — real oauth2-proxy, mock issuer | `make local-up` ([local/README.md](../local/README.md)) |
| `google` | `oauth2-proxy` | EC2 / staging / prod | `make up PROFILE=google` |

`google` and `local` are the **same** `oauth2-proxy`, run as a generic **OIDC**
client. Only `OIDC_ISSUER_URL` (+ its client id/secret) differs:
`https://accounts.google.com` in prod, a local mock issuer for `local`. Google is
a compliant OIDC provider, and `--email-domains` enforces the company domain in
both — so nothing about the auth *behaviour* changes with the issuer.

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

## Local parity (`AUTH_MODE=local`) — real oauth2-proxy without Google

To exercise the genuine oauth2-proxy path on a laptop — redirects, callback,
cookie, the whole OIDC handshake — without a Google tenant, use the Colima parity
harness ([local/README.md](../local/README.md)). It runs the same oauth2-proxy
against [`navikt/mock-oauth2-server`](https://github.com/navikt/mock-oauth2-server)
(a real OIDC issuer) with `mkcert` TLS and `nip.io` DNS, so only the issuer URL,
its client creds, and the cert issuer differ from prod. `make local-up` then
`make parity-local`.

For day-to-day work that doesn't care about OAuth, prefer the dev stub. When you
need to trust the auth chain end-to-end, use `local` (or the real thing on EC2).
