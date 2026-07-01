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
argument-hint: "[#N | new | review #N | \"topic\"]"
license: MIT
compatibility: Requires git and gh (GitHub CLI) installed and authenticated.
metadata:
  author: sunnywong
  version: "0.5"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(jq:*) Read Write Edit AskUserQuestion Task Agent
---

# Propose

Lift planning material into a well-structured GitHub issue that's optimized for **discussion and alignment** — reviewers can quote a row, post a number against a question, propose an alternative, or strike a scope item.

The output style is modelled on a small set of exemplars (see `references/exemplars.md`): status block, context + outcome, optional Mermaid/ASCII diagram for flow changes, decision matrices with **Default lean**, what's-excluded fence, SHA-pinned code citations, and a verification list.

## Routing: create vs update (the front door)

`/zeus:propose` is one skill with three entry points — **compose a new issue** (the Workflow below), **amend an existing one** (Updating, near the end), or **peer-review someone else's** (Reviewing someone else's proposal, near the end). All three share the same `state → render → gate` engine; routing only decides *which state you start from* and *which output adapter runs* (post your own body / comment on theirs). The `argument-hint` is `[#N | new | review #N | "topic"]`. Parse `$ARGUMENTS` and walk this ladder, **strongest signal first** — an explicit instruction always beats an inference:

0. **Peer-review verb** (`/zeus:propose review #840`, "review #840", or any `#N` with `--as peer`) → **REVIEW #840** read-only: run the cross-check against *their* body and post one trust-labeled comment, never editing the artifact. See *Reviewing someone else's proposal*. (`--as self` forces the opposite — treat a target as your own draft to gate; `--as` overrides the ownership auto-detection in the gate paragraph below.)
1. **Explicit `#N`** (`/zeus:propose #840 …`, or "amend/update/supersede #840") → **UPDATE #840**. An id is an instruction; it wins over every pin or guess, and re-points the worktree pin.
2. **Leading `new`** (`/zeus:propose new "<topic>"`) → **CREATE**, bypassing the pin.
3. **Session target** — an issue created or amended **in this conversation** → **UPDATE it** (conversation context outranks all scripts).
4. **Worktree pin** — `bash ${CLAUDE_SKILL_DIR}/scripts/state.sh current` returns the active proposal for this worktree → **UPDATE it, but confirm first**. The pin is per-checkout state that can outlive the task that set it (e.g. pinned while on `main`, then reused for unrelated work in the same checkout), so a resumed pin is an *inference*, not a fact — never blind-amend one you didn't create in this session. Always ask on topic-drift (prompt keywords don't match the pinned issue's title): *"This worktree is proposing **#N '<title>'**. New topic, or fold into #N?"*; otherwise confirm the target in one line before writing. In a non-interactive run an unconfirmable pin is **not** used — fall through to CREATE / ask, never guess.
5. **A topic phrase, no pin/session** → `resolve-target.sh "<phrase>"`: `high` → confirm then UPDATE; `ambiguous` → one AskUserQuestion with the candidates; `none` → **CREATE**.
6. **No argument at all** → resume the worktree pin / session target if one exists (step 3–4); otherwise **CREATE** (interview for the source).

Any branch that resolves to **UPDATE** then passes an **ownership gate** (`ownership.sh`): an amend rewrites the whole artifact, so it's only allowed on a proposal you authored. **Not yours splits by intent**: an explicit *review* (step 0, or `--as peer`) runs the full **peer-review** flow (*Reviewing someone else's proposal*); a bare amend of someone else's issue **degrades to a disposition comment** instead of a body rewrite (*Updating → amend only your own proposal*). Both land as a comment and never touch the body — the difference is that peer-review actively runs the cross-check and labels its findings, where the amend-degrade just posts what you'd have written. On GitHub the read-only guarantee is enforced in `post-issue.sh` (`--update` hard-refuses a non-owned issue; `--comment` never edits); on the Confluence path (no post-issue.sh backstop) the agent MUST honour `ownership.sh` before `updateConfluencePage`.

This skill spans **two destinations** (GitHub issues, Confluence pages — see *Destination*), and routing is destination-agnostic: the worktree pin (`state.sh current`) and `resolve-target.sh` candidates each carry a `provider` + `ref` (a bare `<number>` for GitHub, `confluence:<id>` for a page), so an explicit `#N`, a resumed pin, or a resolved phrase lands on whichever destination that proposal lives in. The UPDATE then follows the matching sequence in *Updating*.

