# Self-serve internal app platform

A platform where non-technical creators drop a ZIP and get a hosted,
authenticated, optionally-LLM-powered internal app — with a per-tenant database,
cron, and RBAC — running identically on a laptop (Colima) and an internal EC2 box.

**Engine: Coolify** (Apache 2.0) owns ingress/TLS/domains, build, container
lifecycle, cron, env/secrets, resource limits, rollback, and multi-server
placement. We build the **kiosk / LLM / RBAC** layer on top via Coolify's API.
See `docs/coolify-evaluation.md` for the verified architecture + operating rules.

This directory scaffolds the **LLM layer**; the rest is planning docs.

## What's here

| Path | Role |
|------|------|
| `docker-compose.yml` | The **platform services** (kiosk, litellm, authelia, sqld, postgres, redis). Deploy as a Coolify resource or run locally. Tenant apps are created via the Coolify API, not here. |
| `litellm/config.yaml` | LiteLLM gateway: OpenRouter upstream, model aliases, tenant-scoped Redis cache. |
| `litellm/hooks/tenant_cache.py` | Forces a per-tenant cache namespace so tenants never share cached completions. |
| `control-plane/src/provisionLlmApp.ts` | Detects an LLM app, mints a per-tenant LiteLLM virtual key, injects gateway env vars, flags hard-coded keys. |
| `postgres/init/01-databases.sql` | Creates the `litellm` and `authelia` sidecar databases. |
| `.env.example` | Kiosk + engine config; only this differs local↔remote. |
| `docs/` | Planning decision records: `coolify-evaluation`, `isolation-and-scaling`, `secrets`, `app-contract-and-detection`, `user-journey`. |

## Operating rules (from the Coolify verification)

1. Tenant apps deploy **as images, not compose** (keeps custom RBAC labels).
2. Kiosk **builds the image → pushes to registry → Coolify deploys it** (immutable).
3. **One Coolify Destination per tenant** for network isolation.
4. **libSQL/sqld namespaces (or SQLite on a volume)** for cheap per-tenant DB;
   Postgres-per-tenant only on demand (~50–100× the RAM at fleet scale).

## Trust model

**Trusted-internal, accident-hardened** — tenants are trusted colleagues; the
threat is *accidental bad code*, not malice. Keep all blast-radius controls
(resource limits, quotas, LLM budgets, default-deny RBAC, secret encryption,
backups); drop the anti-malice hardening (gVisor, rootless-build sandbox, strict
egress). Standard `runc` everywhere → trivial laptop↔EC2 parity, and Coolify is a
viable turnkey substrate. See `docs/isolation-and-scaling.md`.

## LLM traffic model

```
kiosk (Dockerfile gen) ─┐
                        ├─► litellm ──► OpenRouter ──► providers
tenant app 1 ───────────┤   (virtual keys, budgets,
tenant app N ───────────┘    tenant-scoped cache, spend log)
```

- The **OpenRouter master key lives only in the `litellm` container.** Tenants
  never see it — they get a scoped virtual key pointing at the internal gateway.
- Each tenant key carries `metadata.tenant_id`, used for cache isolation and
  per-tenant spend metering/billing.
- Both `OPENAI_*` and `ANTHROPIC_*` SDK env vars are pointed at the gateway, so
  whichever SDK the creator's app uses, it routes through governance.

## Tenant-scoped cache — verify once

`hooks/tenant_cache.py` sets a per-request `cache.namespace` of `tenant:<id>`.
Confirm against your pinned LiteLLM image with a two-tenant identical-prompt
test. If your version ignores per-request namespacing, the guaranteed-safe
fallback is to mint tenant keys with caching disabled (cache only the kiosk key).

## Isolation notes (trusted-internal, accident-hardened)

- Threat is *accidental bad code*, not malice: keep blast-radius controls
  (per-app limits, quotas, LLM budgets, default-deny RBAC, secret encryption,
  backups); drop anti-malice hardening (gVisor, rootless-build sandbox, strict
  egress). Standard `runc`.
- **Per-tenant network isolation = one Coolify Destination per tenant.**
- On EC2: IMDSv2 hop-limit 1 (near-free); allow egress to `openrouter.ai`.
- Sensitive/customer-data or internet-facing apps are the trigger to re-harden
  that app (gVisor / graduate to microVM). See `docs/isolation-and-scaling.md`.
