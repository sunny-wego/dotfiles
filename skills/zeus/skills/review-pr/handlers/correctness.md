# Handler: correctness

Logic, data flow, and control flow of the changed code. The default lens — runs
on any code change.

**Owns:** wrong results, off-by-one, inverted conditions, wrong defaults, dead or
missing branches, mishandled None/empty/zero, equality/identity bugs, incorrect
string/number parsing, comparison on the wrong field.
**Not this:** races (→ concurrency), error/timeout paths (→ resilience), payload
shape assumptions (→ api-contract), authz/secrets (→ security).

## What to look for
- **Identity & equality:** values compared by a reconstructed/normalized form
  that can drift (e.g. matching on a rebuilt URL string instead of a stable key).
  Trace both sides — do they always produce byte-identical values?
- **Boundary & empty cases:** first/last element, empty list, zero, negative,
  missing key. What does the code do when the collection it indexes is empty?
- **Default values:** a default that silently changes behavior (a flipped bool
  default, a fallback that masks a real value).
- **Control flow:** an early return / `continue` / `break` that skips needed
  work; a branch that can never be reached; an `else` that swallows a case.
- **Data flow:** follow the value end-to-end. Correct in isolation ≠ correct in
  context — the bug is often where a correct function is called with the wrong
  argument or its result is ignored.

## How to verify (Tier 1)
- Write a focused unit test in the repo's framework that feeds the
  boundary/empty/identity input and asserts the claimed wrong result; run it.
  Capture steps + failing output as `evidence` → `confirmed`.
- Or drive the function with a one-off probe in the repo's language
  (`python3 -c`, `node -e`, `go run`, a scratch `cargo`/`jshell`) — see the
  stack table in `references/review-contract.md`.
- Can't isolate it cheaply → `hypothesis` with the exact input to try in `verify`.

## Emit
Per `references/review-contract.md`: `concern` states the wrong behavior (not the
fix), `question` asks what guarantees the correct value, `fix_aside` optional.
DROP anything equally true on the base branch.
