# Coolify variant — operator runbook

This realizes the README's **headline architecture**: Coolify is the deploy
engine and the operator admin plane; the Kiosk drives it through its REST API on
the creator's behalf. It is the counterpart to the plain-Docker variant
([`../M1.md`](../M1.md) / [`../v1.md`](../v1.md)) — same Kiosk, same build/heal
pipeline, same auth chain, **different engine underneath**.

> **Why two variants?** The deploy engine sits behind a small interface
> (`kiosk/app/backends/base.py`). `KIOSK_DEPLOY_BACKEND=docker` drives the host
> Docker daemon (default, zero-install, the local/dev path); `=coolify` drives
> Coolify. Nothing above the image + auth-chain contract changes — the README's
> "additive, not a migration".

## Two planes, mapped onto Coolify

| Plane | Who | Surface |
|---|---|---|
| **User plane** | creators (non-eng) | the **Kiosk** only (ZIP→app, logs, catalog) |
| **Admin plane** | operators (eng) | the **Coolify dashboard** (deploys, envs, logs, rollback, resources) |

The Kiosk holds a **least-privilege Coolify API token** and creates one Coolify
*application* per tenant app. Creators never open Coolify; operators never touch
the Kiosk to debug — they use Coolify's dashboard, which shows every tenant app
because the Kiosk created them all in one project.

## What Coolify now owns (was bespoke in the plain-Docker variant)

Per README §3 ("native Coolify = deploy engine"):

| Concern | Coolify mechanism | Kiosk code path |
|---|---|---|
| Deploy-from-image | Docker-image application | `backends/coolify/backend.py::deploy` |
| TLS + domains | Coolify-managed Traefik | `domains` field on the app |
| Env / secret store | Coolify encrypted env store | `client.set_envs` (bulk upsert) |
| CPU / mem limits | app resource limits | `limits_cpus` / `limits_memory` |
| Cron | **Scheduled Tasks** | `client.*_scheduled_task` (kiosk cron loop OFF) |
| Rollback | deployment history | dashboard (surfaced via the Kiosk's rollback action) |

**Still the Kiosk's job** (README's extensions): the LLM Dockerfile + build /
verify / heal pipeline, redaction, the base-image allowlist, per-tenant Postgres
db-per-tenant, LiteLLM virtual keys, the oauth2-proxy + `appauthz` auth chain,
per-tenant `pg_dump` backups, and actor-attributed audit.

## The auth chain still applies — verify this first

Tenant apps must stay behind `strip-auth-in → slug-<slug> → forwardauth →
appauthz` (README §9; enforced identically for both engines by
`kiosk/app/backends/labels.py`). Under Coolify:

1. The Kiosk sets the chain as **custom Traefik labels** on each app, and sets
   `is_container_label_readonly_enabled` so Coolify does **not** auto-generate a
   second, unauthenticated router.
2. The `@file` middlewares the labels reference must exist in **Coolify's**
   Traefik. Install [`traefik-dynamic.yml`](./traefik-dynamic.yml) into Coolify's
   proxy dynamic-config directory (see that file's header) and point its
   `forward-auth` / `kiosk` addresses at the reachable service names.

> **Parity gate (do not skip).** The in-repo tests cover the pure logic (auth
> chain order, API request shapes) but this sandbox cannot run Coolify. On the
> EC2 box, re-run the plain-Docker done-when checks against the Coolify backend:
> `make smoke` (T1–T4) and the v1 checks (DB, cron, egress-deny, unauthorized
> denied, restore drill). A tenant URL hit **without** a company session MUST
> return 403 — that proves the chain survived the engine swap.

## Bring-up

```bash
# 1. Install Coolify on the box (host-as-code, pinned).
sudo ./install.sh

# 2. In the Coolify dashboard, once:
#    - create a Project + Environment ("production") for tenant apps
#    - add this server, and a Destination whose Docker network is the same
#      network kiosk/postgres/litellm/egress-proxy sit on (COOLIFY_TENANT_NETWORK)
#    - create an API token (Keys & Tokens) scoped to that project
#    - install ./traefik-dynamic.yml into Coolify's proxy dynamic config

# 3. Point the Kiosk at Coolify (see ../.env.example "Deploy engine" block):
#    KIOSK_DEPLOY_BACKEND=coolify, COOLIFY_BASE_URL, COOLIFY_API_TOKEN,
#    COOLIFY_PROJECT_UUID, COOLIFY_SERVER_UUID, COOLIFY_DESTINATION_UUID
```

The Kiosk and shared services (Postgres, LiteLLM, egress-proxy, oauth2-proxy) can
keep running from the compose stack on the same box, or be deployed as Coolify
resources; either way they must share `COOLIFY_TENANT_NETWORK` so tenant apps
reach their DB/LLM and the `appauthz` hop reaches the Kiosk.

## Backups — the one thing the engine swap adds to your runbook

Per-tenant DB backups stay in the Kiosk (`backup.py`, unchanged). What Coolify
adds is that **Coolify's own state is now deployment state** — domains, envs,
scheduled tasks, destinations. If you lose it, retained images/Dockerfiles alone
won't reproduce the apps. So:

- Enable Coolify's built-in **scheduled backup of its own database**.
- Back up Coolify's data directory (`/data/coolify`) off-box.
- Keep this runbook + `install.sh` as the host-as-code restore path.

## Async deploys

Coolify deploys are **asynchronous**: the Kiosk returns once the deploy is
*accepted*, not once the container is live (the plain-Docker backend blocks until
live). The app page and the Coolify dashboard show progress. This is the only
creator-visible behavioural difference between the two engines.
