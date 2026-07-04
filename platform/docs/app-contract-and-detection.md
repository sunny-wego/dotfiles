# App contract & detection — how we apply RBAC without restricting authoring

Status: **planning**. Answers: do we need to restrict how apps are written to
apply RBAC and detect features reliably? Decision: **no hard authoring
restrictions — constrain enforcement (fail-closed), not authoring.**

## Principle
> Constrain the **enforcement** (fail-closed at app-independent layers), not the
> **authoring** (apps stay free). **No source modification (no codemods).** Use
> conventions + multi-signal agent analysis + a confirmed manifest to make
> detection *accurate*, and default-deny to make detection *misses safe*.

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
2. **Dynamic — LLM-generated ephemeral probe/observer scripts** (NO source edits).
   During the `runsc` verify step, run against a throwaway instance:
   - *Black-box probe:* LLM-generated, framework-tailored script hitting candidate
     endpoints (seeded by static analysis) to enumerate reachable routes/methods,
     incl. dynamically-registered ones.
   - *Non-invasive observer (optional):* a platform preload (`NODE_OPTIONS=--require`
     / Python import hook) that only *observes* — logs the registered route table,
     env reads, DB/outbound calls. Records, never rewrites.
   Guardrails: the generated script is treated as untrusted (runs under the same
   gVisor + per-tenant net + egress-block sandbox as tenant code); ephemeral
   (generated → run once → output captured → discarded); never shipped in the
   image or the request path; feeds the manifest only. Coverage gaps are safe —
   default-deny protects any route the probe didn't reach. Re-run on redeploy for
   deltas.
3. **LLM semantic** — classify route sensitivity (admin/write/read); propose the
   role→path map in plain English.

**Reconcile:** all agree → auto-propose (high confidence); disagree/uncertain →
flag for creator confirmation with a confidence score. Unclassified → denied.

Skills: `route-mapper` (static+dynamic), `rbac-proposer`, `env-secret-detector`,
`dockerfile-gen+heal`, `twelve-factor-linter`.

## 3. Conventions (recommended, not mandated; handled WITHOUT editing source)
Non-conforming apps still deploy — lower auto-confidence / more prompts. The
platform adapts via **detection + runtime config**, never by rewriting source:
- **12-factor:** config via env, stdout logging, stateless (persist to DB/object
  store, not local disk).
- **Conventional router** so routes are statically analyzable; opaque dynamic
  routing just lowers confidence (probe + default-deny still cover it).
- **Don't roll your own auth** — read injected `Remote-User`/`Remote-Groups` for
  fine-grained checks; the gateway owns authentication.

Handled by config/detection, not codemods:
- **Port** → detect the listen port, point Traefik at it.
- **Health check** → probe the TCP port / `HEAD /` if no endpoint exists.
- **Hardcoded secret** → **detect + flag/block, never rewrite.** Blast radius is
  contained: the platform's keys are never given to the app (LLM access is a
  scoped virtual key via env), so a creator's hardcoded third-party key only
  risks their own isolated app.
- **Manifest** → generated from analysis (see §4), not injected into source.

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
