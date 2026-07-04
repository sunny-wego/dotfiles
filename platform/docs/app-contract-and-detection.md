# App contract & detection — how we apply RBAC without restricting authoring

Status: **planning**. Answers: do we need to restrict how apps are written to
apply RBAC and detect features reliably? Decision: **no hard authoring
restrictions — constrain enforcement (fail-closed), not authoring.**

## Principle
> Constrain the **enforcement** (fail-closed at app-independent layers), not the
> **authoring** (apps stay free). Use conventions + multi-signal agent analysis
> + a confirmed manifest to make detection *accurate*, and default-deny to make
> detection *misses safe*.

## 1. The security guarantee comes from fail-closed, not detection
RBAC is a security boundary, so it must **fail closed**:
- **Default-deny at the proxy** + an explicit, confirmed **allowlist** of
  role→path rules. A route the platform *fails to detect* is **denied**, not
  exposed. Detection accuracy becomes a friction concern, not a correctness one.
- Authentication (login required), network isolation, and secret isolation are
  all enforced at layers that **don't need to understand the app**.

## 2. Detection = multi-signal agent analysis (raises accuracy / lowers friction)
Three signals, cross-checked (implemented as kiosk agent skills):
1. **Static** — parse the framework's routes/decorators (Next.js App Router,
   Express, FastAPI); enumerate routes, methods, env/secret refs, DB calls.
2. **Dynamic** — during the `runsc` boot/verify step, crawl the live app to
   enumerate reachable endpoints (catches routes static analysis misses).
3. **LLM semantic** — classify route sensitivity (admin/write/read); propose the
   role→path map in plain English.

**Reconcile:** all agree → auto-propose (high confidence); disagree/uncertain →
flag for creator confirmation with a confidence score. Unclassified → denied.

Skills: `route-mapper` (static+dynamic), `rbac-proposer`, `env-secret-detector`,
`dockerfile-gen+heal`, `twelve-factor-linter`.

## 3. Conventions (recommended, not mandated; agent normalizes non-conformers)
Non-conforming apps still deploy — lower auto-confidence / more prompts, or the
agent refactors them (transformation, not restriction):
- **12-factor:** config via env, listen on `$PORT`, stdout logging, stateless
  (persist to DB/object store, not local disk), a health endpoint for verify.
- **Conventional router** so routes are statically analyzable; avoid opaque
  dynamic route generation.
- **Don't roll your own auth** — read injected `Remote-User`/`Remote-Groups` for
  fine-grained checks; the gateway owns authentication.
- **No secrets in code** — sanitizer strips them, but clean input detects better.

Agent transformations: missing `$PORT` → rewrite; hardcoded secret → extract to
env; no health endpoint → inject; no manifest → generate.

## 4. Confirmed manifest = source of truth
Analysis distills into a generated **manifest** (routes, role→path rules, port,
secrets, cron) the creator confirms/edits in plain language. Once confirmed it's
authoritative and deterministic — the proxy enforces *that*, not a fresh guess.
On redeploy, re-analyze and surface only the **deltas** (e.g. "new `/admin/settings`
— who can reach it?") so drift can't silently open a hole.

## Open item
Fine-grained (row/field-level) RBAC guarantee — coarse path/method + default-deny
is the current stopping point; intra-tenant data-level rules remain the
LLM-proposed / app-cooperative path noted in earlier RBAC discussion.
