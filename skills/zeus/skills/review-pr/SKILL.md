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
  edits. On a re-review of a PR it already reviewed, it first re-verifies its own
  earlier comments — replying and resolving the ones now fixed, flagging the rest —
  then reviews the new diff and posts only genuinely new findings (no duplicates).
  Each run is one pass; the user re-runs it per round, it never loops itself. Also
  accepts a Slack message link: it reads that message to find the PR, reviews it,
  and replies a short summary in the same thread (re-replies on a same-session
  re-review). Use when asked to review a pull request, critique a PR, or review your
  local changes before opening a PR. Triggers on: "review pr", "review this pr",
  "code review this pr", "critique this pr", "review my changes/diff before PR", a
  PR URL, a Slack message link to review, or
  "/zeus:review-pr [url|number|slack-link|--local]".
license: MIT
compatibility: Requires git, gh (GitHub CLI) authenticated, jq, python3. Language runtimes / a local Postgres are optional — they only enable the verify tier. The Slack entry point additionally needs the Slack MCP.
metadata:
  author: sunnywong
  version: "0.5"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(python3:*) Read Grep LSP AskUserQuestion ScheduleWakeup EnterWorktree Skill Task Agent mcp__plugin_slack_slack__slack_read_thread mcp__plugin_slack_slack__slack_send_message

---

# Review PR

Review code and leave findings the author can act on. Every finding carries an
honest trust label — **Confirmed** (reproduced, with evidence), **Hypothesis** (a
concern to verify), or **Nit** — so nothing is hidden and nothing is overstated.
This skill is **read-only**: it diagnoses and reports, it never edits, commits, or
pushes. Its terminal action is a **handoff** — it hands the findings back; fixing is
the caller's job (the LLM, in its normal flow).

It runs the **same review engine** along two **auto-detected** axes, so you never
have to say which (overridable — see Modes):

- **`source` — where the diff is.** `local` = the current branch's working diff vs
  its base (no PR needed); `remote` = an open PR, checked out in an isolated worktree.
- **`role` — whose work it is** (this is the distinction that matters): `self` = **my
  work** → findings are **handed back to fix**, nothing is posted; `peer` = **someone
  else's PR** → findings are **posted as review comments** (the reviewer role, the
  inverse of `address-pr`). Locality is not authorship: reviewing my *own* open PR is
  `source=remote, role=self`.

