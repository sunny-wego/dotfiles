---
name: deploy-internal-app
description: >-
  Deploy and manage an internal web app on the company Kiosk platform — drop a
  project and get a hosted URL behind company login, with a database, cron,
  secrets, per-app access, and rollback. Use when the user wants to ship/host an
  app they built, check its status or logs, manage its secrets/scheduled
  tasks/allow-list, or roll it back. Drives the `kiosk` CLI.
---

# Deploy an internal app with the `kiosk` CLI

The Kiosk hosts internal apps: you hand it a project ZIP, it builds a container
(LLM-generated Dockerfile + self-healing), and serves it at
`https://<slug>.<company-domain>` behind company Google login. You drive it with
the `kiosk` CLI (in `platform/cli/kiosk`); it talks to the Kiosk API with a
personal token. Everything here runs from the machine where the app's code is.

**Always pass `--json` and parse the result** — then report status to the user in
plain language. Never invent a slug or URL; read it from the CLI output.

## 0. Make sure you're authenticated
```
kiosk whoami --json
```
If it errors with "not logged in" / 401: the user must mint a token in the Kiosk
web UI (their profile → API tokens), then run
`kiosk login --url <kiosk-url> --token <ksk_…>` once. Don't try to create the
first token from the CLI — that needs a browser session.

## 1. Deploy (or redeploy) an app
Zip the project (exclude junk), then deploy and wait for the result:
```
zip -r /tmp/app.zip . -x '.git/*' 'node_modules/*' '.venv/*'
kiosk deploy /tmp/app.zip --name my-app --wait --json
```
- `--wait` polls until the app is `running` or `failed`, streaming build/heal log
  lines to stderr. Deploys are async, so without `--wait` you get `deploying`
  back and must poll `kiosk status <slug> --json` yourself.
- Re-running `deploy` with the same name **updates** the app (owner only).
- On `"status":"failed"`, fetch `kiosk logs <slug>` and the build lines to
  diagnose (missing dependency, wrong port, crash on boot), fix the project, and
  redeploy. Report the concrete reason to the user — never a raw trace.

## 2. Configure the app
```
kiosk secret set  my-app DATABASE_PASSWORD hunter2   # secrets → injected as env
kiosk secret rm   my-app OLD_KEY
kiosk egress add  my-app api.stripe.com              # allow one outbound host
kiosk cron add    my-app --name nightly --schedule '0 9 * * *' --command 'python report.py'
kiosk cron rm     my-app --name nightly
kiosk access add  my-app teammate@company.com        # who may open the app
kiosk access rm   my-app teammate@company.com
```
- **Never commit secrets into the project/ZIP** — pass them via `kiosk secret set`
  (they're injected at runtime, not baked into the image).
- Cron schedules are 5-field cron; state they run in the container's timezone.
- Outbound network is default-deny: an app can only reach hosts added via
  `egress add`.

## 3. Inspect / recover
```
kiosk list --json                 # catalog: slug, status, url
kiosk status my-app --json        # current status + URL
kiosk logs   my-app --json        # runtime logs
kiosk rollback my-app --json      # re-point to the previous build
```

## Guardrails
- The app is **private by default** — reachable only by the owner + anyone on the
  allow-list. Don't widen access without the user asking.
- You act as the token's owner; every action is audited under that identity.
- If a command 403s, it's an ownership/allow-list denial — surface it, don't
  retry against a different app.
