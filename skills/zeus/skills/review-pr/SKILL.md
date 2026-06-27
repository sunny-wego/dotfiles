---
name: review-pr
description: >-
  Review code and report findings, each clearly labeled Confirmed (with
  reproduction evidence) or Hypothesis (to verify). Reviews across correctness,
  concurrency, resilience, data/migrations, API contract, security, and tests, and
  verifies what it cheaply and safely can. Auto-detects its target: an open PR
  (checks it out in an isolated worktree, posts findings as comments) OR — when
  you're pre-PR — the local working diff vs its base (renders findings locally,
  posts nothing). Read-only either way: it diagnoses and hands findings back, never
  edits. Use when asked to review a PR, do a code review, critique a pull request,
  or review your local changes before opening a PR. Triggers on: "review pr",
  "review this pr", "code review", "critique this pr", "review my changes/diff
  before PR", a PR URL, or "/zeus:review-pr [url|number|--local]".
license: MIT
compatibility: Requires git, gh (GitHub CLI) authenticated, jq, python3. Language runtimes / a local Postgres are optional — they only enable the verify tier.
metadata:
  author: sunnywong
  version: "0.1"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(python3:*) Read Grep LSP AskUserQuestion ScheduleWakeup Skill Task Agent

---

# Review PR

Review code and leave findings the author can act on. Every finding carries an
honest trust label — **Confirmed** (reproduced, with evidence), **Hypothesis** (a
concern to verify), or **Nit** — so nothing is hidden and nothing is overstated.
This skill is **read-only**: it diagnoses and reports, it never edits, commits, or
pushes. Its terminal action is a **handoff** — it hands the findings back; fixing is
the caller's job (the LLM, in its normal flow).

It works in two targets, **auto-detected** so you never have to say which:

- **Remote (open PR)** — the reviewer role: checks the PR out in an isolated
  worktree and posts findings as comments (the inverse of `address-pr`).