**Confirm an inferred target before any write.** An explicit `#N` or a this-session target is trusted — just echo it (*"Amending **#840**."*). A target reached by inference (the worktree pin or a `resolve-target.sh` match) needs a yes first (*"Resuming **#840** — amend it?"*), so a stale pin can't silently redirect the next task; non-interactive + unconfirmable → CREATE or ask, never guess. Posting auto-pins the issue as this worktree's active proposal (`post-issue.sh`), so the next bare `/zeus:propose` resumes it.

## Review gating: derived from content, not declared

One pipeline for everything from a tracking ticket to a full RFC — **stages that have nothing to check skip themselves**. Whether the review machinery (Stage 1 reviewer simulation + hash stamp, Stage 2 grounding) runs is derived from what the state actually contains:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/requires-review.sh "$STATE_FILE"
# → {"required":bool,"mode":"auto|always|never","reasons":[...]}
```

Triggers (any one): `discussion_questions` non-empty · `code_grounding` non-empty · >200 words across `proposal` + custom `sections` + `discussion_banner` · MUST/MUST NOT invariants in that prose — i.e. the things that genuinely need review. A six-line tracking ticket has none and flows compose → validate → post untouched. `post-issue.sh` calls the **same script** to enforce, so an author can't dodge review by not labeling a decision doc (the old self-declared `depth` field had exactly that hole).

Override with the state's `review` field when the heuristic misfires: `"always"` (force it) or `"never"` (skip it — legitimate for a paste-dump tracking issue, but it MUST appear as a visible choice in the step-5 confirmation, never a silent default). Full review playbook (Stage 1 prompt template, Stage 2 grounding, Stage 3 steelman, amend vs supersede, the Amendment Log, invariants-in-content): **`references/rfc-mode.md`**. Conventions and *why*: **`references/house-style.md`**.

## Destination: GitHub, Confluence, or both

The same `state → render → gate` pipeline is destination-neutral; only the **render + post tail** forks. GitHub is always the default. A repo may additionally opt in to publishing its proposals to **Confluence** (as child pages under a parent page) — this is the *only* thing the destination changes.

Resolution is **per repo**, from personal-tooling config (the `auto-ping.sh` store style — user config dir, keyed by `owner/repo`, **not** committed):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/confluence-target.sh "$REPO"
# unconfigured → {"configured":false}            (GitHub-only — today's behaviour, no new surface)
# configured   → {"configured":true,"cloudId":…,"spaceKey":…,"spaceId":…|null,
#                 "parentId":…|null,"mode":"both"|"confluence","defaultStatus":…}
```

A repo absent from the store behaves **exactly as before**. Enable one with `confluence-target.sh enable <owner/repo> --cloud <id|url> --space <KEY> [--parent <pageId>] [--mode both|confluence] [--status current|draft]`.

`mode` names the destination set:

- **`both`** (default) — GitHub issue **and** a Confluence page. The **GitHub issue stays canonical** (keeps `#N`, the journey handoff into the issue→code→PR chain); the Confluence page is an additional published surface, backlinked to the issue. Lowest risk; the chain is untouched.
- **`confluence`** — Confluence page **only**, no GitHub issue. For decision docs / RFCs that won't be turned into code. The page becomes the proposal's identity.
- *(GitHub-only is the **absence** of a Confluence config entry — not a mode value.)*

The **gate is shared and runs once.** Validate, audit, and the Stage-1 reader test all operate on `render(state)` as canonical markdown; Confluence is just a transport encoding of that same approved state, so the reader test is **not** re-run against the Confluence body — the existing `reader_test_hash` (keyed on state) covers both surfaces. Nothing in *Review gating* changes.

## Inputs

Picking order (highest priority first):

| Source | When | How |
|---|---|---|
| User-supplied path or inline text | Explicit argument | `/zeus:propose <path>` or `/zeus:propose "raw paste"` — argument wins over the others. |
| Plan file (e.g. `~/.claude/plans/*.md`) | After plan mode | Prefer `$CLAUDE_PLAN_FILE`; otherwise the most-recent `.md` under `~/.claude/plans/`. |
| Current conversation | Mid-session, no plan file | Summarise the conversation-so-far. |

## Prerequisites

