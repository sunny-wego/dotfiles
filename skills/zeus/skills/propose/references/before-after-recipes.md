# Before/after recipes

When a section shows a *change*, a fenced block almost always beats prose. Pick
the form below, then copy a template. Same spirit as `diagram-recipes.md`: only
use one when there's a concrete change to show — don't dress up prose as a diff.

## Pick a form

| Source describes | Use |
|---|---|
| Small structural delta to config / properties / schema fields (a few lines; the *change* is the point) | **```diff fence** — `+`/`-` lines render red/green |
| Two substantial blocks (full type def, function body) where a unified diff would be noisy | **Twin labeled fences** — `// BEFORE` … `// AFTER` |
| Many small field-level rows, no code | **Side-by-side table** — Before / After columns |
| Non-structural change | Prose |

**Default lean:** diff fence for ≤ ~12-line property/config/schema deltas; twin
fences when each side reads top-to-bottom as one coherent block; table for > 4
short field rows.

Don't reach for a delta block when nothing structural changes — a sentence is
fine. A `diff` fence with no `+`/`-` lines is a misused delta (the validator
soft-warns on it).

## Recipe 1 — delta (` ```diff `)

For property panels, env vars, config keys, small schema-field changes. Context
lines stay unmarked; `+` marks additions, `-` removals; `#` lines label the
BEFORE / AFTER halves and call out the salient line.

````md
```diff
  # BEFORE — single value in the canonical field
  Booking ID (Automated):       WF123
  PNR (Automated):              ABC

  # AFTER — canonical field = the acted record; the rest in a new field
  Booking ID (Automated):       WF456            # the acted booking
  PNR (Automated):              XYZ
+ Related Bookings (Automated):
+   ▶ WF456 · TICKETINPROCESS · JED→CAI 02 Apr   # acted
+     WF123 · TICKETED · DXB→LHR 23 Mar
```
````

## Recipe 2 — twin fences (BEFORE / AFTER)

For two substantial code blocks where a unified diff would be hard to read. Put
both in one `lang` fence with comment headers, or two adjacent fences. End with
the one-line takeaway (what actually moved).

````md
```ts
// BEFORE — input read from the projection (single slot, written pre-decision)
const pnr = unwrap(caseProps[EF.pnr]) ?? "";        // file.ts:159

// AFTER — input read from the decision (the record the agent chose)
const chosen = retrieval.records.find(r => r.ref === action.args.ref);
const pnr    = resolvePnr(chosen);
```
Same downstream call — only the *source* moved.
````

## Recipe 3 — side-by-side table

For many small field-level changes where code would be noise.

````md
| Field | Before | After |
|---|---|---|
| `pnr` | `caseProps[EF.pnr]` | the decision (acted record) |
| `status` | `caseProps[EF.status]` | the decision; re-query source if stale |
````

## Interactions (so the block behaves)

- **`pin-refs.sh` leaves fenced refs alone.** A `file.ts:NNN` inside a diff or
  twin-fence stays illustrative shorthand — it is *not* rewritten to a
  permalink. That's intended: keep the inline ref short, and put the
  authoritative, SHA-pinned citation in `code_grounding` (renders in the
  collapsed appendix).
- **`validate-draft.sh`'s table-ref warning does not fire inside fences.** It
  only flags code refs in *table cells* outside `<details>`. Diff/code blocks
  are safe — don't try to "fix" a warning that isn't there.
- **Collapse long blocks under `<details>`** per `section-patterns.md`, so the
  visible layer stays scannable. A short delta (≤ ~12 lines) can sit inline; a
  full payload or function before/after should be collapsed.