- **Local (pre-PR)** — the author's self-review: reviews the current branch's
  working diff vs its base with the **same** engine, renders findings locally, and
  **posts nothing** (there's no PR yet). This is the pre-PR gate `/zeus:implement`
  and `/zeus:create-pr` invoke before a PR is opened.

State lives under the checkout's `.git/review-pr/` (created by `scripts/lib.sh`).
Prefer the scripts in `scripts/` over hand-rolled `gh`/`git` — they own the
target detection, diff/anchor extraction, and review assembly.

## Modes

The default — **no flag, no arg** — auto-detects the target via `detect-target.sh`
(see Flow step 1): local when you're pre-PR, remote once a PR exists for the branch.
Flags are overrides.

| Invocation | Intent |
|---|---|
| `/zeus:review-pr` | **Auto-detect.** No open PR for the branch → review the **local** working diff (pre-PR). Open PR exists and the branch matches its head → review that **PR**. Open PR but local has uncommitted/unpushed changes → **local** (review the real on-disk state, not the stale pushed head). |
| `… <url\|number>` | Force **remote** review of that PR (explicit override). |
| `… --local [--base <ref>] [--include-dirty]` | Force **local** review (override — even if a PR is open). `--base` picks the diff base (default: repo default branch); `--include-dirty` includes uncommitted changes. |
| `… --deep` | Force parallel fan-out regardless of size. |
| `… --single` | Force single-context regardless of size. |
| `… <handler>` | Run one dimension standalone (`correctness`, `concurrency-idempotency`, `resilience`, `data-migrations`, `api-contract`, `security`, `tests`) — always single-context. |
| `… --submit` | (remote only) Post the review (event `COMMENT`). Default without this flag is dry-run; refused in local mode (no PR to post to). |
| `… --submit --request-changes` | Post as `REQUEST_CHANGES` (explicit only; the skill never auto-blocks). |

In both `select-mode.sh` picks single-context vs parallel fan-out from the diff
size (parallel when reviewable LOC ≥ 400 or files ≥ 8).

## Flow

### 1. Detect the target (local vs remote), then resolve
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/detect-target.sh "$@" > /tmp/rp-target.json   # → {mode:"local"|"remote", ...}
```
`detect-target.sh` is the deterministic decision (auto by default; `--local`/`--base`
and a PR arg are overrides — see its header). Read `.mode` and branch:

**`.mode == "local"` (pre-PR self-review):** you're already on the branch, so there's
no PR to resolve and no checkout. Extract the working diff and pick the run mode:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --local [--base <ref>] [--include-dirty]
bash ${CLAUDE_SKILL_DIR}/scripts/select-mode.sh [--deep|--single]
```
If `detect-target.sh` returned a `.note` (e.g. an open PR exists but the branch has
unpushed/uncommitted changes), surface it so the user knows local was chosen on
purpose. Skip `identify-pr.sh` / `ensure-checkout.sh` entirely.

**`.mode == "remote"` (review an open PR):**
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/ensure-checkout.sh --pr <n> --repo <owner/repo> --foreign <bool>
```
- If `.mode == "worktree"` and `.already_inside == false`: call the **EnterWorktree**
  tool with `.path` before reading any code, so you review the PR head — not
  whatever branch the launch checkout is on.
- If `.mode == "foreign-clone"`: read and run from `.path` directly (absolute paths).
- Then extract the diff + anchorable lines:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --pr <n> --repo <owner/repo>
bash ${CLAUDE_SKILL_DIR}/scripts/select-mode.sh [--deep|--single]   # → {mode, applicable_handlers, reviewable_loc, ...}
```
Either way `extract-diff.sh` writes the diff + anchorable lines (the single source of
truth for where inline comments may land), and `select-mode.sh` deterministically
reads `.mode` (`single`|`parallel`) and `.applicable_handlers`. Log the line it
prints so misfires are tunable.

### 2. Read the contract once
Read `references/review-contract.md` before the first handler — it owns the
severity rubric, the Tier-0/Tier-1 verification protocol, the Tier-1 safety
fence, and the diagnose-only discipline. Read `references/findings-schema.md` for
the finding shape and `references/comment-format.md` only when rendering.

### 3. Select applicable dimensions
`select-mode.sh` already emitted `.applicable_handlers` from the diff (path +
keyword heuristics). Treat that as the candidate set: read those handler files,
and use the table below to sanity-check it — add a lens the heuristic missed, or
drop one whose precondition doesn't truly hold. A docs/config-only PR may trigger
none of the heavy ones.

| Pri | Dimension | Precondition (from the diff) | Handler |
|--|--|--|--|
| 1 | Correctness | any code change | `handlers/correctness.md` |
| 2 | Concurrency / idempotency | shared state, queues, webhooks, retries, dedup, background tasks, locks | `handlers/concurrency-idempotency.md` |
| 3 | Resilience (failure paths) | any external call, error branch, timeout, retry, new failure mode | `handlers/resilience.md` |
| 4 | Data / migrations | `migrations/`, schema/model changes, new tables/columns/indexes | `handlers/data-migrations.md` |
| 5 | API contract | request/response handlers, serializers, event parsing, external-API calls, identity/keys | `handlers/api-contract.md` |
| 6 | Security | auth, secrets, crypto, signature verify, untrusted input, bot/loop/abuse guards | `handlers/security.md` |
| 7 | Tests / verifiability | every code change (is the change guarded?) | `handlers/tests.md` |

### 4. Diagnose (branch on `.mode`)
- **`mode == "single"`:** work each applicable handler in turn in this context.
  Each appends its findings to `$FINDINGS_FILE` (schema-shaped, under `with_lock`).
- **`mode == "parallel"`:** spawn one **Agent** per applicable handler in a single
  message, each given the diff, its handler file, `review-contract.md`, and the
  finding schema; each returns its findings array. The agents are **read-only
  diagnosis** — they never run the verify tier (step 5 does, centrally). Then:
  - **Barrier — merge + dedup** all findings by `(path, line)` + claim similarity.
  - **Synthesis pass (parallel only):** one agent reads the *full* merged set and
    looks for what isolated lenses miss — **cross-dimension findings** (e.g. a
    race × a failure path × dedup that together lose an event), severity upgrades,
    and fragments of one issue filed by two handlers (merge them). This recovers
    the cross-dimension reasoning a single context gets for free. Append/adjust
    findings accordingly.

### 5. Verify (centrally, after diagnosis)
For findings a cheap, safe check can settle (per the contract's Tier-1 + fence):
**detect the repo's stack and use its native tooling** (see the stack table in
`review-contract.md` — never assume Python), run the cheapest check that
reproduces the claim, and capture both the **ordered commands** and the **literal
output** into `evidence`, then set `status: confirmed`; otherwise leave
`hypothesis` with a `verify` step. Refuted → drop. Verification is **central and
serial** even under `--deep` (the parallel agents only diagnose) — never touch
shared/long-lived infra; on any denial, stay `hypothesis`.

### 6. Render & hand off
```bash
# remote PR:
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --dry-run        # default: render, post nothing
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --submit         # explicit: post one COMMENT review
# local (pre-PR):
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --local          # render findings locally, post nothing
```
The script validates labels (confirmed⇒evidence, hypothesis⇒verify) and demotes
off-diff anchors to the summary in either mode.

- **Remote:** show the dry-run to the user; only `--submit` on explicit instruction
  (it dedups already-posted ids on re-review).
- **Local:** `post-review.sh` always renders and **posts nothing** (it refuses
  `--submit` — there's no PR). **Hand the findings back to the caller** — summarize
  the Confirmed findings and worthwhile Hypotheses so the LLM can fix them in its
  normal flow. review-pr does not fix, loop, or re-review; that's the caller's job.

### 7. Cleanup
Remove the per-run state and any throwaway verify resources. Leave the worktree
(reused on a re-review of the same PR) unless asked to remove it.

## Scope discipline
- **Diagnose only — no edits/commits/pushes, in either mode.** Local mode reviews the
  author's own diff but still never fixes it: it renders findings and hands them back.
  Fixing belongs to the caller (`/zeus:implement`, `/zeus:create-pr`, or the user).
- Don't report pre-existing issues (true on the base branch) as this change's findings.
- Default review event is `COMMENT`; never auto-`REQUEST_CHANGES`.
- A clean pass (no findings) is a valid result — say so; don't manufacture noise.
