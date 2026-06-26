# Handler: api-contract

The contract at boundaries — what comes in, what goes out, and the assumptions
made about external shapes. Runs when the diff touches request/response handlers,
serializers, event parsing, external-API calls, or identity/keys.

**Owns:** payload-shape assumptions, fields assumed present/non-empty, identity &
key choices, versioning / backward-compat, external-API behavior assumptions,
status-code contracts, pagination, enum/union handling.
**Not this:** internal logic (→ correctness), the failure path itself (→ resilience).

## What to look for
- **Assumed-present fields:** code that reads `payload[x][y]` or takes the first
  element of an array the provider doesn't guarantee. (PR-223 takes the first of
  `workflow_run.pull_requests`, which GitHub leaves **empty for fork PRs and many
  branch-triggered runs** → the trigger silently never fires.) Ask: under what
  real conditions is this field empty/missing/multi-valued?
- **Identity / key choice:** is the join/lookup key stable and canonical, or a
  reconstructed string that can drift across hosts/formats? (PR-223 matches
  sessions by a rebuilt `github.com/...` URL — breaks on enterprise hosts or any
  format difference.) A natural key like `(repo, number)` is usually sturdier.
- **Backward-compat:** a changed response field/type/status that existing callers
  depend on; a removed/renamed field; a narrowed enum.
- **External-API behavior:** assumptions about ordering, idempotency, rate limits,
  retry semantics, or which events a webhook actually delivers.
- **Status-code contract:** returning a code whose meaning to the caller differs
  from intent (e.g. a 2xx that means "ignored" vs a retryable 5xx).

## How to verify (Tier 1)
- Feed a payload with the field missing/empty/multi-valued through the parser and
  show the outcome (dropped / wrong target). Capture → `confirmed`. (PR-223's
  empty-`pull_requests` → no-follow-up is covered by exactly such a case.)
- Real-world *frequency* of the empty/missing case usually can't be proven locally
  → `hypothesis`, with `verify` naming where to check (sample real payloads / the
  provider's docs).

## Emit
`concern` = the broken/fragile contract assumption; `question` asks what
guarantees the field/shape/host the code assumes — never lead with the key-change
fix. Cite the provider behavior where known.
