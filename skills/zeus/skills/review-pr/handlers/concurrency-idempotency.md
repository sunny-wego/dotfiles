# Handler: concurrency-idempotency

Races, ordering, and exactly-/at-least-/at-most-once behavior. Runs when the diff
touches shared state, queues, webhooks, retries, dedup, background tasks, or locks.

**Owns:** lost updates, check-then-act races, dedup keyed on the wrong thing,
retry × side-effect interactions, ordering assumptions, double-processing, missing
locks, idempotency-key scope.
**Not this:** single-threaded logic (→ correctness), the handling of one failure
(→ resilience).

## What to look for
- **Claim/commit ordering vs. side effect:** is the dedup/idempotency row
  committed *before* the real work? If the work then fails and the caller
  retries, is the retry deduped away and the effect lost? (This is the PR-223
  dedup-before-process bug — a transient 502 after the claim drops the event.)
- **Idempotency key scope:** does it key on the *delivery/request* when the thing
  to protect is the *effect*? Two distinct requests for the same logical action
  can both pass a per-request key and both fire (e.g. a review event + a comment
  event for one PR → two concurrent agents on one branch).
- **In-flight guard:** is there anything stopping a second operation from
  starting while the first is still running for the same entity? Counting
  ancestors/history is not the same as counting in-flight siblings.
- **Check-then-act:** read-decide-write without a lock or atomic upsert; two
  callers both read the "safe" state and both proceed.
- **Ordering:** code that assumes events arrive in order, or that a later event
  can't be processed before an earlier one.

## How to verify (Tier 1)
- Drive the handler twice with the same id through the real dedup path (in a
  throwaway DB) and show the second is dropped — or fire two distinct ids for the
  same entity and show two effects. Capture output → `confirmed`. (This is exactly
  how the PR-223 dedup bug was confirmed: fresh-id first attempt 502, retry 200
  "duplicate delivery".)
- True concurrency (two simultaneous requests) is often not cheaply reproducible
  → `hypothesis` with a concrete two-request `verify` recipe and `severity` set by
  impact, not by reproducibility.

## Emit
`concern` describes the race/lost-effect and its trigger; `question` asks what
guarantees single-execution / correct dedup scope. Set `severity` by blast radius
(data loss / duplicate side effect = high) regardless of `status`.
