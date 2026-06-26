# Handler: tests

Whether the change is *guarded*, not whether it's correct. Runs on every code
change.

**Owns:** missing coverage of the changed paths, tests that stub away the very
risk they appear to cover, missing failure-case/edge-case tests, assertions that
don't assert the behavior that matters, flaky patterns.
**Not this:** whether the code is correct (that's the other handlers) — this lens
asks "if this broke, would a test catch it?"

## What to look for
- **Stubbed-away risk:** a test that mocks the dependency whose failure is the
  actual concern, so the risky path never runs. (PR-223's handler tests stub
  `run_followup` to *return*, never to *raise* — so the 502/dedup-loss path has
  no coverage and the bug ships green.) Whenever another handler files a finding,
  ask: is there a test that would have caught it? If not, that gap is a finding
  here.
- **Coverage of new branches:** new error branch, new condition, new event type —
  is each exercised? Or only the happy path?
- **Edge cases:** empty/None/zero/boundary inputs the change introduced.
- **Assertion quality:** tests that call the code but assert nothing meaningful
  (status only, not the effect), or assert on a mock instead of the outcome.
- **Migrations:** is there an up/down round-trip test for a new migration?
- **Flakiness:** time/order/network dependence, shared mutable fixtures.

## How to verify (Tier 1)
- Run the PR's existing test slice for the changed area; note what passes and what
  isn't covered. A coverage tool, if present, makes the gap concrete → `evidence`.
- Demonstrate the blind spot: show that the risky path (e.g. the dependency
  raising) has no test by grepping the tests for that scenario. This is usually a
  factual, confirmable gap → `confirmed` when you can point at the absence.

## Emit
`concern` = the unguarded path and why it matters; `question` asks whether that
path is intended to be covered. Usually `severity: medium` (a latent bug waiting
to regress), higher when it masks a confirmed finding from another handler.
Cross-reference the related finding's `id` in `reasoning` when applicable.
