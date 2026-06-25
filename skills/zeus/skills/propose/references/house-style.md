# House style

Conventions this skill writes by, and *why* — so you apply judgment, not rote rules. These are defaults; a repo may override them in prose (see "Per-repo overrides" at the end).

## Progressive disclosure

Lead with the decision; bury the proof. The visible layer is: status → context findings → decision tables/diagrams → discussion questions → scope/acceptance. Collapse code, payloads, long fixtures, and per-item rationale under `<details>`. Reviewers scan the visible layer first and expand only when they want evidence — a wall of code up top buries the decision they're there to make.

## Lead substantial proposals with a skim layer

A short tracking ticket needs no summary, but a decision-bearing or RFC-grade
proposal — the same class that triggers review (open `discussion_questions`,
>200 words of design prose, or MUST/MUST NOT invariants) — buries its decisions
when the reader must reach the `discussion_questions` block (which renders after
the proposal *and* every custom section) to find what's being asked. For that
class, put a skim layer above the fold by leading the Context with:

- a **TL;DR** (≤5 lines): the goal in one sentence, what ships first vs what's
  deferred, and the one-line ask of the reader; and
- a **Decisions needed** digest: one line per open question with its recommended
  answer (its `Default lean`), so a stakeholder can ratify in 30 seconds and
  expand the full `### Q<n>` tables only to disagree.

When the plan is phased, give each milestone/phase **rough sizing** — relative
effort + dependency risk, not committed estimates — so a reader deciding
*go / sequencing* can see which phase is large and where the schedule risk sits.

This is progressive disclosure applied to the *decision itself*: the visible
layer should answer "what am I deciding, and what does each path cost" before
any proof.

## Mention a rejected alternative once

When a design rejects an option, state it once — in **What's Excluded** — with the reason. Repeating it across sections re-litigates a settled call and reads as indecision. The main body should describe only what you *are* doing; the reader shouldn't have to hold two designs in their head.

## Show changes as before/after, not prose

When a section describes a *change*, a fenced block beats a paragraph. Pick the form via `before-after-recipes.md` (diff fence for property/config deltas, twin `BEFORE`/`AFTER` fences for substantial blocks, table for many small rows). Seeing the delta is faster to verify than reading a description of it.

## Decisions are matrices with a Default lean

Any open choice gets a `### Q<n>` block: 2–4 options as `Option | What it means | Trade-off`, then a **Default lean** (tag `[draft]` if it's your inference, not the user's call). This lets a reviewer quote one row and disagree, instead of arguing with a paragraph.

## Explain structural changes; don't just assert them

If a change is forced by the design (a schema that can't represent the new state, a contract that must move), say *why it's inevitable* — ideally distinguishing what's unconditionally forced from what's forced only by a decision taken here. Reviewers accept a constraint they understand; they push back on one asserted by fiat. Don't pad — only structural/non-obvious changes need this.

## Two layers of language (the RFC-2119 split)

These pull in opposite directions and both are right, at different layers:

- **This skill's instructions to you** (and prose explaining conventions) — reason it out, avoid heavy MUST/NEVER. You're smart; given the *why* you apply taste.
- **The design content the issue carries**, when it will be implemented by an agent — state binary invariants (`MUST` / `MUST NOT`, allowed/forbidden), not "prefer"/"ideally". An implementing agent can't act on "ideally"; it needs a rule. (See `quality-criteria.md` → Agent-Ready.)

So: explain *why* in the framing, state *what must hold* in the invariants.

## Tables stay scannable

Body table cells are short phrases — no permalinks, no multi-sentence grounding. Evidence goes in the collapsed `code_grounding` appendix; rationale goes in a `<details>` under the table. A reader should get the whole decision from the visible layer and only expand for proof.

## Cross-links use explicit anchors, not heading auto-slugs

When the doc links one of its own sections (`[…](#…)`), put an explicit `<a name="short-id"></a>` immediately above that heading and link to *that*. GitHub derives a heading's anchor by slugifying its text — lowercasing, spaces→`-`, dropping punctuation, and collapsing ` / ` and ` — ` oddly — so a link guessed from the title (`#proposal--approach`, `#when-a-route-must-…`) is fragile and silently breaks on the next retitle. Before pushing, confirm every `(#anchor)` has a matching `<a name>` or heading. Explicit anchors survive retitling and punctuation; auto-slugs don't.

## Don't keep an inline changelog

An amended proposal grows a running "changelog/history" only if you write one — and it bloats until someone bulk-deletes it. Don't: GitHub already versions every edit (the issue's edit history *is* the changelog). If a re-scope genuinely needs a note, keep a short collapsed "recent changes" (last few) and prune it on material shifts — never an append-only ledger in the body.

## Per-repo overrides

If a repo wants different defaults (e.g. ASCII over Mermaid, a standing label), it states them in prose the agent reads at compose time. Keep genuine *data* config (default label, etc.) minimal and explicit; keep *style* as reasoned prose, never a wall of toggles.
