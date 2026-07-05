# `kiosk` CLI

A thin client over the Kiosk HTTP API — the non-browser surface for the Internal
App Platform. It drives the **same control plane** as the web UI (create/deploy,
status, logs, secrets, cron, egress, access, rollback), authenticated with a
personal API token, from the machine where your app's code lives.

- **`kiosk`** — the CLI (Python 3; needs `httpx` → `pip install httpx`).
- **`SKILL.md`** — the agent skill: teaches a coding assistant to drive the CLI
  ("deploy this app", "why did it fail", "add a nightly cron"). Point your agent
  at it (e.g. symlink into your skills dir).

## Setup
```
kiosk login --url https://api.kiosk.<your-domain>
```
This runs a browser device-authorization flow (like `gh auth login`): it prints
a URL + short code, you open it in your browser (where you're already signed in
with company Google), confirm the code, and the CLI receives a token — no
copy-paste. `kiosk whoami` to confirm.

Alternatives: paste a token minted in the web UI (**API tokens → Create token**)
with `kiosk login --url … --token ksk_…`, or set `KIOSK_URL` / `KIOSK_TOKEN` env
vars. Config lives at `~/.config/kiosk/config.json`.

> **Ingress note (operators).** The token/device endpoints are Bearer-authed (or
> pre-auth), not cookie-authed, so they must reach the Kiosk *past* oauth2-proxy:
> expose an API route with only `strip-auth-in` (no `forwardauth`) — e.g.
> `api.kiosk.<domain>` — and point the CLI's `--url` there. `strip-auth-in` is
> required so nobody can spoof identity headers on the un-cookied route. The
> browser approval page (`/device`) and the web UI keep the full auth chain.

## Common commands
```
kiosk deploy ./app.zip --name my-app --wait   # ZIP → live URL (polls to done)
kiosk list                                     # catalog + status + URLs
kiosk status my-app        kiosk logs my-app
kiosk secret set my-app KEY value              kiosk secret rm my-app KEY
kiosk cron add my-app --name nightly --schedule '0 9 * * *' --command 'python x.py'
kiosk egress add my-app api.stripe.com         # default-deny outbound
kiosk access add my-app teammate@company.com   # private by default
kiosk rollback my-app
kiosk token create --label laptop              kiosk token list / revoke <id>
```
Add `--json` to any command for machine-readable output (what the skill parses).

Auth, RBAC, and audit are identical to the web UI — a token carries your company
identity, so every CLI action is attributed to you and fail-closed on the
company-domain + per-app allow-list checks.
