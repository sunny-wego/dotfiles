# The coherence reader

`evidence-add.sh` lints the reproducibility contract in **form** — bounded queries, SHA-pinned refs,
a `recorded` label where the source expires. It cannot judge **meaning**: a perfectly-bounded query
whose *reading doesn't follow from the result*, an evidence item that silently *contradicts an earlier
one*, or a Summary that *overstates what actually shipped*. Those are the failures that survive
incremental review and corrupt the record. The coherence reader is the cheap, automatic backstop for
exactly that gap — the report equivalent of a fresh human reviewer reading the whole doc cold.

It is the same idea as propose's RFC reader test, with two deliberate differences: it reads the
**report doc** (not an alignment issue), and it is a **recommended step, not a hard gate** —
nothing refuses to let you close (see "Why this isn't enforced").

## When to run it

- **At resolve / finalize** — the once-per-investigation moment the doc stops growing. This is the primary
  home (SKILL.md → Mode: resolve).
- **On an amendment** — the "correct in place with a dated amendment" path (evidence step 4) is the
  highest-risk-of-contradiction edit; a quick pass over the affected items is worth it.

Do **not** run it on every `evidence` append. That fights the skill's incremental, GitHub-does-the-work
design and adds a subagent round-trip to every finding for little gain — the contract lint already
gates each append's form, and coherence is a property of the *whole* record, best checked once.

## Procedure

Spawn a **fresh subagent** (Task tool) and give it *only* the rendered report body — no
conversation context, no access to the investigation. Ask it to answer, from the doc alone:

1. **What failed, and what's the headline root cause?** (Can a cold reader even extract the story?)
2. **Claim ↔ evidence coherence** — for each evidence item `E<n>`: does the *Reading* actually follow
   from the captured result, or does it assert more than the numbers show?
3. **Cross-evidence contradiction** — do any two evidence items, or an item and the Summary / root
   cause / Candidates-ruled-out table, disagree?
4. **Overstatement** — do the `Summary`, `Root cause`, and `Prevention → Done` claims respect the
   contract's reasoning rules the lint can't see:
   - rate-normalised comparisons over commensurate windows (rule 6),
   - "merged ≠ in production" for anything claimed live (rule 4),
   - task progress vs outcome progress kept separate (rule 5),
   - no derived field used as an independent observation (rule 7)?
5. **What's unclear, unsupported, or self-contradictory?**

## Output contract (shared with the family's other fresh-reader passes)

Require the reader to end with a **`VERDICT: READY | BLOCKED`** line plus severity-tagged, numbered
gaps — the same contract as propose's Stage-1 reviewer simulation (see
`.vendor/CONVENTIONS.md` → Verification patterns). A defined verdict gives the loop a stop condition:
without one, "looks fine overall" and "two real contradictions" both read as prose, and the author
decides when to stop by vibes.

## What counts as a gap

A wrong or uncertain answer, any "can't tell from the body", a detected contradiction, or an
overstated claim. For each gap, fix the **evidence item or the section** (not the reader's wording) and
re-run the reader. Loop until the verdict is READY.

## Why this isn't enforced

propose's reader test is `post-issue.sh`-enforced because an RFC has an external gate-keeper — a
reviewer must sign off before the decision holds. A report has no such gate-keeper; it is a record
you own. So this stays **judgment**: run it because a fresh reader catches the overstated win or the
self-contradictory claim that incremental review missed — not because a script blocks the close. If it
ever needs to become a hard gate, that's a deliberate later decision, not the default.
