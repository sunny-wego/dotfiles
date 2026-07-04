# Deployments & updates

Status: **planning**. How tenant-app updates, rollbacks, and config changes are
deployed. Immutable-image model; deploy mechanics are Coolify-native.

## Update flow
1. **Trigger** — creator drops a **new ZIP** in the kiosk (or, if a git repo is
   connected, a push webhooks the kiosk).
2. **Rebuild** — kiosk re-runs detection/heal as needed → builds a **new image
   tagged with a build id** (e.g. `:2026-07-04-abc123`) → **base-image allowlist +
   Trivy scan** → **push to registry**.
3. **Re-check RBAC** — kiosk re-runs the manifest **delta** ("this build added
   `/admin/settings` — who can reach it?") so an update can't silently open a route
   (see `app-contract-and-detection.md`).
4. **Deploy** — kiosk calls the **Coolify API** to point the app at the new image
   tag and redeploy (`/applications/{uuid}/start`). Coolify does a **health-checked,
   zero-downtime rollout**: the new container must pass its health check before
   traffic cuts over; if it fails, the old one keeps serving.

## Rollback
Every build is an **immutable tag in the registry**, so rollback = **redeploy a
prior tag** via the API. Instant, no rebuild.

## Config / secret changes
Update env via Coolify's env API, then redeploy (same health-checked rollout).

## DB migrations (important caveat)
The platform does **not** auto-migrate. Schema changes are the app's responsibility
— run on startup or via a Coolify **Scheduled Task**. Note the asymmetry: an image
rollback reverts **compute**, but **data/schema changes don't roll back** — use
forward-fix migrations, not rollback, for schema.

## Platform-service updates
The platform's own services (kiosk, litellm, oauth2-proxy, authz, sqld) are
Coolify-managed apps — updated by the same build→push→deploy flow. Coolify itself
self-updates. Base-image allowlist is bumped centrally.

## Security ties
Updates traverse the **same** build→scan→manifest-recheck→deploy pipeline as first
deploys, so the allowlist, Trivy scan, and default-deny RBAC apply to every update
(no "update bypass" of the controls).
