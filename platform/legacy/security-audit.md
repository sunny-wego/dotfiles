# Security audit & fixes

Status: **planning**. Architectural audit of the design (no code yet). Verdict:
secure *for the stated trust model* (trusted-internal, accident-hardened) once the
Coolify-friendly fixes below land — with two "arbitrary code on the shared host"
risks and a customer-data policy left as accepted/contained (gVisor excluded to
keep Coolify simple).

## The structural tension (central finding)
The trust model assumes *authors are trusted, threat is accidents*. But the pipeline
feeds **untrusted, LLM-interpreted input into privileged operations**: the ZIP's text
is read by an LLM that generates a Dockerfile we build and run, and even a trusted
author's app can be compromised via a dependency. So "trusted authors" does not cover
the ingestion pipeline — hence the fixes below apply regardless of trust.

## Findings + fixes, by where the fix lives
Legend: 🟦 Coolify-native · 🟩 config on a service we already run · 🟨 kiosk logic ·
🟥 accepted/contained (needs gVisor to eliminate)

| # | Finding (sev) | Fix | Where |
|---|---|---|---|
| 1 | Build-time RCE — LLM Dockerfile from untrusted ZIP, unsandboxed build (**high**) | base-image **allowlist** (validate `FROM`) + **Trivy scan** before deploy; full elimination = bespoke rootless builder (deferred) | 🟨 + 🟥 residual |
| 2 | sqld admin unauth + reachable → cross-tenant DB (**high**) | admin auth key; **per-namespace-scoped tokens**; sqld on internal net | 🟩 + 🟦 |
| 3 | Kiosk crown jewel (Coolify + LiteLLM master tokens) (**high**) | **least-privilege Coolify token**; kiosk behind oauth2-proxy; per-user provisioning quotas | 🟦 + 🟨 |
| 4 | Relaxed egress → lateral movement / SSRF (**high**) | Destination-per-tenant; **platform services reached only via Traefik hostnames** (LLM gateway + own DB) so tenant nets hold no datastores; host default-deny egress | 🟦 + 🟩 |
| 5 | Header spoofing of `X-Auth-*` (**med**) | Traefik **headers middleware strips inbound `X-Auth-*`**; ports unpublished | 🟦 |
| 6 | authz fail-open / path bypass / stale cache (**med**) | **fail-closed**; path canonicalization; cache-invalidate on role change | 🟨 |
| 7 | Postgres RLS owner bypass (**med**) | non-owner role + `FORCE ROW LEVEL SECURITY`; deny when `app.user` unset | 🟨 on 🟦 PG |
| 8 | Over-permissive manifest (rubber-stamp) (**med**) | most-restrictive default; explicit opt-in to widen; loud "public" warning | 🟨 |
| 9 | Cross-tenant LLM cache leak (**med**) | verify tenant cache-namespace hook (two-tenant test); else disable tenant caching | 🟩 |
| 10 | Customer data → OpenRouter + wrong tier (**med**) | OpenRouter provider filtering + ZDR; **policy: customer-data apps don't run here** | 🟩 + 🟥 policy |
| 11 | Zip-slip / zip-bomb (**med**) | safe extract: reject `../`, cap size/ratio/count | 🟨 |
| 12 | Secrets blast radius (**med**) | least-priv token; block deploy on hard-coded secret; no build args | 🟦 + 🟨 |
| 13 | Probe scripts mutate/leak (**med**) | disposable verify instance + throwaway DB; read-oriented probes | 🟨 |
| — | Cookie hardening, offboarding cleanup, dep scan (**low**) | oauth2-proxy config; kiosk cleanup of stale email→role | 🟦 + 🟨 |

**Nothing above needs new infrastructure** — Coolify features, config on the four
services we already run (sqld, LiteLLM, authz, Postgres), or kiosk logic. Near-zero
marginal maintenance.

## The Coolify-friendly network move (#4)
Expose the **LLM gateway** and each app's **DB endpoint** as **Traefik hostnames**
(`OPENAI_BASE_URL=https://llm.internal/…`, sqld over an HTTPS route). Tenant
Destinations then hold **no datastores**; apps reach platform services only through
the proxy (which auths/scopes). Pure Coolify (Destinations + routes); closes most
lateral movement without a bespoke network layer.

## Left unfixed without gVisor (accepted + contained)
| Residual | Why | Containment |
|---|---|---|
| Build-time RCE on build host (#1) | real sandbox is bespoke; Coolify builds unsandboxed | allowlist + Trivy scan; same class as escape |
| Container escape → host → tenants | shared kernel, no gVisor | blast radius limited by #4 segmentation |
| Customer-data apps need stronger isolation (#10) | hardened tier == gVisor (excluded) | **policy: don't host customer-data apps here** |

To *eliminate* rather than contain the first two = gVisor + rootless build, which
trades away Coolify simplicity. Consistent choice under this trust model:
**contain, don't eliminate** — and record build-RCE + escape as accepted risks.

## Highest-leverage fixes (do these first)
1. **Base-image allowlist + Trivy scan** (🟨, cheap) — mitigates the worst hole (#1).
2. **Network segmentation via Traefik-hostname platform access** (🟦) — #4, enables #2, shrinks #3/#12.
3. **Hardened ingress: strip `X-Auth-*` + fail-closed authz + path canonicalization** (🟦+🟨) — #5, #6, backs #8.
