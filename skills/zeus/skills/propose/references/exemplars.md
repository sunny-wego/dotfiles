# Exemplars

Five GitHub issues from `wego/sprinklr-iran-conflict` whose authoring style this skill models. When in doubt, mirror these.

## #632 — cs-agent v1 shadow pipeline

<https://github.com/wego/sprinklr-iran-conflict/issues/632>

**What it demonstrates:**
- **Side-effect contract table** auditing every step in a pipeline (`Side effect | Owner | v1 shadow allowed?`).
- **Mermaid `flowchart TD`** for parallel-flow architecture.
- **What's Excluded** section with explicit rationale per bullet.
- **In-band revisions** — issue body was edited to "v2" / "v3" after review comments instead of opening a new issue.

**Lift these patterns:** any architecture proposal with multiple side-effect paths; any "shadow / fork / parallel" proposal.

## #668 — propose go/no-go gate (4 allow-rules)

<https://github.com/wego/sprinklr-iran-conflict/issues/668>

**What it demonstrates:**
- **Decision matrix Q1..Q5** — each axis gets Option / What it means / Trade-off + a **Default lean** line.
- **Resolved section with verdict table** — each Q gets a verdict and the change it triggered, with shadow-data numbers.
- **Code references pinned to commit SHA** (`blob/6c856f60/.../types.ts#L164-L179`).
- **Behavior cases as JSON snippets** — gate inputs + expected outputs, mirrored 1:1 by unit tests.

**Lift these patterns:** any proposal with multiple decision axes; any "we have data, here's the verdict" follow-up; any matcher / gate / rule-engine spec.

## #672 — booking refs + Wego hotlines, stop masking

<https://github.com/wego/sprinklr-iran-conflict/issues/672>

**What it demonstrates:**
- **Status block at top** (`## Status: PR open — #675`).
- **Behavioural delta table** before / after, surface by surface.
- **Mermaid `flowchart LR`** with `classDef` for wire / redact / store paths.
- **Reviewer asks → author resolution table** (in comments) — Khai's "5 asks" compressed to a single resolution table.

**Lift these patterns:** privacy / data-handling changes; anything with a clear before/after delta per surface; PRs that need a back-and-forth audit trail.

## #683 — cs-agent v1 auto-send: two-flip design

<https://github.com/wego/sprinklr-iran-conflict/issues/683>

**What it demonstrates:**
- **ASCII state diagrams** for small flips (Flip A / Flip B), preferred to Mermaid when ≤ 3 nodes.
- **Inline code snippets** showing the exact diff to land (`export const ACTIVE_EXECUTION_ENGINE: …`).
- **Defence-in-depth statement** — both flips default off, both must align for action.
- **cc @owner at the bottom** for explicit hand-off to the rule-content owner.

**Lift these patterns:** any "ship dormant first, flip later" proposal; any feature-flag design; any rollout requiring multiple gates.

## #800 — multi-booking identification, execute-one

<https://github.com/wego/sprinklr-iran-conflict/issues/800>

**What it demonstrates:**
- **Before/after everywhere** — schema (twin `BEFORE`/`AFTER` Zod fences), a concrete multi-booking payload, a ` ```diff ` caseProps delta, and a side-by-side executor-source table. The canonical demo of `references/before-after-recipes.md`.
- **Two Mermaid `flowchart TD`** (before/after pipeline) plus a two-tier "why this is inevitable" argument.
- **Decision matrix Q1..Q6** with **Default lean**, and a single rejected alternative captured *once* in What's Excluded (not sprinkled).
- **Heavy progressive disclosure** — code, payloads, and per-item rationale collapsed under `<details>` so the visible layer stays scannable.

**Lift these patterns:** any schema / data-flow change with a clear delta; anything where seeing the *change* (not just the end state) drives the review.

---

## Section presence matrix (which exemplar has what)

| Section | #632 | #668 | #672 | #683 | #800 |
|---|---|---|---|---|---|
| Status block | ◦ | ✓ | ✓ | ✓ | ✓ |
| Context + Outcome | ✓ | ✓ | ✓ | ✓ | ✓ |
| Side-effect contract table | ✓ | ◦ | ◦ | ◦ | ◦ |
| Mermaid flowchart | ✓ | ◦ | ✓ | ◦ | ✓ |
| ASCII state diagram | ◦ | ◦ | ◦ | ✓ | ◦ |
| Decision matrix (Q1..Qn) | ◦ | ✓ | ◦ | ◦ | ✓ |
| Verdict table | ◦ | ✓ | ◦ | ◦ | ◦ |
| Behavioural delta table | ◦ | ◦ | ✓ | ◦ | ✓ |
| Before/after code (```diff / twin fences) | ◦ | ◦ | ◦ | ✓ | ✓ |
| What's Excluded | ✓ | ✓ | ✓ | ✓ | ✓ |
| SHA-pinned code refs | ◦ | ✓ | ◦ | ◦ | ✓ |
| Verification list | ✓ | ◦ | ◦ | ◦ | ✓ |

Use this matrix to decide which sections fit the current source. Don't force all of them — pick the ones that make the discussion concrete.
