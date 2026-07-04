# Self-serve internal app platform

A platform where non-technical creators drop a ZIP and get a hosted,
authenticated, optionally-LLM-powered internal app — with a per-tenant database,
cron, and RBAC — running identically on a laptop (Colima) and an internal EC2 box.

**Engine: Coolify** (Apache 2.0) owns ingress/TLS/domains, build, container
lifecycle, cron, env/secrets, resource limits, rollback, and multi-server
placement. We build the **kiosk / LLM / RBAC** layer on top via Coolify's API.
See `docs/coolify-evaluation.md` for the verified architecture + operating rules.

**This is a design plan — docs only, no implementation code.**

## Docs

| Doc | Contents |
|------|------|
| `docs/coolify-evaluation.md` | Architecture-of-record: Coolify-as-engine, verified findings + API spikes, provisioning flow, operating rules, security requirements. |
| `docs/isolation-and-scaling.md` | Trust model (trusted-internal, accident-hardened), the 5 moves, laptop↔EC2 parity, scale-out path. |
| `docs/secrets.md` | App env/secrets: define → store (Coolify) → inject. |
| `docs/app-contract-and-detection.md` | How RBAC is applied without restricting authoring: fail-closed default-deny + multi-signal detection (incl. LLM-generated probe scripts). |
| `docs/user-journey.md` | End-to-end walkthrough for a stock Next.js app using every feature. |

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

## Tenant-scoped cache — design note

The LiteLLM cache must be namespaced per tenant (`tenant:<id>`) so tenants never
share cached completions. Confirm the chosen mechanism against the pinned LiteLLM
image with a two-tenant identical-prompt test; the guaranteed-safe fallback is to
disable caching on tenant keys (cache only the kiosk's own key).

## Isolation notes (trusted-internal, accident-hardened)

- Threat is *accidental bad code*, not malice: keep blast-radius controls
  (per-app limits, quotas, LLM budgets, default-deny RBAC, secret encryption,
  backups); drop anti-malice hardening (gVisor, rootless-build sandbox, strict
  egress). Standard `runc`.
- **Per-tenant network isolation = one Coolify Destination per tenant.**
- On EC2: IMDSv2 hop-limit 1 (near-free); allow egress to `openrouter.ai`.
- Sensitive/customer-data or internet-facing apps are the trigger to re-harden
  that app (gVisor / graduate to microVM). See `docs/isolation-and-scaling.md`.
