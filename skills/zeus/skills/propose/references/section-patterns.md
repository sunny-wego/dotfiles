# Section patterns

Per-section extraction rules. Each section has: **when to include**, **what to look for in source**, **render template**, and an **example** lifted from the exemplars.

## Status block (required)

**When:** every long-lived issue.

**Source signals:** explicit `Status:` / `Closes-when:` phrasing; references to an open / merged PR; sentences like "tracked in #N", "closes when …", "blocked on …".

**Render:**

```
Status: <open | decisions-pending | tracking | superseded-by-#N | shipped-in-#N>
Closes-when: <merge of PR #N | sign-off recorded in this thread | acceptance below>
```

If neither line is inferrable from the source, ask once via AskUserQuestion before drafting.

**Example (from #672):**
```
Status: PR open — #675 (review-driven scope expansion)
Implementation tracked in https://github.com/wego/sprinklr-iran-conflict/pull/675
```

## Context + Outcome (required)

**When:** every issue.

**Source signals:** "Context", "Why", "Today …", "We want to …", framing turns at the top of a plan or first message of the conversation.

**Render:** 2–4 sentences. State the current situation, then the intended end state. Use present tense.

**Example (from #632):**
> Today, every eligible webhook runs v4.5 (`cs-brain`) and writes one row to `cs_brain_analyses`. We want to start shadow-running `cs-agent v1` in parallel with v4.5 so we can compare their outputs offline and build confidence for an eventual cutover.
>
> Outcome: for every eligible webhook, two rows land in `cs_brain_analyses` — one from v4.5 (unchanged), one from v1 shadow.

## Proposal / Approach (required when there's a concrete change)

**When:** any proposal-style issue. Omit for pure tracking issues.

**Source signals:** "Proposal", "Approach", "We will …", tables of files-to-change, code-snippet sketches.

**Render:** the recommended path only — alternatives belong in the decision matrix below. Tables and code blocks are welcome. Skip the section if the source has only an open question.

## Side-effect contract table (when relevant)

**When:** anything touching a pipeline with multiple sinks (DB writes, HTTP calls, external APIs, telemetry).

**Source signals:** the word "side effect", lists of external calls, "writes to …" / "mutates …" / "sends …" phrasing.

**Render:**

| Side effect | Owner | Allowed in <variant>? |
|---|---|---|
| `<call>` (file:line) | <step> | ✅ / ❌ + reason |

**Example (from #632):**

| Side effect | Owner | v1 shadow allowed? |
|---|---|---|
| `enterpriseUpdateTicket` (Sprinklr write-back inside `identify`) | shared `identify` | implicitly skipped — v1 does not call `identify` again |

## Discussion questions / Decision matrix (when alternatives exist)

**When:** the source contains language like "we could do A or B", "options", "tradeoff", or multiple paragraphs starting with bold letters proposing alternatives.

**Source signals:**
- Sentences of the shape "we could X or Y or Z".
- Headings "Q1 / Q2 / Question 1 / Option A / Option B".
- The words "default", "lean", "prefer", "leaning toward".

**Render:** one `### Qn — <question>` per axis. Each question gets a 3–4 row Option table. Recommended option goes first with `*(Default lean)*`. Tag inferred leans with `[draft]`.

```
### Q1 — <one-sentence question>

| Option | What it means | Trade-off |
|---|---|---|
| **A. <name>** *(Default lean)* | <one sentence> | <one sentence> |
| **B. <name>** | <one sentence> | <one sentence> |
| **C. <name>** | <one sentence> | <one sentence> |

**Default lean:** A — <one-sentence reason>.
```

**Example (from #668 Q4):**

> ### Q4 — What's missing from Rule 1?
>
> | Option | What it adds | Trade-off |
> |---|---|---|
> | **A. Nothing — ship the four rules first** | Narrowest gate. … | Slower expansion but every addition is data-driven. |
> | **B. Rule 1 expansion** — add `INITIATED` … | Covers the … | Need to confirm reviewers actually auto-approve those … |
>
> **Default lean:** A + B.

## Behavioural delta table (when before/after is the point)

**When:** the change has observable user-visible effects.

**Source signals:** "before / after", "today / after this PR", "previously / now".

**Render:**

| Surface | Before | After |
|---|---|---|
| `<surface>` | `<value>` | `<value>` |

**Example (from #672):**

| Surface | Before | After |
|---|---|---|
| `cs_brain_analyses.v4_output` (regex / service) — any engine | `WF***` | full WF |
| Outbound reply to customer | full WF | unchanged |

## Verdict / Resolved table (in follow-ups after data is in)

**When:** revisiting a decision matrix after analysis has been done.

**Render:**

| Q | Verdict | Applied change |
|---|---|---|
| **Qn — <axis>** | **<A/B/C>** | <one-line code change> |

Keep it adjacent to the original matrix so readers see both at once.

## What's Excluded (required)

**When:** every issue. The CLAUDE.md mandates it.

**Source signals:** "out of scope", "not doing", "deferred", "follow-up", "won't ship in this PR".

**Render:** bulleted list. Each bullet says **what's excluded** and **why**. Link to a follow-up issue / ticket when one exists.

**Example (from #683):**

> - **DB-backed gate config.** `gate-rules.ts` already flags this as the long-term endgame; we'd move there once CS ops needs to tune without an engineer in the loop. For now, code is the source of truth.
> - **HITL approval path for v1.** Deleted in #632; out of scope.

## Verification / Acceptance (required)

**When:** every issue with a concrete change.

**Source signals:** "verify", "test plan", "how we'll know", SQL snippets, `bun test`, `grep`, `gh api`.

**Render:** numbered list. Preserve SQL / shell blocks verbatim — they're meant to be runnable.

**Example (from #632):**

> 1. **Schema unit** — parse both `V4OutputSchema` and `EvidenceSnapshotSchema` against hand-crafted fixtures; assert versions `"20260512"` / `"20260513"`.
> 2. **Side-effect audit unit** — mock the shadow workflow's environment and assert that no calls are made to: `executeCsAgentActions`, `enterpriseUpdateTicket`, …
> 3. **Verification SQL:**
>    ```sql
>    select engine_version, …
>    from cs_brain_analyses
>    where case_number = <id>;
>    ```

## References (optional but encouraged)

**When:** the issue cites or is informed by prior decisions, related issues, or external docs.

**Render:** bullet list at the bottom. `#N — short description` per entry.

**Example (from #679):**

> - #668 — gate rule discussion + Q1–Q4 verdicts + deferred Q5
> - #669 — gate matcher PR (shadow-only, `CS_AGENT_V1_AUTOSEND_ENABLED = false`)
> - #632 — original shadow-only landing PR

## Collapsible details (`<details>`)

**When to use:** any subsection that's important for reviewers who care, but would bury the top-level discussion if inlined. The summary stays visible; the body opens on click.

**Strong fits (lift from exemplars):**

- **File-by-file change list** — keep the high-level "Files (N)" table in the open; put per-file rationale inside `<details>`. (Per #672 "File-by-file", #632 file map.)
- **"Where these fields live in the schema"** — inline Zod snippets / type definitions that ground the discussion but aren't the discussion itself. (Per #668, #632.)
- **"Files NOT modified"** — explains the boundary of the change without padding the main flow. (Per #672.)
- **"Out of scope (separate follow-ups)"** when the list is long enough that it crowds the main What's Excluded. (Per #672.)
- **Match semantics / matcher edge cases** — formal spec adjacent to a higher-level proposal. (Per #668.)
- **Long verification SQL or fixture dumps.** Keep the assertion in the open, the query/expected-output in `<details>`.

**Don't use for:**

- Status, Context, Outcome, Discussion questions, Default lean, What's Excluded summary, top-level Verification list — these are the discussion surface; reviewers shouldn't have to click to see them.
- Anything you'd quote in a PR review comment — quoting hidden content is friction.
- Short content (≤ 3 lines). `<details>` for a one-liner is noise.

**Render:**

```markdown
<details>
<summary><b>File-by-file</b></summary>

### `apps/system/lib/pii-mask.ts`
- one-line rationale
- another line

### `apps/system/lib/db/cs-brain-privacy.ts`
- …
</details>
```

**Style rules:**

- `<summary><b>Title</b></summary>` — bold the summary; reads as a heading when scanned.
- One blank line after `<summary>` before content (GitHub Markdown requires this to render inner Markdown).
- Don't nest `<details>` more than one level deep.
- Headings inside `<details>` should be one level deeper than the surrounding section.

## Section ordering

The body does **not** repeat the title (GitHub shows it). Status/Closes-when render as a two-row header **table** at the very top. A `## Mermaid` diagram renders **right after `## Context`** — a flow/architecture diagram is orientation, so it comes before the detail (progressive disclosure: problem → picture → approach → detail → appendices).

```
<no title line — GitHub shows the title>

| | |
|---|---|
| **Status** | … |
| **Closes-when** | … |

## Context
## Mermaid / ASCII diagram      (when applicable — orientation, placed early)
   [sections: placement "before_proposal"]   (Background, Glossary)
## Proposal / Approach          (when applicable)
   [sections: placement "after_proposal" — DEFAULT]  (Alternatives, Risks, Rollout, Security, Consequences)
## Discussion questions         (when alternatives exist)
   discussion_banner            (optional intro: disposition of the set)
   ### Q1 …   **✅ Decided:** …  (per-question `decided` renders this line)
   ### Q2 …
   [sections: placement "after_discussion"]
## What's Excluded              (required for kind=implementation; optional otherwise)
## Verification / Acceptance    (required for kind=implementation; optional otherwise)
   [sections: placement "before_references"]
## References
## Amendment Log                (RFC-grade; renders near the foot)
<code grounding appendix>       (collapsed <details>)
```

**`kind`** gates the two conditionally-required sections: `implementation` (default) requires What's Excluded + Verification; `decision`/`research`/`tracking` relax both (an ADR or a research-question issue has no acceptance criteria). **Custom `sections`** (`{heading, body, placement}`) are first-class and reorderable — reach for one before stuffing a new `##` heading into the `proposal` blob, so the section stays addressable and survives amends.

## Code grounding appendix (when claims cite code)

**When:** any issue whose tables or findings rest on code-level claims ("X never sets property Y", "Z is emitted at …"). Audit/realignment issues almost always need it.

**Source signals:** `path:line` citations attached to claims; "grounded in", "confirmed in code", "emission point" phrasing.

**Render:** populate the state's `code_grounding` array (`{claim, ref}`); the scaffolder emits a collapsed table at the very bottom:

```html
<a name="code-grounding"></a>
<details>
<summary><b>Code grounding — claims above, pinned to the SHA in each link</b></summary>

| Claim | Code |
|---|---|
| <one-line claim, matching the wording used in the body> | path/to/file.ts:NNN-NNN |

</details>
```

Rules:

- This is the **only** place code citations appear. Body tables cite claims in words; readers expand the appendix for proof. (validate-draft.sh soft-warns on refs in body table cells.)
- Claim wording should echo the body row it supports, so a reviewer can map row → evidence without guessing.
- Refs stay in `path:NNN-NNN` form in the state; `pin-refs.sh` converts them to `blob/<sha>` permalinks after scaffolding.
- Body prose may link to it once: `see the [appendix](#code-grounding)`.

**Example (from #776):** four-row decision table with short "Why" phrases, 10-row collapsed claim→code table at the bottom.

## Summary table + collapsed rationale (proposal pattern)

**When:** the proposal is a set of per-item decisions (alerts, flags, routes, migrations) where each item has a one-line verdict plus a paragraph of justification.

**Render:** decision table first (short cells: verdict + one-phrase why), then immediately:

```html
<details>
<summary><b>Why these N (rationale per item)</b></summary>

- **A — <item>.** <full paragraph>
- **B — <item>.** <full paragraph>

</details>
```

The table is the discussion surface (quote a row, disagree); the details block carries the depth without burying the next section.
