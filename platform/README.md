# Self-serve internal app platform

A single-box, `docker compose`-up platform where non-technical creators drop a
ZIP and get a hosted, authenticated, optionally-LLM-powered internal app — with
a per-tenant database, cron, and RBAC — running identically on a laptop and on
an internal EC2 box.

This directory currently scaffolds the **LLM layer** (the piece that makes each
tenant able to be an LLM app). The rest of the stack is wired in
`docker-compose.yml` and filled in as it's built.

## What's here

| Path | Role |
|------|------|
| `docker-compose.yml` | The whole platform stack. `up` starts the control plane + shared services; tenant apps are launched *dynamically* by the control plane, not defined here. |
| `litellm/config.yaml` | LiteLLM gateway: OpenRouter upstream, model aliases, tenant-scoped Redis cache. |
| `litellm/hooks/tenant_cache.py` | Forces a per-tenant cache namespace so tenants never share cached completions. |
| `control-plane/src/provisionLlmApp.ts` | Detects an LLM app, mints a per-tenant LiteLLM virtual key (budget + limits + model allowlist), injects gateway env vars, strips hard-coded keys. |
| `postgres/init/01-databases.sql` | Creates the `litellm` and `authelia` sidecar databases. |
| `.env.example` | The only thing that differs between local and remote. |
| `docs/` | Planning decision records: `isolation-and-scaling`, `secrets`, `app-contract-and-detection`, `user-journey`, `coolify-evaluation`. |

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

## Security notes (single-box)

- `control-plane` talks to Docker only through `docker-socket-proxy`, never the
  raw socket.
- On the internal EC2 box, allow outbound HTTPS to `openrouter.ai` **only**.
- Per-tenant network segmentation (tenant A can't reach tenant B or the
  datastores directly) is a hardening follow-up — today `web` + `backplane` is
  the coarse split.