- **Required:** `git` (run inside a repo), `gh` (GitHub CLI, authenticated), `jq`, and `python3` (used by `pin-refs.sh` to pin file citations to blob URLs).
- **Optional:** a JS runner — `npx` (bundled with Node) or `bun` — enables the token-usage footer; safely skipped if absent.
- **Confluence destination (optional):** the **Atlassian MCP** server, for repos configured to publish to Confluence (see *Destination* below). It's an agent tool, not a CLI, so it can't be probed from a script and is **unavailable in headless / cron runs** — confirm it with a live `getAccessibleAtlassianResources` call before relying on it, and fall back to GitHub-only when it's absent.

## Workflow

When the user asks to "create an issue", "file an issue", or invokes `/zeus:propose`, follow these steps.

### 0. Preflight & bootstrap

```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo (echo corrupts the JSON under zsh)
```

On `.ok == false`, present the `.remediation[]` fixes and re-check with `preflight.sh --fix`; proceed only at `ok: true`. Full flow (the `--fix` auto-install vs interactive steps like `gh auth login`): **`zeus/lib/PREFLIGHT.md`**.

### 1. Gather repo + ref context

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/issue-context.sh
```

Returns JSON:
- `repo` — `owner/name` from `gh repo view`
- `branch` — current branch
- `head_sha` — `git rev-parse HEAD`, used to pin all code references
- `related_issues` — open issues whose titles share keywords (best-effort)

Then resolve the destination once (cache it like the context): `bash ${CLAUDE_SKILL_DIR}/scripts/confluence-target.sh "$REPO"`. `{"configured":false}` → GitHub-only, nothing else changes. Configured → also publish to Confluence at step 6 per its `mode` (see *Destination*).

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
- **Build-ready — the execution axis (work-orders).** When `requires-review.sh` reports `build_ready_required` (a merge-closing issue with code signals and no invariants yet), Stage 1 also runs an **implementer persona** — "the agent that implements this cold" — and stamps `build_ready` (`ready|incomplete`) with its own hash. `review-gate.sh` requires it; `BUILD-INCOMPLETE` posts only with recorded `build_ready_consent`. This catches an issue that's *align-ready but not build-ready* (all questions decided, load-bearing rule still prose).

Full procedure — the contradiction-class checklist, the implementer persona, the stamp command, the grounding plan, and Stage 3 — is in **`references/rfc-mode.md`**. An issue that derives both `required: false` and `build_ready_required: false` (a tracking ticket) skips this step entirely.

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

When the build-ready gate reports **`BUILD-INCOMPLETE`**, surface the ranked contract gaps here as a **visible choice** (like a `review:"never"` skip — never a silent default): *pin them* (recommended — add the `MUST`/`MUST NOT` invariants + a concrete shape example, then re-render and re-test) or *post anyway* (sets `build_ready_consent`, recorded on the issue).

**Fallback (other agents):** if AskUserQuestion isn't available, pipe `preview.sh` to stdout, then prompt via bash:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/preview.sh "$(jq -r .title "$STATE_FILE")" "$DRAFT_PATH" 40
read -r -p "[1] Post  [2] Edit  [3] Save only  [4] Cancel > " choice
```

### 6. Publish to the destination set

A proposal publishes to one destination or several. The set comes from the
`confluence-target.sh "$REPO"` lookup: **GitHub-only** (default / repo unconfigured),
**`both`** (GitHub canonical + a Confluence page that backlinks it), or **`confluence`**
(Confluence only). Each destination is a **publish backend** conforming to
[`references/publish-contract.md`](./references/publish-contract.md) — the same three
verbs, the shared gates, the artifact URL on stdout. The skill **dispatches by name**
and composes the set; there is no router.

**GitHub** (`post-issue.sh`) — the default, and the canonical artifact under `both`:

```bash
GH_URL=$(bash ${CLAUDE_SKILL_DIR}/scripts/post-issue.sh \
  --title "<title>" --body-file "<draft-path>" --state "$STATE_FILE" \
  [--label <label>] [--assignee <user>] [--milestone <m>])
```

Prints the URL and exits. `--state` persists the
JSON under the issue number (`state.sh`) so a later amend reloads it. Appends a
create-only Claude Code usage footer (`telemetry.sh --issue`; self-disabling outside
Claude Code or under `CLAUDE_ISSUE_TELEMETRY=0` / the shared `CLAUDE_PR_TELEMETRY=0`).

#### 6b. Confluence (`confluence.sh`) — when the destination resolved `configured: true`