So **reviewing my own work and reviewing someone else's are different outputs of one
engine** — self hands back (and feeds `/zeus:create-pr`'s pre-PR gate); peer posts
honest trust-labeled comments and stops. Either way the skill is
**read-only on code** — it never edits.

State lives under the checkout's `.git/review-pr/` (created by `scripts/lib.sh`).
Prefer the scripts in `scripts/` over hand-rolled `gh`/`git` — they own the
target detection, diff/anchor extraction, and review assembly.

## Modes

The default — **no flag, no arg** — auto-detects `source` and `role` via
`detect-target.sh` (Flow step 1). Flags are overrides.

| Invocation | Intent |
|---|---|
| `/zeus:review-pr` | **Auto-detect.** No open PR for the branch → **local** self-review (pre-PR). Open PR at the branch head → review that **PR** (`role` = self if you authored it, else peer). Open PR but local has uncommitted/unpushed changes → **local** (review the real on-disk state, not the stale pushed head). |
| `… <url\|number>` | Force a **remote** PR (role still auto: self if yours, peer otherwise). |
| `… <slack-message-link>` | **Slack-triggered.** Read the linked Slack message → find the PR URL it contains → review that PR (remote, peer) → reply a summary **in that thread**. The thread coordinate is persisted (step 1), so a same-session re-review (next invocation, even with no arg) replies in the same thread. The linked message must contain the PR URL. |
| `… --local [--base <ref>] [--include-dirty]` | Force **local** self-review (even if a PR is open). `--base` picks the diff base (default: repo default branch); `--include-dirty` includes uncommitted changes. |
| `… --as self\|peer` | Force the **role** (e.g. review your own PR as a peer would, or hand a peer PR's findings back instead of posting). |
| `… --deep` / `… --single` | Force parallel fan-out / single-context regardless of size. |
| `… <handler>` | Run one dimension standalone (`correctness`, `concurrency-idempotency`, `resilience`, `data-migrations`, `api-contract`, `security`, `tests`) — always single-context. |
| `… --dry-run` | **Peer only.** Render the review but post **nothing** (preview). Peer **auto-submits by default** (this skill only runs on an explicit review request, so the post is what was asked for); use `--dry-run` when you want to eyeball it first. |
| `… --request-changes` | **Peer only.** Submit with event `REQUEST_CHANGES` instead of the default `COMMENT`. **Never automatic** — explicit opt-in only; the default leaves the author to decide what to fix. |

`select-mode.sh` sets the deterministic **floor** — single-context vs parallel fan-out
from diff size (parallel when reviewable LOC ≥ 400 or files ≥ 8) plus the candidate
`applicable_handlers` — for either role. A cheap **scout** (step 3.75) then *refines*
within that floor: it narrows the live lenses, picks a per-lens model tier, and localizes
hot spots, so spend tracks risk. The floor is a safety net the scout cannot lower.

**Config** (zeus config, repo > user > shipped; keys under `review.`):
`enable_scout` (true), `scout_model` (`claude-haiku-4-5-20251001`), `scout_escalate_model`
(`claude-sonnet-5`, for migrations/auth/secrets diffs), `tiers` (mechanical →
`claude-sonnet-5`, reasoning → `claude-opus-4-8`), `synthesis_model` (`claude-opus-4-8`,
= synthesis + central verify), `tests_first` (true), `max_test_seconds` (120),
`test_exclude_regex` (skips integration/e2e), `loc_threshold` (400), `file_threshold` (8).

## Flow

### 1. Detect the target (source + role), then resolve

**Slack-triggered first (arg is a Slack message link, `*slack.com/archives/…`).**
Resolve it to a PR, then fall through to the normal remote path with that PR URL —
detect-target never sees the Slack link (it rejects one by design):
```bash
coords=$(bash ${CLAUDE_SKILL_DIR}/scripts/slack-thread.sh parse "<slack-link>")  # → {channel, thread_ts, msg_ts}
```
Read the thread yourself with `slack_read_thread(channel_id=<coords.channel>,
message_ts=<coords.thread_ts>)`, then from the returned messages capture two things:
the **PR URL**, and the **requester** = the `user` (Slack id) of the linked message
(`coords.msg_ts`; fall back to the thread parent) — the person who asked for the
review, whom step 6b must ping.
```bash
printf '%s' "<thread message text>" | bash ${CLAUDE_SKILL_DIR}/scripts/slack-thread.sh extract-pr  # → PR URL
```
Now continue as a normal **remote, peer** review of that PR URL (run
`detect-target.sh <pr-url>`, not `"$@"`). **After** the checkout + EnterWorktree
(remote branch below), persist the thread + requester so step 6b and any
same-session re-review can find them:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/slack-thread.sh save --channel <channel> --thread-ts <thread_ts> --msg-ts <msg_ts> --pr-url <pr-url> --requester <slack-user-id>
```
**Same-session re-review:** invoke again with the PR URL/number you already remember
— `slack-thread.sh get` recovers the stored thread for the reply, so no re-paste is
needed. (A non-Slack invocation has no `$SLACK_FILE` and simply skips step 6b.)

For a normal (non-Slack) invocation, start here:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/detect-target.sh "$@" > /tmp/rp-target.json   # → {source, role, ...}
```
`detect-target.sh` is the deterministic decision (auto by default; `--local`/`--base`,
a PR arg, and `--as` are overrides — see its header). Read `.source` and `.role`:
`.role` decides the output adapter in step 6 (self → hand back; peer → post). Branch
on `.source`:

**`.source == "local"` (working diff, always `role=self`):** you're already on the
branch, so there's no PR to resolve and no checkout. Extract the working diff and pick
the run mode:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --local [--base <ref>] [--include-dirty]
# Re-review delta scoping (step 0b) also applies locally: a second self-review after a
# commit diagnoses only what changed since the last one. $REVIEWED_HEAD_FILE is written
# by post-review at the end of every review (self included); absent → full working diff.
since=$(cat "$REVIEWED_HEAD_FILE" 2>/dev/null || true)
if [ -n "$since" ] && [ "$since" != "$(jq -r .head_sha "$PR_FILE")" ]; then
  bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --local [--base <ref>] --since "$since"
fi
bash ${CLAUDE_SKILL_DIR}/scripts/select-mode.sh [--deep|--single]
bash ${CLAUDE_SKILL_DIR}/scripts/run-changed-tests.sh              # → $TESTS_FILE (step 3.5; best-effort)
```
If `detect-target.sh` returned a `.note` (e.g. an open PR exists but the branch has
unpushed/uncommitted changes), surface it so the user knows local was chosen on
purpose. Skip `identify-pr.sh` / `ensure-checkout.sh` entirely. (Local self-review has
no PR, so no `prior-findings.sh` — role is always self; findings are handed back.)

**`.source == "remote"` (review an open PR):**
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/ensure-checkout.sh --pr <n> --repo <owner/repo> --foreign <bool>
```
- If `.mode == "worktree"` and `.already_inside == false`: call the **EnterWorktree**
  tool with `.path` before reading any code, so you review the PR head — not
  whatever branch the launch checkout is on.
- If `.mode == "foreign-clone"`: read and run from `.path` directly (absolute paths).
- Then extract the diff + anchorable lines, recover prior findings, scope the delta
  (re-review), and run the changed-area tests:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --pr <n> --repo <owner/repo>   # full diff + anchors; writes $PR_FILE
bash ${CLAUDE_SKILL_DIR}/scripts/prior-findings.sh   # → $PRIOR_FILE; also reconstructs $REVIEWED_HEAD_FILE if a prior review exists
# Re-review delta scoping (step 0b): if we have a last-reviewed head that DIFFERS from
# the current head, produce $DELTA_DIFF_FILE so NEW-findings diagnosis reads only the
# new commits (prior findings are still re-verified in step 5b; anchors/posting use the
# full diff). A first review (no $REVIEWED_HEAD_FILE) simply skips --since → full diff.
since=$(cat "$REVIEWED_HEAD_FILE" 2>/dev/null || true)
if [ -n "$since" ] && [ "$since" != "$(jq -r .head_sha "$PR_FILE")" ]; then
  bash ${CLAUDE_SKILL_DIR}/scripts/extract-diff.sh --pr <n> --repo <owner/repo> --since "$since"   # → $DELTA_DIFF_FILE
fi
bash ${CLAUDE_SKILL_DIR}/scripts/select-mode.sh [--deep|--single]   # reads the delta when present → {mode, applicable_handlers, ...}
bash ${CLAUDE_SKILL_DIR}/scripts/run-changed-tests.sh              # → $TESTS_FILE (step 3.5; best-effort)
```
`extract-diff.sh` writes the diff + anchorable lines (the single source of truth for
where inline comments may land) and, on a re-review, `$DELTA_DIFF_FILE`; `select-mode.sh`
reads the delta when present so `.mode`/`.applicable_handlers` reflect the NEW work.
Log the line it prints so misfires are tunable. `prior-findings.sh` recovers this
skill's own unresolved comments from earlier rounds (matched by the `zeus:review-pr
id=` marker) — a **non-empty `$PRIOR_FILE` means this is a re-review**: you'll address
those comments in step 5b, and step 6 won't re-post anything already on the PR. It also
reconstructs `$REVIEWED_HEAD_FILE` from the prior review's commit when the local marker
is missing (a wiped worktree), so the delta base survives.

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

### 3.5 Fold in the changed-area test results
`run-changed-tests.sh` (step 1) already ran the repo's own tests for the changed files
— the unit slice; integration/e2e are excluded (they need infra) — and wrote
`$TESTS_FILE` (`{status, all_passed, groups[...]}`). This is the cheapest, highest-signal
oracle; read it *before* diagnosing:
- A **passing** test exercising a changed path is a ready-made refute — a hypothesis
  whose mechanism it covers is likely already guarded (cite it in step 5). A **failing**
  test is a confirmed-bug signal — lead with it.
- `status: skipped` / `no_changed_tests` just means no cheap oracle here — proceed; it
  is never a blocker.
Pass `$TESTS_FILE` into the diagnosis prompts and the central verify (step 5).

### 3.75 Scout the risk map (cheap triage → how much to spend)
Spawn **one** `zeus:scout` subagent to set depth + model tier, so spend is proportional to
risk. Give it the diff (`$DELTA_DIFF_FILE` on a re-review, else `$DIFF_FILE`), the PR
title/body, `select-mode`'s JSON, and `$TESTS_FILE`.
- **Model:** `review.scout_model` (default `claude-haiku-4-5-20251001`); **escalate to
  `review.scout_escalate_model` (default `claude-sonnet-5`)** on a high-blast-radius diff
  — i.e. `select-mode`'s `.applicable_handlers` includes `data-migrations` or `security`.
- **Returns:** `{difficulty: low|medium|high, live_lenses: [...], hotspots:
  [{file, why}], tier_per_lens: {lens: model}, skipped: [{lens, why}],
  recommend: single|targeted-fanout}`. `skipped` records every `.applicable_handlers`
  lens the scout dropped **and the reason** — one line per lens (e.g. `{lens:
  "security", why: "no auth/crypto/untrusted input in diff"}`). This is not optional
  bookkeeping: it is the structured form of the "stated reason" the guardrail requires,
  and it feeds the reader-facing Coverage block (step 6).
- **Persist the decision** so the Coverage renderer can read it:
  `Write` the returned JSON verbatim to `$SCOUT_FILE` (`.git/review-pr/scout.json`).
- **Guardrails (recall-safe):** the scout may only **refine within `select-mode`'s
  deterministic floor** — narrow `live_lenses`, assign tiers, localize hotspots. It may
  **not** downgrade a floor-`parallel` (`.mode == "parallel"`) into `single`, nor drop a
  `.applicable_handlers` lens without recording it in `skipped` with a reason (a
  kept-but-doubted lens stays at ≥ Sonnet 5). A mis-scored scout thus costs a wrong
  tier or an extra lens — never a missed bug.
- Skip the scout when `review.enable_scout=false` (→ fall back to the deterministic
  `.mode` branch) or on a trivial docs/config-only diff.

### 4. Diagnose (dispatch on the scout's `recommend`, bounded by the floor)
Diagnosis reads the **delta** on a re-review (`$DELTA_DIFF_FILE` — only the new commits);
prior findings are re-verified separately in step 5b.
- **`recommend == "single"`** (low difficulty / small delta, and the floor is not
  `parallel`): work each lens in `live_lenses` in turn **in this (Opus) context**, no
  fan-out. Append findings to `$FINDINGS_FILE` (schema-shaped) as you go — a single
  writer, so no lock is needed.
- **`recommend == "targeted-fanout"`** (or floor `.mode == "parallel"`): spawn one
  **`zeus:diagnostician` per `live_lens`** in a single message, each with **`model =
  tier_per_lens[lens]`** (mechanical lenses — data-migrations, api-contract, tests —
  default `claude-sonnet-5`; reasoning lenses — concurrency, resilience, correctness —
  `claude-opus-4-8`), a prompt focused on the scout's `hotspots`, plus its handler file,
  `review-contract.md`, the finding schema, and `$TESTS_FILE`. `zeus:diagnostician` is
  **read-only by construction** (no Bash/Edit/Write) — it **returns** its lens's findings
  as schema-shaped JSON and never runs the verify tier (step 5 does, centrally). Then:
  - **Barrier — collect + merge + dedup:** gather every diagnostician's returned
    findings, write them to `$FINDINGS_FILE` (the orchestrator is the sole writer),
    then merge + dedup by `(path, line)` + claim similarity.
  - **Synthesis pass** (**Opus**, `review.synthesis_model` default `claude-opus-4-8`,
    in this main context — *not* the scout or the per-lens explorers): read the *full*
    merged set for what isolated lenses miss — **cross-dimension findings** (a race × a
    failure path × dedup that together lose an event), severity upgrades, and fragments
    of one issue filed by two handlers (merge them). Append/adjust findings.

### 5. Verify (centrally, after diagnosis — Opus, this context)
Runs in the **main context on Opus** (`review.synthesis_model`), never the scout or the
per-lens explorers — this is the decisive, deliberately-not-cheap step. First **consult
`$TESTS_FILE`**: a green test already exercising a finding's mechanism refutes or
downgrades it for free (cite the test as evidence); a red one confirms. For what the
suite doesn't settle, per the contract's Tier-1 + fence: **detect the repo's stack and
use its native tooling** (see the stack table in `review-contract.md` — never assume
Python), run the cheapest check that reproduces the claim, and capture both the
**ordered commands** and the **literal output** into `evidence`, then set `status:
confirmed`; otherwise leave `hypothesis` with a `verify` step. Refuted → drop.
Verification is **central and serial** even under fan-out (the parallel agents only
diagnose) — never touch shared/long-lived infra; on any denial, stay `hypothesis`.

### 5b. Address prior review comments (peer re-review only)
Skip when `$PRIOR_FILE` is empty (first review of this PR) or `role=self`. Otherwise
`$PRIOR_FILE` holds this skill's own **unresolved** comments from earlier rounds,
each with its `prior_status`, `thread_id`, and `comment_id`. **Re-verify every one
against the CURRENT head** using the same discipline as step 5 (review-contract.md
Tier-0/Tier-1 + the safety fence) — re-run the recorded repro if it was
`confirmed`, re-run its `verify` step if it was `hypothesis`. Reach a verdict from
**fresh, recorded evidence — never infer "fixed" from the diff alone**:

- **Fixed** — the repro no longer reproduces / the gap is closed. Reply with the
  verdict + fresh evidence, and **resolve** the thread.
- **Moot** — the code it referenced is gone or rewritten so the concern no longer
  applies. Reply explaining why, and **resolve**.
- **Still open** — not addressed, or only partially. Reply with what remains (and
  why), and **leave the thread open** for the author.

Write the reply body (verdict + evidence) to a file, then:
```bash
# verified fixed / moot → reply + resolve
bash ${CLAUDE_SKILL_DIR}/scripts/resolve-thread.sh --comment-id <id> --thread-id <tid> --body-file <f> --resolve
# still open → reply only, leave the thread open
bash ${CLAUDE_SKILL_DIR}/scripts/resolve-thread.sh --comment-id <id> --thread-id <tid> --body-file <f>
```
This is the **only** place review-pr writes to a thread it opened. The verdict is
yours (gated on the re-verification above); the script only posts the reply and,
when told, resolves. Still read-only on code — you re-test the fix, you never make it.

### 6. Render & hand off — by `role`
First render the **Coverage** diagnostics block from the scout's decision, then post.
```bash
# Reconcile floor → scout → executed into $COVERAGE_FILE (reads $SELECT_FILE +
# $SCOUT_FILE + $TESTS_FILE). No-op when review.show_diagnostics=false or the scout
# was skipped-with-nothing-to-say; safe to always run.
bash ${CLAUDE_SKILL_DIR}/scripts/render-coverage.sh

# role=self (my work — pre-PR diff or my own PR): render, NEVER post
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --self
# role=peer (someone else's PR): auto-submit one COMMENT review by default
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --peer --submit   # post one COMMENT review (DEFAULT)
bash ${CLAUDE_SKILL_DIR}/scripts/post-review.sh --peer            # --dry-run only: render, post nothing
```
`post-review.sh` appends `$COVERAGE_FILE` to the review body by default (a collapsible
`<details>` footer: what ran, what was skipped and why, per-lens tier, tests) — so
every review, local or posted, carries the reviewer's coverage decision once. The
script validates labels (confirmed⇒evidence, hypothesis⇒verify) and demotes off-diff
anchors to the summary in both roles. (Pass the `.role` from step 1; a local diff is
forced to `--self` regardless.)

- **`role=self` (my work):** always renders and **posts nothing** (it refuses
  `--submit`). **Hand the findings back** — summarize the Confirmed findings and
  worthwhile Hypotheses so the LLM (`/zeus:create-pr` or the user) fixes them in its
  normal flow. review-pr does not fix, loop, or re-review.
- **`role=peer` (someone else's PR): auto-submit by default.** This skill only runs
  when the user explicitly asks for a review, so posting the result IS the request —
  submit one `COMMENT` review without a confirmation round-trip. `post-review.sh`
  **drops any finding whose id is already posted** (an earlier round — those are
  handled in-thread in step 5b), so re-running never duplicates; if nothing new
  remains it posts nothing rather than an empty review. Only skip the post when the
  user asked for a `--dry-run`/preview. Every comment must **state plainly what it is** — a
  reproduced **Confirmed** finding (carries evidence) vs. an unproven **Hypothesis**
  (carries a verify step) vs. a **Nit** — and pose its question about intent, so the
  **author decides what to fix**. Event is always `COMMENT`; never
  auto-`REQUEST_CHANGES` (that verdict is the author's, not the reviewer's).
  **Clean pass:** on a genuine first-round clean pass (zero findings — not the
  re-review case where everything was already posted), `post-review.sh` posts
  nothing (it skips an empty review). Leaving zero trace on a review the user
  explicitly asked for is a bad signal, so post one brief `COMMENT` review
  yourself (`gh pr review --comment`) stating it passed and naming what you
  checked — append the rendered `$COVERAGE_FILE` block, which *is* the
  what-ran/what-skipped record, so a clean pass still shows its coverage. This is
  the ONE case where you post outside `post-review.sh`; the
  re-review "already posted" skip stays silent (its findings live in-thread).

### 6b. Reply in the Slack thread (Slack-triggered reviews only)
Run this **only** when `slack-thread.sh get` returns a non-empty record (this review
was kicked off from a Slack link this session, or a prior round seeded it) and
`role=peer`. Otherwise skip — a normal review posts nothing to Slack.
```bash
coords=$(bash ${CLAUDE_SKILL_DIR}/scripts/slack-thread.sh get)   # {} → skip; else {channel, thread_ts, ...}
```
Post a **simple, informational** reply yourself via
`slack_send_message(channel_id=<coords.channel>, thread_ts=<coords.thread_ts>,
message=<text>)`. It is a *completion notice*, not a report — the findings live in
the PR comments; do **not** restate them here. It **must ping the requester** by
opening with `<@<coords.requester>>` (the Slack id saved in step 1). Keep it to one
line, naming only the high-level outcome + PR link:
- **First review:** *"<@U123> Review done — left N comments on <pr>. Details in the PR."*
  A clean pass: *"<@U123> Reviewed <pr> — no blocking issues. ✅"*
- **Re-review:** *"<@U123> Re-reviewed <pr> — N resolved, M still open, K new. See the PR."*

Always reply, even on a clean pass — closing the loop is the point. A bare count is
fine (it's informational); the per-finding detail stays on the PR. If
`coords.requester` is somehow empty, still post (the threaded reply notifies
participants) and note the missing ping. This threaded reply is review-pr's **only**
write to Slack, and it never broadcasts (`reply_broadcast` stays false). Still
read-only on code and on the author's PR body (we never write the journey marker —
that's the author's request-review concern, the inverse role).

### 7. Cleanup
Remove the per-run state and any throwaway verify resources (`cleanup_run_state`).
Leave the worktree (reused on a re-review of the same PR) unless asked to remove it.
`$SLACK_FILE` and `$REVIEWED_HEAD_FILE` are intentionally preserved (not in
`cleanup_run_state`) so a same-session re-review replies in the original thread and
scopes its diff to the delta since the last review; both die with the worktree.
(`post-review.sh` writes `$REVIEWED_HEAD_FILE` at the end of a completed review.)

## Scope discipline
- **Diagnose only — no edits/commits/pushes, in either mode.** Local mode reviews the
  author's own diff but still never fixes it: it renders findings and hands them back.
  Fixing belongs to the caller (`/zeus:create-pr` or the user).
- Don't report pre-existing issues (true on the base branch) as this change's findings.
- Default review event is `COMMENT`; never auto-`REQUEST_CHANGES`.
- A clean pass (no findings) is a valid result — say so; don't manufacture noise.
- **One pass per invocation — never loop.** Each manual run addresses the existing
  comments (step 5b) and posts any new findings, then stops. The user re-runs the
  skill for the next round; the skill never schedules or re-triggers its own
  re-review. A re-verified-fixed thread is closed with evidence, not on faith.
