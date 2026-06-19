# Code in issues

Include code only when it **reduces ambiguity**. A snippet earns its place if it makes the decision clearer, more aligned, or more verifiable; otherwise it's noise that buries the decision.

> If removing the code increases ambiguity, keep it.
> If removing the code changes nothing, delete it.

## Include
- **API / contract shapes** — function signatures, request/response, schema fields (the *shape*, not the implementation).
- **Data models & state transitions** — what the persisted/serialized thing looks like, and the states it moves through.
- **Invariants / gate conditions** — the binary rules an implementing agent must honor (e.g. a denylist predicate, a uniqueness rule).
- **Before/after deltas** — the change itself, via `before-after-recipes.md`. This is usually the highest-signal code an issue can carry.

## Avoid
- Production-ready implementations, large diffs, framework glue — that belongs in the PR, not the decision doc.
- Code that restates prose already above it.
- Whole-file pastes when a few lines + an ellipsis convey the shape.

## Keep it scannable
- Collapse anything beyond ~12 lines under `<details>` (house style — visible layer stays a decision, not a listing).
- Cite real code by `path:line` in the `code_grounding` appendix (SHA-pinned), not inline in the prose — illustrative snippets inside code fences are left as shorthand on purpose (`pin-refs.sh` doesn't touch fences).
- Prefer the shape over the detail: `args: { pnr: string, bookingRef?: string }` says more, faster, than 40 lines of the real function.
