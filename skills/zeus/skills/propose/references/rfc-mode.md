# The review playbook (decision docs, RFCs, proposals)

propose runs ONE pipeline for everything from a tracking ticket to a full RFC — same venue (a GitHub issue), same state→render→post backbone. There is no declared "depth": **whether the review stages below run is derived from the document's content** by `scripts/requires-review.sh` — open questions, grounded claims, a substantial proposal, or binding invariants; any one arms the gate, and the state's `review` field overrides (`"always"` / `"never"`, the latter surfaced visibly at confirmation). A tracking ticket triggers nothing and flows compose → validate → post; a decision doc triggers everything below. The rigor that would live in a standalone RFC tool lives here; the artifact stays an issue.

Derived gating exists because the old self-declared label was set by the same author whose blind spots the gates check — an unlabeled decision doc got zero enforcement. Content can't forget to label itself. Two corollaries: don't fight the derivation to force the loop onto a one-paragraph ask (process for its own sake), and if a genuinely contentious decision derives as no-review, set `review: "always"` — then ask why the doc has nothing a reviewer could grip (no questions, no claims is itself a finding).

## The authoring loop (mapped onto propose)

1. **Context** — the existing resolve-source / interview step. Push for concrete, measurable problem statements; surface constraints and invariants early.
2. **Section-by-section refinement** — the decision-matrix pipeline you already use: for each open choice, brainstorm 3–5 options, let the user curate (keep/remove/combine), then write it into the **state** (never hand-edit the rendered body — edit state and re-render, so consistency holds by construction).
3. **Stage 1 — Reviewer Simulation** — before posting and after **every** amend and **every** fix round (no exemptions). See below.
4. **Stage 2 — Targeted Grounding** — the document agrees with the world, not just itself. See below.
5. **Stage 3 — Steelman the Objector** — conditional, contested decisions only. See below.

