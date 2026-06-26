---
name: review-pr
description: >-
  Review a GitHub pull request and post findings as comments (inline where
  possible), each clearly labeled Confirmed (with reproduction evidence) or
  Hypothesis (for the author to verify). Checks the PR out in an isolated
  worktree, reviews across correctness, concurrency, resilience, data/migrations,
  API contract, security, and tests, and verifies what it cheaply and safely can.
  Use when asked to review a PR, do a code review, or critique a pull request.
  Triggers on: "review pr", "review this pr", "code review", "critique this pr",
  a PR URL, or "/zeus:review-pr <url|number>".
license: MIT
compatibility: Requires git, gh (GitHub CLI) authenticated, jq, python3. Language runtimes / a local Postgres are optional — they only enable the verify tier.
metadata:
  author: sunnywong
  version: "0.1"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(python3:*) Read Grep LSP AskUserQuestion ScheduleWakeup Skill Task Agent

---

# Review PR

Review a pull request and leave findings the author can act on. Every finding is
posted with an honest trust label — **Confirmed** (reproduced, with evidence) or
**Hypothesis** (a concern to verify) or **Nit** — so nothing is hidden and
nothing is overstated. This skill is read-only on the PR's code: it diagnoses and
comments, it never edits, commits, or pushes.

State lives under the checkout's `.git/review-pr/` (created by `scripts/lib.sh`).
Prefer the scripts in `scripts/` over hand-rolled `gh`/`git` — they own the
diff/anchor extraction and the review assembly you'd otherwise reproduce by hand.

## Modes

| Invocation | Intent |
|---|---|
| `/zeus:review-pr <url\|number>` | Full review. **`select-mode.sh` picks single-context vs parallel fan-out from the diff size** (parallel when reviewable LOC ≥ 400 or files ≥ 8). Dry-run: renders the review, posts nothing. |
| `… --deep` | Force parallel fan-out regardless of size. |
| `… --single` | Force single-context regardless of size. |
| `… <handler>` | Run one dimension standalone (`correctness`, `concurrency-idempotency`, `resilience`, `data-migrations`, `api-contract`, `security`, `tests`) — always single-context. |
| `… --submit` | Post the review (event `COMMENT`). Default without this flag is dry-run. |
| `… --submit --request-changes` | Post as `REQUEST_CHANGES` (explicit only; the skill never auto-blocks). |

## Flow

### 1. Resolve & isolate
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/identify-pr.sh <url|number> > /tmp/rp-pr.json   # → owner/repo/number/head_sha/foreign
bash ${CLAUDE_SKILL_DIR}/scripts/ensure-checkout.sh --pr <n> --repo <owner/repo> --foreign <bool>
```
- If `.mode == "worktree"` and `.already_inside == false`: call the **EnterWorktree**
  tool with `.path` before reading any code, so you review the PR head — not
  whatever branch the launch checkout is on.
- If `.mode == "foreign-clone"`: read and run from `.path` directly (absolute paths).
- Then extract the diff + anchorable lines (the single source of truth for where
  inline comments may land):
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --pr <n> --repo <owner/repo>
bash ${CLAUDE_SKILL_DIR}/scripts/select-mode.sh [--deep|--single]   # → {mode, applicable_handlers, reviewable_loc, ...}
```
`select-mode.sh` is the deterministic decision: read `.mode` (`single`|`parallel`)
and `.applicable_handlers`. Log the line it prints so misfires are tunable.

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

### 6. Render & post (dry-run by default)
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --dry-run        # default: render, post nothing
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --submit         # explicit: post one COMMENT review
```
Show the dry-run to the user. Only `--submit` on explicit instruction. The script
validates labels (confirmed⇒evidence, hypothesis⇒verify), demotes off-diff
anchors to the summary, and dedups already-posted ids on re-review.

### 7. Cleanup
Remove the per-run state and any throwaway verify resources. Leave the worktree
(reused on a re-review of the same PR) unless asked to remove it.

## Scope discipline
- Diagnose only — no edits/commits/pushes to the PR.
- Don't post pre-existing issues (true on the base branch) as this PR's findings.
- Default review event is `COMMENT`; never auto-`REQUEST_CHANGES`.
- A clean pass (no findings) is a valid result — say so; don't manufacture noise.