`confluence.sh` is the Confluence publish backend: the **curl-over-REST analogue of
`post-issue.sh`, no MCP**. It honors the same contract — same three verbs, the shared
`review-gate.sh`, **hard-enforced ownership** (it fetches the page author and refuses a
non-owned update), and **version-based drift it checks itself**.

**Setup (once):** export `CONFLUENCE_EMAIL` + `CONFLUENCE_API_TOKEN` (the curl analogue
of `gh auth`), and set `CONFLUENCE_CONVERTER` to a `markdown-on-stdin → storage-XHTML-on-stdout`
command (e.g. a `mark --compile-only` wrapper) — REST takes storage, not markdown. Absent
either, `confluence.sh` fails loudly rather than posting wrong-format.

1. **Order by mode.** `both` → run the GitHub post (6) FIRST so the page can backlink
   the canonical issue. `confluence` → skip GitHub entirely.
2. **Render the Confluence body** from the same approved state. `--telemetry` adds the
   create-only Claude Code usage footer (the Confluence analogue of `post-issue.sh`'s;
   pass it on **create**, omit on amend — the footer drops on re-render, same as GitHub).
   This step also bakes the `_via_` watermark and, in `both` mode, the issue backlink:
   ```bash
   BODY=$(bash ${CLAUDE_SKILL_DIR}/scripts/render.sh "$STATE_FILE" --format confluence \
     --sha "$HEAD_SHA" --repo "$REPO" --telemetry [--issue-url "$GH_URL"])   # --issue-url only in `both` mode
   ```
3. **Publish.** `confluence.sh` resolves cloud/space/parent from `--repo` (via
   `confluence-target.sh`), resolves `spaceId` from `spaceKey` if needed (persisting it
   back), converts the body, creates the page as a **child** of the configured parent,
   then writes `confluence_page_id` + `confluence_version` to state and **pins** it:
   ```bash
   CONF_URL=$(bash ${CLAUDE_SKILL_DIR}/scripts/confluence.sh \
     --title "<title>" --body-file "$BODY" --repo "$REPO" --state "$STATE_FILE")
   ```
4. **Print both URLs.** In `both` mode the GitHub issue stays the canonical resume
   target (its `--state` pin); the page id rides along on the same state.

If `confluence.sh` exits non-zero (auth / converter / network), report it and stop after
the GitHub post — don't silently drop the Confluence half.

Amend, comment, and supersede for a Confluence page use the same backend's
`--update` / `--comment` verbs — see **Updating an existing proposal** below.

## Updating an existing proposal (amend / supersede)

Triggers: "fold this into #N", "amend the issue/page", "update #N", "amend the RFC" (no number), `/zeus:propose <#N> "<change>"`. An amend is the **same compose pipeline entered from a rehydrated state** — edit the **state**, never the live artifact — so it reuses steps 3–4b above. The shape is identical for both destinations; only the resolve/ownership/drift/post calls differ by `provider` (which `resolve-target.sh` and the worktree pin both carry).

**GitHub** sequence (scripts under `${CLAUDE_SKILL_DIR}/scripts/`):

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

**Confluence** sequence — same skeleton, same backend. The writes go through
`confluence.sh` (no MCP); **ownership + version-drift are enforced inside `--update`**,
so they are not separate steps. The one remaining read — re-ingesting a live page when
state was lost — is a page fetch (curl `GET` or MCP), not a publish verb.

```bash
resolve-target.sh "<phrase>"                            # 0. resolve + CONFIRM (a confluence: candidate)
STATE_FILE=$(rehydrate.sh "confluence:<id>" [--body-file <fetched-page-md>])   # 1. load persisted state; --body-file re-ingests a fetched page only if state was lost
# 2. (no separate ownership/drift step — confluence.sh --update enforces BOTH in-backend at write)
# 3. edit state + append an Amendment Log line
BODY=$(render.sh "$STATE_FILE" --format confluence --sha "$HEAD_SHA" --repo "$REPO")   # 4. render + check + Stage-1 re-stamp
check.sh "$BODY" [--kind …]
confluence.sh --update <id> --title "<t>" --body-file "$BODY" --repo "$REPO" --state "$STATE_FILE"   # 5a. amend (ownership + version-drift gated in-backend; bumps version, re-persists, re-pins)
confluence.sh --comment <id> --body-file <findings> --repo "$REPO"                                    # 5b. not mine → comment (a non-owned --update is refused)
# 5c. supersede: confluence.sh create the NEW page, then confluence.sh --update the OLD with a prepended banner
#     > ⚠️ **Superseded by** [<new title>](<new url>)   — pages don't close; no delete
```