The layering principle: **scripts prove structure** (`check.sh`: sections, Q-refs, anchors, ranges, mention-once — don't spend reader tokens there), **one cold reader proves the document agrees with itself**, **one grounded verifier proves it agrees with the world**, and the human owns authorization and the decision. Reader-found gaps that recur as *classes* graduate into `audit-draft.sh`; the reader is reserved for what only a reader can do.

## Stage 1 — Reviewer Simulation (the reader test)

A design doc that only its author can parse isn't aligned. Validate it works cold — and validate **the right artifact**: always `render(state)` of the state about to be posted, **never the live issue body** (on an amend they can diverge; a body-pointed reader grades stale-but-fluent prose "great" while the state regenerating it is missing whole sections).

1. Spawn a **fresh subagent** (Task tool) with *only* the rendered body — no conversation context — role-played as **a skeptical senior stakeholder with 10 minutes**.
2. Require four outputs:
   - **Comprehension**: the decision, the cost, the risk, and *what is being asked of me*, in ≤5 sentences. "Can't tell from the body" = gap.
   - **Contradiction sweep**, hunting these classes explicitly (each has bitten in practice):
     - headline/summary claim contradicted by the detailed body ("ONE optional field" vs a list adding four; "six call sites" vs an 8-row matrix)
     - invariant ↔ table/matrix agreement ("exactly one X" vs the enumerated rows)
     - a value referenced before the step that produces it (ordering / circular dependency)
     - status-vs-content drift (`Status: decisions-pending` while every Q reads resolved)
     - vocabulary closure: every enum value / schema field defined or self-evident
     - both sides of any asymmetric semantics (retry, atomicity, ordering, rollback direction)
     - arithmetic claims vs the tables they summarize ("3 of 5 shims" vs a 3-row table)
     Tell it to SKIP what scripts already check (sections, Q-refs, anchors, mention-once) and to treat repo jargon as given — precision per token, not noise.
   - **Discussability audit**: is each question genuinely open or rhetorical? does every option carry a real tradeoff, or is one a strawman propping up the lean? can a reviewer disagree with a single quotable row? *what comment would you actually post?* Score the 7 criteria in `quality-criteria.md` here, from the outside.
   - **`VERDICT: READY | BLOCKED`** with severity-tagged numbered gaps.
3. BLOCKED → fix the relevant section **in state**, re-render, **re-test**. Loop until READY. Fix rounds are where regressions are born — a fix that renumbers a list orphans a cross-reference; a confident clarification overclaims. The hash stamp makes skipping the re-test unrepresentable, not just discouraged.

On READY, **stamp the passing render** — a boolean AND the state hash, so the gate knows the test ran against *this* state:

```bash
HASH=$(bash ${CLAUDE_SKILL_DIR}/scripts/state-hash.sh "$STATE_FILE")
jq --arg h "$HASH" '.reader_test = true | .reader_test_hash = $h' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
```

`post-issue.sh` refuses a review-required post/update without the stamp **or on a hash mismatch** (state edited after the test = untested fixes); `rehydrate.sh` clears both, so every amend re-runs the test. An issue that derives `required: false` (a tracking ticket) skips Stages 1–3 entirely.

## Stage 2 — Targeted Grounding

The cold reader takes every empirical claim on faith — faith is where fluent hallucinations live. A refutation-framed pass with repo/data access, scoped to ROI and **fanned out**: spawn one subagent per lean-supporting claim, one for the spot-check batch, and one artifact-executor, all in a single turn — the checks are independent reads of different parts of the world, so the merged verdict set is identical to a serial pass at a fraction of the wall-clock. Sequencing rule: on a **first** render, run Stage 1 before Stage 2 (a BLOCKED verdict forces state edits that would waste grounding work); on a **re-render after fixes**, Stage 1 and the touched-claim Stage 2 re-checks may launch together — both gates pass independently, so ordering can't change the outcome, only the latency.

- **Infer the grounding plan per run; never write a repo config for it.** The doc's fenced blocks declare what's *needed* (SQL DDL → a disposable database branch; code → the repo's runners; none → code-claims only). The repo's existing artifacts declare what's *available* (ORM configs, MCP servers, AGENTS.md / skill files naming prod projects, package scripts). Surface the plan in the pre-post confirmation — that's the authorization moment; capabilities are inferable, **permission never is**. Ambiguity → ask.
- **Check exactly two claim sets**: lean-supporting claims (the facts that flip a default lean if false — a false premise here means the team aligns on a decision that won't survive implementation) and spot-check bait (numbers, "today X does Y at file:line" — the two-minute falsifiables where reviewer trust dies first). Prompt the verifier to *refute* from the pinned source, not confirm.
- **Execute every executable artifact** somewhere the author didn't seed: self-seeded fixtures encode the author's own misbeliefs and go green anyway. A copy-on-write branch of the production DB falsifies jsonb paths against real rows, dress-rehearses the DDL, and makes `EXPLAIN` meaningful at production scale. Conclusions only into the issue — never raw rows/PII.
- **Ledger what can't be verified**: each load-bearing assumption names which lean flips if it's false and the post-ship signal that would reveal it. Honest labeling replaces verification where verification can't reach.

Evidence (dated queries, branch id, claims checked/refuted) lands in `code_grounding` / a collapsed appendix — the issue carries its own evidence trail; no config file anywhere.

## Stage 3 — Steelman the Objector (conditional)

For contested or high-stakes decisions only. One agent per *anticipated objector* (objectors are fewer and more concrete than rejected alternatives), with repo access, writes the strongest comment that person would post — a concrete losing scenario, not rhetoric. Spawn them in a single turn: objections are independent by construction; A's steelman never depends on B's. Amend to pre-answer each, or post it yourself as a named open question. Arriving with the opposition's best argument already addressed is the cheapest buy-in accelerator there is.

## Amend vs supersede

```
Existing issue, and you're changing it?
  Typo / clarification / adds detail, decision unchanged   → AMEND
  Scope / direction / a constraint invalidates the decision → SUPERSEDE
  Status only (e.g. accepted / shipped)                    → just update the Status line
```

**Amend** (the common case) edits the **state** and re-runs the compose pipeline — never hand-patch the live body. Operational sequence (scripts under `${CLAUDE_SKILL_DIR}/scripts/`):

```bash
# 0. resolve + CONFIRM the target
resolve-target.sh "<phrase>" [--repo R]          # explicit #N wins; else a this-session issue; else this
# 1. rehydrate the state (source of truth)
STATE_FILE=$(rehydrate.sh <N> [--repo R])
# 2. drift gate BEFORE editing anything
drift-check.sh <N> "$STATE_FILE" [--repo R]
# 3. edit state, append an Amendment Log line, 4. render + check + Stage 1 re-stamp
DRAFT=$(render.sh "$STATE_FILE" --sha "$HEAD_SHA" --repo "$REPO")
check.sh "$DRAFT" [--mention-once "…"] [--kind "$(jq -r '.kind // "implementation"' "$STATE_FILE")"]
# 5. apply
post-issue.sh --update <N> --title "<t>" --body-file "$DRAFT" --state "$STATE_FILE"
```

Two safeguards the sequence rests on:

- **Step 0 — confirm the target before any write.** A fuzzy match (newest-touched in the per-repo state store, else `gh issue list --search`) MUST NOT trigger a body update unconfirmed: the drift gate compares an issue's state to *that issue's own* body, so it's blind to a wrong-target amend — target confirmation is the only safeguard for that class. Lead the confirmation with the inferred target ("Updating **#N** — '<title>' (last touched <date>). Correct?"). A `has_state: false` candidate also gets the lossy-re-ingest warning surfaced there.
- **Step 2 — drift gate before editing.** `drift-check.sh` renders the rehydrated state and diffs it against the live body (re-pinned refs / footers normalized away). Divergence means someone edited prose out-of-band; **STOP and reconcile** (re-ingest those edits into state) or the re-render clobbers them. This is the deterministic half of "regenerate from current truth"; the reader test is blind to it.

Re-run Stage 1 + re-stamp on **every** amend (rehydrate cleared the stamp; `post-issue --update` refuses without a match) — no "non-structural" exemption. Because the body regenerates from state, unrelated sections stay coherent automatically.

**Acknowledging a review (the disposition comment).** When an amend is *driven by reviewer feedback*, the body update is only half the job — it makes the design say the new thing but doesn't tell the reviewer their points landed. Post **one** reply comment (not one per point — a reviewer scanning the thread sees the whole disposition at a glance):

```bash
gh issue comment <N> [--repo R] --body-file <reply.md>
```

Format each entry as the reviewer's header quoted **verbatim** (so it's greppable against their comment), then your response beneath:

```markdown
> **B1. <reviewer's exact header>**

<what changed: section(s) touched + the decision + the rev it landed in>
```

Rules: say what *changed*, not "done"; a **declined** point is still a disposition — "kept as-is because…", never silence; don't restate the body, point to it. The split is deliberate — the **body is the latest truth** (coherent for a reader who never saw the review), the **comment is the audit trail** of what moved. This reply comment is the *only* write the skill makes to the comment thread (the issue's human-owned zone); everything else is the body.

**Supersede**: the decision itself changed enough that editing in place would erase the record of *why* the old call existed. Open a **new** issue, add `Supersedes #<old>` near the top, post it, then comment `Superseded by #<new>` on the old issue and close it. The old issue stays as the durable record of the prior decision.

## Amendment Log

For decision docs, carry a short log so the edit history is legible without diffing the body across edits. Render it as its own section near the end:

```md
## Amendment Log
- 2026-06-10 — folded in the data-flow principle; A7 → cosmetic (amend)
- 2026-06-10 — added Sprinklr representation + Q6 (amend)
```

Keep it to one line per substantive edit (what changed + amend/supersede). It's authored content like everything else — it lives in state and renders with the body.

## Invariants in the content

When the issue will be implemented by an agent, write the load-bearing rules as binary invariants (`MUST` / `MUST NOT`, allowed/forbidden) in the body — not "prefer"/"ideally". See `quality-criteria.md` → Agent-Ready and `house-style.md` → the RFC-2119 split. This is about the *doc's content*; the skill's own guidance still explains the *why*.
