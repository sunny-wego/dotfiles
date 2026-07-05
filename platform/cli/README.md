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
1. In the Kiosk web UI, open **API tokens → Create token**, copy the `ksk_…`.
2. `kiosk login --url https://kiosk.<your-domain> --token ksk_…`
   (or set `KIOSK_URL` / `KIOSK_TOKEN` env vars; config lives at
   `~/.config/kiosk/config.json`).
3. `kiosk whoami` to confirm.

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