Two things the sequence rests on, with the rationale and the disposition-comment template in **`references/rfc-mode.md`** → *Amend vs supersede*:

- **Amend only your own proposal (step 0.5).** `ownership.sh` compares author to viewer — **GitHub:** `ownership.sh <N>` (issue author vs `gh` viewer); **Confluence:** `ownership.sh --author <pageAuthorId> --viewer <myAccountId>` (the agent fetches both via MCP). **Mine → amend** (the full sequence). **Not mine → comment, never edit** — composing a review against a teammate's proposal is fine, rewriting their authored artifact isn't. Run the review on *their* body, write the findings to a file, and post a **GitHub** comment with `post-issue.sh --comment <N> --body-file <path>` or a **Confluence** footer comment with `★ createConfluenceFooterComment(pageId, body)` — no `rehydrate`/drift/`--update`/`updateConfluencePage`. `post-issue --update` hard-refuses a non-owned issue regardless (`--force-amend` is the escape hatch); for Confluence the agent MUST honour the `ownership.sh` verdict before calling `updateConfluencePage` — there's no post-issue.sh in that path to backstop it.
- **Confirm the target before any write** (step 0) and **run the drift gate before editing** (step 2) — a wrong-target amend and an out-of-band edit are both invisible to every other gate. **GitHub** drift is a text diff (`drift-check.sh`, render vs live body); **Confluence** drift is a version check (`confluence-drift.sh`, stored `confluence_version` vs live `version.number`) — Confluence reformats markdown on round-trip, so a text diff would false-positive; the version number is the reliable signal. Re-run Stage 1 + re-stamp on **every** amend, both destinations.
- **Amend vs supersede:** decision unchanged → amend; the decision itself changed → supersede. **GitHub:** new issue, `Supersedes #<N>`, **close** the old. **Confluence:** new page, `Supersedes <old url>`, and prepend a **"⚠️ Superseded by"** banner to the old page (pages have no close, and the MCP has no delete). When the amend answers **reviewer feedback**, post **one** disposition comment afterward (`gh issue comment` / `createConfluenceFooterComment`) quoting each concern by its verbatim header with what changed — the artifact is the latest truth, the comment is the audit trail.

## Reviewing someone else's proposal (peer review)

Triggers: `/zeus:propose review #N`, "review #N", or any `#N` with `--as peer` (step 0 of Routing). This is the **inverse of an amend**: the self-gate (Stages 1–3) proves *your* draft before you post it; peer review points the **same cross-check at someone else's posted issue** and hands back trust-labeled findings as one comment. It is **read-only on the artifact** — it never `rehydrate`s, `--update`s, or pins (the target isn't yours). The output adapter is `post-issue.sh --comment`, which by construction skips the reader-test stamp, the state pin, and telemetry.

The engine and the finding contract (trust labels, the citation-drift check, the comment template) live in **`references/rfc-mode.md` → Peer review**. Operational sequence (GitHub):

```bash
# 0. resolve + CONFIRM the target (explicit #N wins; a phrase resolves via resolve-target.sh)
resolve-target.sh "<#N|phrase>" [--repo R]
# 0.5 ownership: peer expects mine:false. mine:true + --as peer is allowed (review your own as an outsider);
#     mine:true without --as peer is NOT a review — route to the self-gate / amend instead.
ownership.sh <N> [--repo R]
# 1. fetch THEIR live body + the head SHA to pin drift against (NO rehydrate, NO state file)
gh issue view <N> [--repo R] --json body,title -q .body > "$THEIR_BODY"
HEAD_SHA=$(bash ${CLAUDE_SKILL_DIR}/scripts/issue-context.sh | jq -r .head_sha)
# 1.5 STAGE 0 — SCOUT (Haiku 4.5; Sonnet 5 for a contested decision doc): one cheap pass over
#      "$THEIR_BODY" → {doc_type, stages, claim_inventory, tier_per_check, hotspots}. Sizes the
#      Stage-2 fan-out and picks model tiers. Recall-guarded: never skips Stage 2 grounding.
# 2. run the cross-check read-only against "$THEIR_BODY" (rfc-mode.md → Stage 0 + Peer review):
#      Stage 1 reader test · Stage 2 grounding — fan-out SIZED by claim_inventory, TIERED per
#      tier_per_check (citation-drift/spot-check → Haiku/Sonnet, lean-claim refute → Opus) ·
#      Stage 3 steelman (Opus, iff scout armed it)
#      → citation-drift check: every `path:line` / blob-SHA cite in their body vs current HEAD_SHA
#      → merge + verdict synthesis in the MAIN context on Opus (only this promotes to Confirmed)
# 3. render findings to a file: factual layer trust-labeled (Confirmed w/ evidence / Hypothesis
#      w/ verify / drop), judgment layer (reader-test, steelman) posed as questions — per template
# 4. post — body untouched
post-issue.sh --comment <N> --body-file "$FINDINGS" [--repo R]
```

