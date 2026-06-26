# Handler: resilience

What happens when things fail — timeouts, 5xx, partial failure, exhausted
retries. Runs when the diff has any external call, error branch, or new failure
mode.

**Owns:** unhandled failure paths, fail-open vs fail-closed choices, retry/backoff
behavior, timeout budgets, blast radius of a misconfig, work done synchronously
in a latency-bound path, error swallowing, partial-failure cleanup.
**Not this:** the happy path (→ correctness), the race itself (→ concurrency).

## What to look for
- **Synchronous work in a bounded window:** heavy I/O (token mint, external API,
  multi-hop DB) done inside a request that has a hard external deadline. E.g. a
  webhook handler doing a 10s-timeout API call inside GitHub's ~10s delivery
  budget → the receiver itself times out. Prefer ack-fast-then-async.
- **Failure → wrong status → bad downstream behavior:** returning a 5xx where the
  caller will retry, when the work is already committed (ties to idempotency); or
  a missing-config branch that 500s on *every* request and trips an auto-disable
  (GitHub disables a webhook after sustained 5xx) → whole-system outage from one
  unset value.
- **Fail-open vs fail-closed:** on error, does it skip safely or proceed
  dangerously? Is that the choice we want here?
- **Retry/backoff:** infinite or unbounded retries; retry without backoff;
  retrying a non-idempotent op.
- **Partial failure:** multi-step work that leaves state half-written when step N
  fails; no compensating cleanup.
- **Error swallowing:** broad `except`/`catch` that hides the failure and
  continues as if it succeeded.

## How to verify (Tier 1)
- Drive the failure branch: make the dependency raise/timeout (monkeypatch or a
  stub) and observe the status/behavior; capture it → `confirmed`. (PR-223's
  502-on-transient-failure was confirmed this way.)
- Latency/timeout-budget and auto-disable claims usually can't be reproduced
  locally → `hypothesis`, with `verify` naming the measurement (e.g. "measure p99
  of this path" / "confirm GitHub's disable-on-5xx threshold").

## Emit
`concern` = the failure mode and its blast radius; `question` asks whether that
failure shape (drop / 5xx-storm / fail-open) is intended. Weight `severity` by
blast radius, not by how easily it reproduces.
