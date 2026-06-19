---
name: propose
description: >-
  Put a structured proposal up for alignment as a GitHub issue — anything from a
  quick tracking ticket to an RFC-grade design/decision doc — from a plan file,
  the conversation, or notes, then post via `gh`. Creates a new issue or amends
  an existing #N (a number-less "amend the RFC" resolves the target and
  confirms), supersedes, and audits; decision docs automatically get a staged
  review pipeline (reader test, grounding against code/data, optional objector
  steelman). Use whenever the user wants to open or update an issue, capture a
  proposal or decision, or write an RFC. Triggers on: "propose X", "open/file/
  draft an issue", "turn this plan into an issue", "track this in github",
  "write an RFC / decision doc / ADR", "draft a technical proposal",
  "amend/update/supersede the issue/RFC", "fold this into #N".
argument-hint: "[#N | new | \"topic\"]"
license: MIT
compatibility: Requires git and gh (GitHub CLI) installed and authenticated.
metadata:
  author: sunnywong
  version: "0.2"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(jq:*) Read Write Edit AskUserQuestion Task Agent
---

# Propose

Lift planning material into a well-structured GitHub issue that's optimized for **discussion and alignment** — reviewers can quote a row, post a number against a question, propose an alternative, or strike a scope item.

The output style is modelled on a small set of exemplars (see `references/exemplars.md`): status block, context + outcome, optional Mermaid/ASCII diagram for flow changes, decision matrices with **Default lean**, what's-excluded fence, SHA-pinned code citations, and a verification list.

## Routing: create vs update (the front door)

`/zeus:propose` is one skill with two entry points — **compose a new issue** (the Workflow below) or **amend an existing one** (Updating, near the end). They share the same `state → render → gate → post` pipeline; routing only decides *which state you start from*. The `argument-hint` is `[#N | new | "topic"]`. Parse `$ARGUMENTS` and walk this ladder, **strongest signal first** — an explicit instruction always beats an inference:

1. **Explicit `#N`** (`/zeus:propose #840 …`, or "amend/update/supersede #840") → **UPDATE #840**. An id is an instruction; it wins over every pin or guess, and re-points the worktree pin.
2. **Leading `new`** (`/zeus:propose new "<topic>"`) → **CREATE**, bypassing the pin.
3. **Session target** — an issue created or amended **in this conversation** → **UPDATE it** (conversation context outranks all scripts).
4. **Worktree pin** — `bash ${CLAUDE_SKILL_DIR}/scripts/state.sh current` returns the active proposal for this worktree → **UPDATE it, but confirm first**. The pin is per-checkout state that can outlive the task that set it (e.g. pinned while on `main`, then reused for unrelated work in the same checkout), so a resumed pin is an *inference*, not a fact — never blind-amend one you didn't create in this session. Always ask on topic-drift (prompt keywords don't match the pinned issue's title): *"This worktree is proposing **#N '<title>'**. New topic, or fold into #N?"*; otherwise confirm the target in one line before writing. In a non-interactive run an unconfirmable pin is **not** used — fall through to CREATE / ask, never guess.
5. **A topic phrase, no pin/session** → `resolve-target.sh "<phrase>"`: `high` → confirm then UPDATE; `ambiguous` → one AskUserQuestion with the candidates; `none` → **CREATE**.
6. **No argument at all** → resume the worktree pin / session target if one exists (step 3–4); otherwise **CREATE** (interview for the source).

Any branch that resolves to **UPDATE** then passes an **ownership gate**: an amend rewrites the whole body, so it's only allowed on an issue you authored. Not yours → it becomes a **comment** instead (see *Updating → amend only your own issue*). This is enforced in `post-issue.sh`, not just advised.

**Confirm an inferred target before any write** — routing is an inference and a wrong target is invisible to every downstream gate (the drift gate compares an issue to its *own* body). An **explicit `#N`** or a **this-session target** is trusted and only echoed: *"Amending **#840**."* A target reached by **inference** — the worktree pin (step 4) or a `resolve-target.sh` match (step 5) — is **confirmed, not just announced**: state it and get a yes before amending (*"Resuming **#840** (this worktree's active proposal) — amend it?"*), so a stale pin can't silently redirect the next task. Non-interactive + unconfirmable inference → don't guess; CREATE or ask. Posting (create or update) pins the issue as this worktree's active proposal automatically (`post-issue.sh`), so the next bare `/zeus:propose` resumes it.