Gating note: peer review is **explicitly invoked**, so it does **not** consult `requires-review.sh` (that reads a *state* file, which a peer target doesn't have) — the **scout (Stage 0)** plays the floor's role here, deciding depth + tiers, but it may never skip Stage 2 grounding. Event is **comment-only** — findings pose questions about intent so the author decides what to change; there is no "request changes" analogue (that verdict is the author's, exactly as in `review-pr`).

**Config** (shared `review.*` namespace, same as `review-pr`): `scout_model` (`claude-haiku-4-5-20251001`), `scout_escalate_model` (`claude-sonnet-5`), `tiers` (mechanical → `claude-sonnet-5`, judgment → `claude-opus-4-8`), `synthesis_model` (`claude-opus-4-8` — the merge/verdict pass).

**Confluence parity:** the same flow posts a footer comment via `createConfluenceFooterComment(pageId, body)` — `ownership.sh --author <pageAuthorId> --viewer <myAccountId>` gates it (see SKILL.md ownership note and `references/rfc-mode.md`).

## Progressive disclosure

Load these references when you need the detail; the headings above are enough for a happy path.

- `references/exemplars.md` — annotated links to five issues that demonstrate each section type.
- `references/section-patterns.md` — extraction rules per section (what to look for in source, how to render).
- `references/diagram-recipes.md` — Mermaid `flowchart TD` and ASCII state-diagram templates; "when to use which".
- `references/before-after-recipes.md` — diff fence vs twin `BEFORE`/`AFTER` fences vs side-by-side table; "when to use which".
- `references/rfc-mode.md` — the review + amend + peer-review playbook (the depth behind steps 4b, "Updating", and "Reviewing someone else's proposal"): the authoring loop, the **Stage 0 scout** (cheap triage that refines `requires-review.sh`'s floor, sizes the Stage-2 fan-out, and tiers the models), full Stage 1/2/3 procedures + the reader-test stamp command, the amend operational sequence with its target-confirmation and drift-gate safeguards, amend vs supersede, the disposition-comment template, the Amendment Log, invariants-in-content, and the **peer-review finding contract** — the two-layer rule (factual layer trust-labeled with evidence-before-Confirmed; judgment layer posed as questions), citation-drift, comment template.
- `references/quality-criteria.md` — the 7 quality criteria, scored by the Stage-1 reader from the outside.
- `references/code-guidelines.md` — when a code snippet earns its place in an issue ("if removing it changes nothing, delete it").
- `references/house-style.md` — the conventions this skill writes by, and *why* (progressive disclosure, mention-once, before/after, the RFC-2119 layer split).

## Constraints

- **Discussion-first.** The issue exists to align on a decision, not to be a status dashboard. Optimize sections for "a reviewer can quote a row and disagree."
- **Don't invent decisions.** If a default lean isn't in the source, tag it `[draft]` and let the user accept or override.
- **Preserve voice when possible.** Issue-ready plans get lifted verbatim; only summarise when the source is unstructured.
- **Pin code references.** Long-lived decision docs reference code by `blob/<sha>/path#L`, not by moving `path:line` (which rots).
- **Tables stay scannable.** Body table cells are short phrases — no permalinks, no multi-sentence grounding. Evidence goes in the `code_grounding` appendix; rationale goes in a `<details>` block under the table. A reader should get the whole decision from the visible layer and only expand for proof.
- **Progressive disclosure by default.** Visible layer: status → context findings (bullets) → decision tables → discussion questions → scope/acceptance. Collapsed layer: per-item rationale, code grounding, long fixtures. For substantial / decision-bearing docs, also lead Context with a TL;DR + a "Decisions needed" digest and size any phases (see `references/house-style.md` → "Lead substantial proposals with a skim layer").
- **Cancel is free.** The draft is always written to disk before the post step, so "Save draft only" or "Cancel" never loses work.
