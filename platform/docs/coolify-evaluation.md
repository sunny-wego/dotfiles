# Coolify evaluation

Status: **planning**. How much Coolify simplifies the platform, re-assessed under
the **trusted-internal, accident-hardened** trust model.

## Verdict: strong fit (~60–70% of the plumbing)
Under the earlier *adversarial* model, Coolify was a partial win with a sharp
caveat — it can't cleanly do per-app gVisor, isolated builds, or strict per-tenant
networks. **Those are exactly the things the accident-hardened model no longer
needs**, so the caveat evaporates and Coolify becomes a near-turnkey substrate.

## What Coolify replaces (your remaining safety rails + plumbing)
| Our piece | Coolify |
|---|---|
| Traefik ingress + TLS + custom/wildcard domains | ✅ built-in |
| Build pipeline (Dockerfile) | ✅ built-in (on its Docker daemon — fine now) |
| `docker run` + labels + networks + rollback + zero-downtime | ✅ managed lifecycle |
| socket-proxy orchestration | ✅ Coolify owns the daemon |
| Env/secret storage per app (encrypted at rest) | ✅ |
| Cron (Ofelia) | ✅ scheduled tasks |
| Postgres/Redis provisioning | ✅ one-click |
| Per-container CPU/memory limits | ✅ (the core anti-accident control) |
| Logs, health checks, deploy history | ✅ |
| Multi-server scale-out | ✅ |
| API to drive provisioning | ✅ — kiosk calls Coolify's API, not Docker directly |

## What stays yours (the differentiated core — Coolify covers none of it)
- Non-technical **kiosk UX** (ZIP-drop, auto-detect, plain-English summary, toggles).
- **LLM Dockerfile generation + build-verify-heal loop.**
- **LiteLLM multi-tenant gateway** (virtual keys, budgets, tenant-scoped cache).
- **End-user RBAC for the deployed apps** (Authelia + default-deny + confirmed
  manifest). Coolify's RBAC governs *its own dashboard*, not app end-users.
- **Per-tenant sqld namespaces** + tenant↔db mapping.
- **Detection / LLM-generated probe scripts / manifest.**

## What you still layer on top (cheap, now compatible)
The accident-model hardening that Coolify doesn't provide but that composes fine:
- **Resource limits** — Coolify supports these directly. ✅
- **Per-tenant network** — map each app to a Coolify project/network for accidental
  cross-tenant isolation (verify Coolify's networking supports the split).
- **IMDSv2 hop-limit** — EC2 host setting, outside Coolify. ✅
- **Default-deny RBAC** — your Authelia layer in front of Coolify-managed apps.
- **Build timeout** — Coolify build settings.

Dropped entirely (not needed): gVisor runtime, rootless/Kaniko build sandbox,
strict egress allowlist/anti-spoofing.

## Recommendation
Adopt Coolify as the **deploy substrate**; keep the kiosk / LLM / RBAC / DB layer
as your product calling its API. Confirm two things during a short spike:
1. Coolify **API** covers programmatic create/deploy/env/domain/cron end-to-end.
2. Coolify networking allows a **per-app/per-project network** for accidental
   cross-tenant isolation.

If both hold, Coolify removes the boring, well-understood ~60–70% and you build
only the differentiated core.

## Parity note
Coolify runs on a Linux server; for local dev it runs inside the **Colima** VM
(heavier than a bare `docker compose up`, but the same substrate as EC2 → true
parity). Alternatively keep the hand-rolled compose for local dev and Coolify for
remote — but running Coolify both places maximizes parity.
