# Coolify as the engine — architecture & decision record

Status: **planning**. Decision: **adopt Coolify as the deployment engine**; build
the kiosk/LLM/RBAC layer on top via its API. Verified — **no blocker** (Apache 2.0,
full REST API, per-tenant isolation via Destinations, deploy-from-image).

## Verified findings (July 2026)
| Concern | Result |
|---|---|
| **License** | **Apache 2.0** — commercial + proprietary integration, no copyleft |
| **Source ingestion** | We build the image (heal loop) → push to registry → Coolify **deploys from image** via API. (Git-based build is the alternative.) |
| **Per-tenant network isolation** | **Destinations** = Docker-network endpoints; apps on different destinations can't talk → **one Destination per tenant**. (Per-project auto-isolation is not yet native, so this is deliberate.) |
| **API** | Full REST (`/api/v1`, OpenAPI 3.1): create app (incl. Dockerfile/image), envs, lifecycle (`start`/`stop`/`restart`=deploy), token perms, 200 req/min. Headless. |
| **Cron** | Scheduled Tasks run **inside the container** (no host cron needed); 1h timeout cap |
| **Custom Traefik labels (Authelia RBAC)** | Honored on **standard Dockerfile/image apps**; overridden on **compose/predefined templates** → **deploy tenant apps as images, never compose** |
| **Resource limits** | Per-app CPU/memory native |
| **Scaling** | Vertical + per-server placement native; **single-app replicas not until v5** |
| **Cheap DB** | No one-click libSQL, but sqld/SQLite run as custom resources (see below) |

## How much it simplifies (~60–70% of plumbing)
Deleted from our stack: hand-rolled **Traefik**, **Ofelia (cron)**,
**docker-socket-proxy + launch orchestration**, **build pipeline**, **secret
envelope-encryption**, **rollback/logs/lifecycle**. Coolify provides all of it.

## What stays ours (the differentiated core)
Kiosk UX · LLM Dockerfile generation + build-verify-heal · LLM-generated probe
detection + manifest · LiteLLM gateway + per-tenant virtual keys · Authelia +
default-deny RBAC · per-tenant DB (sqld namespaces).

## Architecture
```
┌─ Kiosk (ours) ── ZIP-drop · detect + probe · LLM Dockerfile + heal · build image
│                   · mint LiteLLM key · provision DB namespace · drive Coolify API
├─ Coolify (engine) ── ingress/TLS/domains · deploy-from-image · CRON · env/secrets
│                       · resource limits · rollback · per-server placement
├─ Platform services (on Coolify) ── litellm · authelia · sqld · redis · metadata PG
└─ Tenant apps ── deployed FROM image · 1 Destination/tenant · Authelia mw via labels
```

## Provisioning flow (Coolify)
1. Kiosk: detect + probe + generate Dockerfile + **build-verify-heal → image**.
2. Kiosk: **push image** to registry; mint **LiteLLM virtual key**; create **sqld
   namespace**.
3. Kiosk → **Coolify API**: create app **from image** in the tenant's **Destination**;
   set env (DB URL + LiteLLM key + secrets via Coolify's store); set domain +
   resource limits; add Scheduled Task (cron); attach **custom labels** for the
   Authelia forward-auth middleware; **deploy** (`/start`).
4. Kiosk records tenant↔app↔db↔manifest in metadata Postgres.

## Operating rules (fall out of verification — must follow)
1. **Tenant apps deploy as images, not compose** (keeps custom RBAC labels).
2. **Build ourselves → push → Coolify deploys the image** (reuses heal loop; also
   makes every deploy an **immutable artifact** → clean rollback, no drift).
3. **One Destination per tenant** for network isolation.
4. **libSQL/sqld namespaces (default) or SQLite-on-volume** for cheap per-tenant DB;
   Postgres-per-tenant only on demand (~50–100× the RAM at fleet scale).

## Answers to standing questions
- **Beefier app server?** Yes — raise per-app CPU/mem limits, and/or add a bigger
  server to the fleet and place the app on it (per-resource server selection). No
  replicas needed; this is the scale axis Coolify does well.
- **Per-tenant enforcement?** Yes on all axes: network (Destination), RBAC
  (Authelia), resources (limits), cost (LiteLLM budgets), data (sqld namespace).
- **Immutable setups?** Yes, and good: image-per-deploy = reproducible, rollback by
  redeploying the prior image, no config drift. Data/volumes persist across redeploys.

## The one spike before committing
Confirm **custom Traefik labels are settable via the API** (not UI-only) — the RBAC
middleware attach depends on it. Fallback if not: a shared Traefik dynamic-config
file rule keyed by host. Either way, not a blocker.

## Scaling ceiling (the one graduation)
Single-app **replica-based HA** isn't native until Coolify v5. If one app ever needs
it: Swarm (experimental) or graduate that app to Cloud Run/Fly/K8s — a re-point via
the Dockerfile contract. Everything else stays turnkey.

## Parity
Coolify on **Colima** locally, Coolify on **EC2** remotely — same engine both sides.