## Review gating: derived from content, not declared

One pipeline for everything from a tracking ticket to a full RFC — **stages that have nothing to check skip themselves**. Whether the review machinery (Stage 1 reviewer simulation + hash stamp, Stage 2 grounding) runs is derived from what the state actually contains:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/requires-review.sh "$STATE_FILE"
# → {"required":bool,"mode":"auto|always|never","reasons":[...]}
```

Triggers (any one): `discussion_questions` non-empty · `code_grounding` non-empty · >200 words across `proposal` + custom `sections` + `discussion_banner` · MUST/MUST NOT invariants in that prose. The things that make a document need review — open decisions, empirical claims, substantial design prose, binding rules — are the things that trigger it; a six-line tracking ticket has none and flows compose → validate → post untouched. `post-issue.sh` calls the **same script** to enforce, so an author can't dodge review by not labeling a decision doc (the old self-declared `depth` field had exactly that hole).

Override with the state's `review` field when the heuristic misfires: `"always"` (force it) or `"never"` (skip it — legitimate for a paste-dump tracking issue, but it MUST appear as a visible choice in the step-5 confirmation, never a silent default). Full review playbook (Stage 1 prompt template, Stage 2 grounding, Stage 3 steelman, amend vs supersede, the Amendment Log, invariants-in-content): **`references/rfc-mode.md`**. Conventions and *why*: **`references/house-style.md`**.

## Inputs

| Source | When | How |
|---|---|---|
| Plan file (e.g. `~/.claude/plans/*.md`) | After plan mode | Prefer `$CLAUDE_PLAN_FILE`; otherwise the most-recent `.md` under `~/.claude/plans/`. |
| Current conversation | Mid-session, no plan file | Summarise the conversation-so-far. |
| User-supplied path or inline text | Explicit argument | `/zeus:propose <path>` or `/zeus:propose "raw paste"` — argument wins over the others. |

Picking order: **explicit argument → plan file → conversation**.

## Prerequisites

- **Required:** `git` (run inside a repo), `gh` (GitHub CLI, authenticated), `jq`, and `python3` (used by `pin-refs.sh` to pin file citations to blob URLs).
- **Optional:** a JS runner — `npx` (bundled with Node) or `bun` — enables the token-usage footer; safely skipped if absent.

## Workflow

When the user asks to "create an issue", "file an issue", or invokes `/zeus:propose`, follow these steps.

### 0. Preflight & bootstrap

Verify dependencies before doing any work:

```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo: under zsh, echo expands the escaped \n in .report and corrupts the JSON
```

If `.ok` is `false`, present each `.remediation[]` entry to the user and **offer to install**. With their confirmation, auto-install the installable ones and re-check:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh --fix
```

`--fix` only runs entries with `auto: true` (package installs). Interactive steps such as `gh auth login` (`auto: false`) are listed but never auto-run — ask the user to run them. Proceed only once preflight reports `ok: true`.

### 1. Gather repo + ref context

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/issue-context.sh
```

Returns JSON:
- `repo` — `owner/name` from `gh repo view`
- `branch` — current branch
- `head_sha` — `git rev-parse HEAD`, used to pin all code references
- `related_issues` — open issues whose titles share keywords (best-effort)

Cache this once per invocation; every code reference in the draft must use `head_sha`.

### 2. Resolve the source

Use the helper — it encodes the priority order so the skill doesn't have to:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/resolve-source.sh "$ARG"
```

Prints one of:
- `path:<absolute>` — file resolved (explicit arg, `$CLAUDE_PLAN_FILE`, or latest plan file).
- `inline:<tmp-path>` — the arg was raw text; written to a tmp file.
- `conversation` — no file found; summarise the running conversation.

If a file path was resolved, check whether it's already issue-shaped:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/is-issue-ready.sh "$SOURCE_PATH"
```

Exit 0 + `"ready": true` → **lift sections verbatim** (preserves voice). Exit 1 → summarise into the section grammar below.

### 3. Compose the draft

The draft is rendered deterministically from a state JSON. `init-state.sh` owns the full schema (one source of truth — keys, not prose); the agent fills the values; `render.sh` enforces the section grammar and ordering.

1. Initialize the state skeleton — every key present, so the agent only fills values:
   ```bash
   # file source (plan / paste): merge its extractable sections in
   bash ${CLAUDE_SKILL_DIR}/scripts/init-state.sh --from "$SOURCE_PATH" > "$STATE_FILE"
   # conversation source: omit --from, fill from the running discussion
   bash ${CLAUDE_SKILL_DIR}/scripts/init-state.sh > "$STATE_FILE"
   ```
   With `--from`, `init-state.sh` runs `extract-sections.sh` and merges its output over the skeleton (`context`, `proposal`, `whats_excluded`, `verification`, `references`, `discussion_questions`, `mermaid`); the skeleton supplies the rest (`title`, `status`, `closes_when`, `kind`, `sections`, `discussion_banner`, `amendment_log`, `code_grounding`). The extractor doesn't infer `kind`/`sections`/`discussion_banner` from prose — set them by judgment (below).

2. Derive the title (or override):
   ```bash
   TITLE=$(bash ${CLAUDE_SKILL_DIR}/scripts/derive-title.sh "$SOURCE_PATH")
   ```
   Encodes the `type(scope): description` convention shared with `/zeus:create-pr`. The agent may override before render.

3. Fill the field values (judgment) — set `title`, `status`, `closes_when`, and the content keys per the Field guidance below. Every key already exists in the skeleton, so this is value-filling (jq writes or Edit), not assembling the shape.

4. Render the draft (scaffold + pin code refs, one call):
   ```bash
   DRAFT=$(bash ${CLAUDE_SKILL_DIR}/scripts/render.sh "$STATE_FILE" --sha "$HEAD_SHA" --repo "$REPO")
   ```
   `render.sh` runs `scaffold-draft.sh` (enforces section grammar + ordering) then `pin-refs.sh` (rewrites any `path/to/file.ext:NNN-NNN` citation to a permalink at `head_sha`, e.g. → `https://github.com/<repo>/blob/<sha>/...#L39-L47`; citations inside ``` code fences are left as-is). Pass `--sha`/`--repo` from step 1 to avoid a second `gh` call; omit them and `render.sh` derives them from `issue-context.sh`.

#### Field guidance (what the agent fills)

- **`status` / `closes_when`** — required. Infer from source language (`status: PR open`, `Closes-when: merge of #N`). If neither is inferrable, ask via AskUserQuestion (one question).
- **`context`** — required. 2–4 sentences, or 2–4 **bold-led finding bullets** for audit/investigation issues (one bullet per finding, key numbers inline). The extractor lifts from the source's `## Context` heading if present; otherwise the agent summarises the "Why" / framing turn.
- **`kind`** — `"implementation"` (default) / `"decision"` / `"research"` / `"tracking"`. Sets which sections are required (see Gate). Use `implementation` for code/schema/flow RFCs; `decision` for an ADR (Context/Decision/Consequences, no acceptance criteria); `research` for a question/investigation issue; `tracking` for a task ticket. When unsure, leave `implementation` — it's the strict default and never silently drops a section.
- **`proposal`** — include when the source proposes a concrete change; leave blank for pure tracking issues.
- **`sections`** — first-class extra sections so genre-specific blocks aren't buried in `proposal`. Array of `{heading, body, placement}`; `body` is free markdown (tables, `<details>`, fences). `placement` ∈ `before_proposal` · `after_proposal` (default) · `after_discussion` · `before_references`, rendered in array order within each slot. Use for `Alternatives Considered`, `Risks`, `Rollout`, `Security`, `Consequences` (ADR), `Background`. Prefer a `sections` entry over stuffing a new `##` heading into the `proposal` blob — sections are addressable, reorderable, and survive an amend cleanly.
- **`discussion_questions`** — include for any section in the source that lists alternatives. The extractor catches `### Q\d+` blocks plus `**Default lean:**` lines (with `[draft]` flag). The agent may add `options` (array of `{label, meaning, tradeoff}`) for richer matrices, and `decided` (string) on a settled question — it renders a `**✅ Decided:**` line so a locked Q reads as a record, not an open ask.
- **`discussion_banner`** — optional intro rendered right under `## Discussion questions` (e.g. "all four locked by @reviewer; Q3 remains open"). Use it to state the disposition of the set instead of repeating it per-question.
- **`mermaid`** — include only when the source has explicit nodes/edges or pipeline / state-change language (per `references/diagram-recipes.md`). Don't invent topology.
- **before/after** — when a section shows a *change*, prefer a fenced block over prose; pick the form via `references/before-after-recipes.md` (diff fence for property/config/schema deltas, twin `BEFORE`/`AFTER` fences for substantial blocks, table for many small rows). These live inline in the `proposal` / section strings.
- **`whats_excluded`** — required. Lift explicit "out of scope" / "not doing" bullets. If the source has none, ask once.
- **`verification`** — required. Numbered list; preserve SQL / shell blocks verbatim.
- **`references`** — populate from `related_issues` (from step 1) plus any `#N` cited in the source.
- **`code_grounding`** — array of `{claim, ref}` (`ref` as `path/to/file.ext:NNN-NNN`). The only place code citations belong; renders as a collapsed appendix. Placement and table-cell rules: `references/section-patterns.md`.
- **Collapsible `<details>` blocks** — wrap important-but-buryable subsections (per-item rationale, file lists, schema defs, long SQL) inside the `proposal` string. Rules: `references/section-patterns.md`.
- **`amendment_log`** (decision docs) — a list of one-line dated entries (`<date> — <what changed> (amend|supersede)`). Renders as an `## Amendment Log` section near the end so the edit history is legible without diffing across edits. See `references/rfc-mode.md`.
- **Invariants in content** — when the issue will be implemented by an agent, write the load-bearing rules as binary `MUST` / `MUST NOT` (allowed/forbidden), not "prefer"/"ideally". This is the *content* layer; the skill's own guidance still explains the *why*. See `references/quality-criteria.md` → Agent-Ready and `references/house-style.md`.
- **`review`** — `"auto"` (default) / `"always"` / `"never"`. Leave on `"auto"` — whether the reader-test gate arms is derived from content by `requires-review.sh` (see Review gating above). Set `"always"` for a terse-but-contentious decision; `"never"` only with the user's visible consent at confirmation.
- **`mention_once`** — array of terms the audit enforces appear ≤1 time (e.g. a rejected alternative named once). Renders an invisible `<!-- audit:mention-once: … -->` guard so `audit-draft`/`check` catch a re-mention on every future amend, no flag needed.
- **`reader_test`** / **`reader_test_hash`** — stamped together by the agent after the Stage-1 reviewer simulation (see 4b for the stamp command). Don't pre-set them; `rehydrate` clears both each amend, and `post-issue` refuses a review-required post when either is missing **or when the hash doesn't match the current state** — any state edit after the test structurally forces a re-test.

### 4. Gate: validate + audit

Run both deterministic pre-post gates in one call:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh "$DRAFT" [--mention-once "term1,term2"] [--kind "$(jq -r '.kind // "implementation"' "$STATE_FILE")"]
```

- **validate** — required sections present. Always: `Status:`, `Closes-when:`, `## Context`. For `kind: "implementation"` (default) also `## What's Excluded` + `## Verification`; `decision`/`research`/`tracking` relax those two to optional (pass `--kind` so the validator knows — omitting it defaults to strict). Status/Closes-when also accept the header-table form.
- **audit** — consistency invariant *classes* (generic, never issue-specific): every `Q<n>` cross-reference resolves to a `### Q<n>` heading and headings run 1..N; numbered-anchor refs (`Invariant N`, `writer #N`, `shim #N`) don't exceed the largest numbered item (a renumber that orphans prose refs fails here, not in review); declared letter-ranges vs lettered headings (warn-only); declared single-mention terms appear ≤1 time (a rejected alternative belongs once, in What's Excluded — see `references/house-style.md`). Declare terms inline with `<!-- audit:mention-once: term -->` or via the flag.

Non-zero exit ⇒ a missing section or a real inconsistency; fix before continuing. Soft warnings (no References, residual `[draft]` tags, empty `diff` fences) print but don't block.

### 4b. Review the draft (Stages 1–3) — when `requires-review.sh` says `required: true`

Anything with open questions, grounded claims, a substantial proposal, or invariants arms the review pipeline — and it reruns **before posting, after every fix round, and on every amend** (no "non-structural" exemption; fix rounds are where regressions are born). The artifact under test is always **`render(state)`, never the live body**. In brief:

- **Stage 1 — reader test (always, when required).** A fresh subagent with *only* the rendered body, role-played as a skeptical 10-minute reviewer, returns comprehension + a contradiction sweep + a discussability audit + `READY|BLOCKED`. Loop fix-state → re-render → re-test until READY, then **stamp** `reader_test` + `reader_test_hash` (`post-issue` refuses without a matching stamp).
- **Stage 2 — targeted grounding (when it carries empirical claims or executable artifacts).** A refutation-framed pass against repo/data; execute fenced SQL/code somewhere the author didn't seed; ledger what can't be verified.
- **Stage 3 — steelman the objector (contested / high-stakes only).** One agent per anticipated objector writes their strongest comment; pre-answer it.

Full procedure — the contradiction-class checklist, the stamp command, the grounding plan, and Stage 3 — is in **`references/rfc-mode.md`**. An issue that derives `required: false` (a tracking ticket) skips this step entirely.

### 5. Confirm with the user

**Preferred (Claude Code):** call AskUserQuestion with the proposed title and a one-screen preview. Generate the preview deterministically — pass the title explicitly (the body no longer carries it on line 1):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/preview.sh "$(jq -r .title "$STATE_FILE")" "$DRAFT_PATH" 40
```

Options:

- **Post as-is** — runs step 6.
- **Edit** — open the draft for inline edits, then re-ask.
- **Save draft only** — print the draft path and stop.
- **Cancel** — discard.

**Fallback (other agents):** if AskUserQuestion isn't available, pipe `preview.sh` to stdout, then prompt via bash:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/preview.sh "$(jq -r .title "$STATE_FILE")" "$DRAFT_PATH" 40
read -r -p "[1] Post  [2] Edit  [3] Save only  [4] Cancel > " choice
```

### 6. Post

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/post-issue.sh \
  --title "<title>" \
  --body-file "<draft-path>" \
  [--label <label>] [--assignee <user>] [--milestone <m>]
```

Captures the returned URL, prints it, and exits. The script also accepts `--yes` for non-interactive callers that confirmed elsewhere.

The wrapper appends a best-effort Claude Code session-usage footer via `telemetry.sh --issue` (vendored identically with `/zeus:create-pr`; self-disabling outside Claude Code or when `CLAUDE_ISSUE_TELEMETRY=0` / the shared `CLAUDE_PR_TELEMETRY=0`). See that script's header for the cost/marker details.

Persist the state so a later amend can reload it: pass `--state "$STATE_FILE"` to `post-issue.sh` (it stores the JSON under the issue number via `state.sh`).

## Updating an existing issue (amend / supersede)

Triggers: "fold this into #N", "amend the issue", "update #N", "amend the RFC" (no number), `/zeus:propose <#N> "<change>"`. An amend is the **same compose pipeline entered from a rehydrated state** — edit the **state**, never the live body — so it reuses steps 3–4b above. Sequence (scripts under `${CLAUDE_SKILL_DIR}/scripts/`):

```bash
resolve-target.sh "<phrase>" [--repo R]                 # 0. resolve + CONFIRM the target
ownership.sh <N> [--repo R]                             # 0.5 amend only if MINE — else comment (below)
STATE_FILE=$(rehydrate.sh <N> [--repo R])               # 1. rehydrate state (source of truth)
drift-check.sh <N> "$STATE_FILE" [--repo R]             # 2. drift gate — STOP & reconcile on divergence
# 3. edit state + append an Amendment Log line
DRAFT=$(render.sh "$STATE_FILE" --sha "$HEAD_SHA" --repo "$REPO")   # 4. render + check + Stage-1 re-stamp
check.sh "$DRAFT" [--kind "$(jq -r '.kind // "implementation"' "$STATE_FILE")"]
post-issue.sh --update <N> --title "<t>" --body-file "$DRAFT" --state "$STATE_FILE"   # 5a. amend in place
supersede.sh --old <N> --title "<t>" --body-file "$DRAFT" --state "$STATE_FILE"        # 5b. or supersede (body: "Supersedes #N")
```

Two things the sequence rests on, with the rationale and the disposition-comment template in **`references/rfc-mode.md`** → *Amend vs supersede*:

- **Amend only your own issue (step 0.5).** `ownership.sh <N>` compares the issue author to the `gh` viewer. **Mine → amend** (the full sequence). **Not mine → comment, never edit the body** — composing a review against a teammate's issue is fine, but rewriting their authored body isn't. Run the review you want (reader test / grounding / objector steelman from step 4b) on *their* body, write the findings to a file, and post with `post-issue.sh --comment <N> --body-file <path>` — no `rehydrate`/`drift-check`/`--update`. `post-issue --update` hard-refuses a non-owned issue regardless, so this is also a real guardrail, not just guidance; `--force-amend` is the explicit escape hatch for a genuinely co-owned body.
- **Confirm the target before any write** (step 0) and **run the drift gate before editing** (step 2) — a wrong-target amend and an out-of-band body edit are both invisible to every other gate. Re-run Stage 1 + re-stamp on **every** amend; `post-issue --update` refuses without a matching stamp.
- **Amend vs supersede:** decision unchanged → amend; the decision itself changed → supersede (new issue, `Supersedes #<N>`, close the old). When the amend answers **reviewer feedback**, post **one** disposition comment afterward (`gh issue comment`) quoting each concern by its verbatim header with what changed — the body is the latest truth, the comment is the audit trail.

## Progressive disclosure

Load these references when you need the detail; the headings above are enough for a happy path.

- `references/exemplars.md` — annotated links to five issues that demonstrate each section type.
- `references/section-patterns.md` — extraction rules per section (what to look for in source, how to render).
- `references/diagram-recipes.md` — Mermaid `flowchart TD` and ASCII state-diagram templates; "when to use which".
- `references/before-after-recipes.md` — diff fence vs twin `BEFORE`/`AFTER` fences vs side-by-side table; "when to use which".
- `references/rfc-mode.md` — the review + amend playbook (the depth behind steps 4b and "Updating"): the authoring loop, full Stage 1/2/3 procedures + the reader-test stamp command, the amend operational sequence with its target-confirmation and drift-gate safeguards, amend vs supersede, the disposition-comment template, the Amendment Log, invariants-in-content.
- `references/quality-criteria.md` — the 7 quality criteria, scored by the Stage-1 reader from the outside.
- `references/code-guidelines.md` — when a code snippet earns its place in an issue ("if removing it changes nothing, delete it").
- `references/house-style.md` — the conventions this skill writes by, and *why* (progressive disclosure, mention-once, before/after, the RFC-2119 layer split).

## Constraints

- **Discussion-first.** The issue exists to align on a decision, not to be a status dashboard. Optimize sections for "a reviewer can quote a row and disagree."
- **Don't invent decisions.** If a default lean isn't in the source, tag it `[draft]` and let the user accept or override.
- **Preserve voice when possible.** Issue-ready plans get lifted verbatim; only summarise when the source is unstructured.
- **Pin code references.** Long-lived decision docs reference code by `blob/<sha>/path#L`, not by moving `path:line` (which rots).
- **Tables stay scannable.** Body table cells are short phrases — no permalinks, no multi-sentence grounding. Evidence goes in the `code_grounding` appendix; rationale goes in a `<details>` block under the table. A reader should get the whole decision from the visible layer and only expand for proof.
- **Progressive disclosure by default.** Visible layer: status → context findings (bullets) → decision tables → discussion questions → scope/acceptance. Collapsed layer: per-item rationale, code grounding, long fixtures.
- **Cancel is free.** The draft is always written to disk before the post step, so "Save draft only" or "Cancel" never loses work.
