---
name: address-pr
description: >-
  Resolve PR blockers by fixing failing checks, merge conflicts, outdated
  branches, and review feedback until the PR is settled. Use when a PR cannot be
  merged due to CI failures, Github Actions errors, merge conflicts, or when a
  reviewer has left actionable feedback that needs addressing. Triggers on: "fix
  pr", "address feedback", "fix failing checks", "resolve merge conflicts",
  "fix CI", "address review comments".
license: MIT
compatibility: Requires git, gh (GitHub CLI) authenticated. SonarQube MCP and Vercel MCP optional.
metadata:
  author: sunnywong
  version: "4.1"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Read Edit Grep LSP AskUserQuestion ScheduleWakeup Skill Task Agent mcp__sonarqube__* mcp__plugin_vercel_vercel__* mcp__plugin_slack_slack__slack_send_message mcp__plugin_slack_slack__slack_send_message_draft mcp__plugin_slack_slack__slack_search_users
---

# Address PR

Drive a pull request to a **settled** state and keep it settled until it merges or closes.
All state lives in script-owned probes under the per-worktree `.git/address-pr/` directory (created by
`scripts/lib.sh`); prefer the
scripts in `scripts/` over hand-rolled `gh`/`git` — they dedupe tool output and own the commit/push/flush
ordering you'd otherwise have to reproduce by hand.

## Modes

| Invocation              | Intent                                                                 | Section |
|-------------------------|------------------------------------------------------------------------|---------|
| `/zeus:address-pr`           | Drive to settled, then watch until merged/closed                       | Drive → Report → Watch |
| `/zeus:address-pr <handler>` | Run one handler standalone (`reviews`, `sonarqube`, `ci-check`, `vercel`, `merge-conflicts`); `reviews <author>` narrows scope to one author | Standalone handler mode |
| `/zeus:address-pr monitor`   | One post-settle watch probe, re-schedule only if the probe says to     | Watch |
| `/zeus:address-pr ready`     | Read-only: print the settled verdict and exit, touching no state       | Ready |
| `/zeus:address-pr re-review` | Re-ping the reviewer (threaded) if the head advanced since their last review — scoped to the configured auto-review reviewer | Re-review |

## The goal: a settled PR

A PR is **settled** exactly when `scripts/ready-for-review.sh` exits 0:

- mergeable — no conflicts, not behind base
- every required check green
- no unresolved review threads, inline comments, or conversation comments
- not a draft

This script is the single source of truth for "done". Drive toward it; never declare a PR ready without it.

## Operations

Apply whichever operations' preconditions currently hold. When several apply in one pass, run them in this
priority order — it minimizes rework: fix the merge state before re-running checks, and address reviews
last so replies cite the final pushed SHA. Read `references/handler-contract.md` once before the first
handler, then read only the handler files you actually need.

| Pri | Operation           | Precondition (from the latest probe)                          | Handler / script |
|-----|---------------------|---------------------------------------------------------------|------------------|
| 1   | Resolve merge state | `mergeable == "CONFLICTING"` or `behind_base == true`         | `handlers/merge-conflicts.md` |
| 2   | Fix SonarQube       | a check named `SonarQube`/`sonarcloud` failed                 | `handlers/sonarqube.md` |
| 3   | Fix CI check        | any other failed check (lint, test, build, scanner — any CI provider) | `handlers/ci-check.md` |
| 4   | Fix Vercel          | a `vercel`/`Preview` check failed (case-insensitive)          | `handlers/vercel.md` |
| 5   | Address reviews     | any unresolved thread/comment, **any author** — every pass    | `handlers/reviews.md` |
| —   | Publish             | local changes pending after the above                         | `scripts/commit-and-evaluate.sh` |

`wait-and-evaluate.sh` returns `.action` as a shortcut over these preconditions:
`fix` = run the check handlers it names, then reviews · `sweep` = checks are green, run reviews in **Sweep
mode** only · `wait` = nothing actionable yet, probe again · `report` = settled, leave the loop.

**Parallel diagnosis, serial application.** When the probe shows multiple actionable items (several
failed checks and/or unresolved review threads), spawn **read-only diagnosis subagents for all of them in
a single turn** — one per failed check (fetch logs, identify the root cause, propose the fix) and one per
review thread or per-author batch (analyze the comment against the code, draft the reply/fix plan).
Diagnosis is pure reading and dominates a busy pass's wall-clock, so fanning it out cuts the pass from
sum-of-diagnoses to slowest-diagnosis with an identical result. Then **apply** the fixes strictly in the
priority order above and publish only through `commit-and-evaluate.sh`, exactly as on a serial pass — the
ordering and the push-before-replies choreography are semantic and stay serial. Hard constraint: diagnosis
subagents MUST NOT mutate the worktree and MUST NOT append outcomes — only the handler application step
edits files and calls `state.sh append`, preserving the one-outcome-per-handler invariant.

## Invariants (hold on every path)

- Each handler appends **exactly one** outcome via `state.sh append`, or the final report under-counts.
- Never resolve a review thread without a reply or a real fix; threads never auto-resolve.
- Never let "out of scope" excuse a correctness, security, or stability regression the PR introduces.
  (Use Original Intent for scope *triage*, never to decline a real defect.)
- A live approval covering the current head is a **do-not-churn** signal: never push a non-blocking
  (nit/style/minor-improvement) change that would dismiss it. Real blockers — failed checks,
  `CHANGES_REQUESTED`, unresolved correctness threads, direct questions — still override and may
  legitimately supersede the approval. The signal (`pr-status.sh`'s `approved_at_head`) is
  author-agnostic and re-derived from GitHub each pass; no per-reviewer state is stored.
- Publish through `commit-and-evaluate.sh` only — it stages safely, commits/pushes, waits for GitHub to
  observe the pushed SHA, writes a fresh status snapshot, and flushes queued replies/resolves/👍 reactions
  *after* the push so each cites the new SHA and nothing lands before the code. Continue from the `DECISION`
  it returns; never reuse a pre-push status snapshot.
- Operate on GitHub / `gh api` as ground truth. The PR body is never a state store.

## Lifecycle (conceptual)

A full run is a **level-triggered reconciler**, not an event-driven state machine: each pass re-observes
the PR (GitHub is the real state) and acts to close the gap to `settled`. The stages below are a **mental
model**, not persisted state — there's nothing to resume, because every run (and re-run) just re-derives
status from the probe. The inner loop stays guard-based, adapting to whatever the latest probe shows.

```
SETUP ─▶ DRIVE ─(report/ready)─▶ SETTLED ─(PR open)─▶ WATCH
          │  ▲                                          │
          │  └───────────(restart: regression)──────────┘
   (cap / probe fail)                            (reschedule)↺
          ▼                                              │
      ESCALATE                        (stop: merged/closed)─▶ DONE
```

(A GitHub-rendered Mermaid version lives in `references/lifecycle.md`.)

| Stage | What happens | Next |
|-------|--------------|------|
| Setup | preflight, identify, fresh `init` | Drive |
| Drive | reconcile: probe → apply operations → publish | Settled; or Escalate at the iteration cap / probe failure |
| Settled | `ready-for-review.sh` exits 0; report + verdict | Watch (PR open) or Done (merged) |
| Watch | post-settle monitor; re-probe on a schedule | Drive (regression), Watch (reschedule), Done |
| Escalate | hit the 5-iteration cap or a probe failure — hand back to the human (AskUserQuestion) | terminal |
| Done | PR merged or closed | terminal |

## Setup & dispatch

Preflight runs on **every** invocation:

```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true   # deps: git, gh, jq; SonarQube/Vercel/Slack MCP optional
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo: under zsh, echo expands the escaped \n in .report and corrupts the JSON
```

On `.ok == false`, present each `.remediation[]` entry and offer to install; `preflight.sh --fix` installs
the `auto:true` entries (interactive steps like `gh auth login` are listed, never auto-run). Don't proceed
until `ok: true`.

### Isolate in a worktree first (mutating modes only)

A full run and a standalone `<handler>` edit files and push, so they must run in an **isolated git
worktree** for the PR — never in whatever checkout you launched from, or they'd clobber its branch.
`ensure-worktree.sh` makes that automatic and idempotent: it **reuses** a worktree already checked out on
the PR's head branch (wherever it lives) or **creates** one at `<repo>/.claude/worktrees/pr-<n>`
(fork-safe, via `gh pr checkout`). The key is derived from the PR alone, so the same worktree is re-found
across sessions and scheduled monitor wakes with no persisted state.

Run it **before** `setup.sh`. Pass the PR number when the invocation carries one (`/zeus:address-pr <n>` or a
PR URL); omit it to infer from the current branch:

```bash
# PR_REF = $ARGUMENTS when it is a number or PR URL; empty otherwise (infer from branch).
# 2>&1 capture: on success WT is clean JSON; on failure it holds the {"error":...} the script prints to stderr.
WT=$(bash ${CLAUDE_SKILL_DIR}/scripts/ensure-worktree.sh ${PR_REF:-} 2>&1) || { echo "$WT" >&2; exit 1; }
echo "$WT" | jq '{path, created, reused, already_inside}'
```

A script can prepare a worktree but **cannot move your session into it**. So:

- `already_inside == false` → call the **EnterWorktree** tool with `path` set to `$(echo "$WT" | jq -r .path)`,
  then continue from inside it (all later steps, including `setup.sh`, run there).
- `already_inside == true` → you're already isolated; continue.
- non-zero exit → surface `WT.error` (e.g. the branch is checked out elsewhere) and stop; do **not**
  mutate the launch checkout.

The read-only `ready` and `re-review` probes skip this entirely — they touch no files and are
cross-worktree safe. For the `monitor` path, see **Watch**.

Then dispatch by mode. **`ready`, `monitor`, and `re-review` own their own identify step and don't touch
run state**, so jump straight to **Ready** / **Watch** / **Re-review**. For a full run or `<handler>`,
establish state:

```bash
# setup.sh runs the fixed sequence (identify + checkout → fresh state init → capture Original Intent)
# and returns one object, so the ordering can't drift and capture can't be skipped.
SETUP=$(bash ${CLAUDE_SKILL_DIR}/scripts/setup.sh)
PR_NUMBER=$(echo "$SETUP" | jq -r .pr); OWNER=$(echo "$SETUP" | jq -r .owner); REPO=$(echo "$SETUP" | jq -r .repo)
```

For `<handler>`, jump to **Standalone handler mode** (state is now initialized for its `append`). Otherwise
continue to **Drive**.

## Drive to settled

Establish the pre-loop merge state once, then loop until the probe returns `report`:

```bash
STATUS_FILE="$(git rev-parse --absolute-git-dir)/address-pr/status.json"  # matches scripts/lib.sh STATE_DIR
bash ${CLAUDE_SKILL_DIR}/scripts/pr-status.sh --pr "$PR_NUMBER" > "$STATUS_FILE"
```

Each pass:

1. `ITERATION=$(bash ${CLAUDE_SKILL_DIR}/scripts/state.sh bump-iteration)`, then read the probe:
   `DECISION=$(bash ${CLAUDE_SKILL_DIR}/scripts/wait-and-evaluate.sh --pr "$PR_NUMBER" -1)`.
2. Apply every operation whose precondition holds, in priority order (the table above). For `sweep`, run
   only `reviews` in Sweep mode (which also fixes clear nitpicks — see the handler-contract Sweep section).
   Each handler appends exactly one outcome.
3. Publish and re-evaluate:
   ```bash
   DECISION=$(bash ${CLAUDE_SKILL_DIR}/scripts/commit-and-evaluate.sh \
     "fix: <what changed> (address-pr iteration N)" "$ITERATION" 5)
   ```
   Continue the loop from the returned `DECISION`. Stop when it is `report`.

The loop is **bounded**: the third arg to `commit-and-evaluate.sh` (`5`) is the iteration cap, so the
probe returns `report` even if blockers remain — it never spins forever. On `report`, go to **Report**;
the readiness verdict there (not the loop's reason) decides whether the PR is settled or needs escalation.

Make commit messages specific. When Original Intent is captured, lean on its Purpose/Scope to avoid generic
messages like `fix: address review feedback` — e.g. `fix(scanner): address retry dedupe review feedback
(address-pr iteration 2)`.

**Original Intent** (Purpose / Scope / Non-goals), when present in the PR body, is *scope context only* —
usable for merge-conflict relevance checks, scope-sensitive review triage, specific commit messages, and
report wording. It is never operational truth; fall back silently if absent or malformed.

## Report

```bash
# Prose summary, then the deterministic verdict.
bash ${CLAUDE_SKILL_DIR}/scripts/report.sh
READY=$(bash ${CLAUDE_SKILL_DIR}/scripts/ready-for-review.sh --pr "$PR_NUMBER" --repo "$OWNER/$REPO")
```

`report.sh` aggregates handler outcomes and emits the stale-review caveat itself when the last fetch saw
GraphQL lag REST (no manual rule to remember; see `report.sh`'s comment for the detail); include
a one-line Original-Intent note if captured.

`READY` is the settled-arbiter; it decides what's next deterministically (not the loop's exit reason):

- `READY.ready == true` (exit 0, zero blockers) — the PR is settled. **Before** proceeding to **Watch**,
  close the notification gap. The verdict is a pure function of GitHub state; "has the reviewer been
  pinged?" belongs to `request-review` (it owns the ping policy and the per-SHA stamp) — and skills call
  skills **by name, never each other's files**, so don't probe its scripts: run the Request-review
  hand-off below unconditionally. The callee answers the gap question itself — its envelope comes back
  `should_send:false` with `skip_reason: already_pinged_at_<sha>` (or a disabled repo) when no gap
  exists, so the hand-off is a safe no-op on an already-pinged SHA. A settled run is not complete until
  the hand-off has run and its envelope was honored. `READY.warnings` are informational. Then
  proceed to **Watch** (or stop if merged).
- `READY.ready == false` (exit 1) — the loop reached `report` with blockers still present
  (`READY.blockers`): hand those blockers to the user via AskUserQuestion rather than re-looping.
  **Exception — a `ci_pending`-only blocker set is transient, not a real blocker:** a still-running
  check means "not settled yet," not "stuck." Do NOT escalate or ping; re-probe with one more
  `wait-and-evaluate.sh` cycle (bounded by the iteration cap) and re-read the verdict once checks
  finish. Only escalate a `ci_pending` blocker if the iteration cap is hit with it still pending.

**Request review (delegated — REQUIRED when auto-ping is enabled).** Reviewer notification lives in the
**`request-review`** skill, the *notifier*. address-pr is the *arbiter*: it produces the readiness verdict
and hands it over — it does not own channels, handles, dedup, or thread state, and it does **not** call
request-review's scripts by path. The hand-off is a **skill invocation by name** carrying data:

1. Produce the verdict: `READY=$(bash ${CLAUDE_SKILL_DIR}/scripts/ready-for-review.sh --pr "$PR_NUMBER" --repo "$OWNER/$REPO")`.
2. **Invoke the `request-review` skill** (Skill tool, `ping` mode), passing as input: the verdict JSON
   and — when `rehydrate.sh` returned a non-null `slack_record` — that record, so request-review can
   re-seed its own thread state (fill-gaps-only) before deciding. Everything else (per-repo policy,
   channel, reviewer, envelope formatting, per-SHA dedup) happens inside the callee per its SKILL.md.
3. Honor the returned envelope: `should_send:false` → done (no gap existed). `should_send:true` → the
   request-review flow sends per its mode — for **`send`**, immediately (the per-repo opt-in in its
   `auto-ping.json` IS the authorization; do not ask the user first) — and stamps its own thread state.

Sending the ping is a **mandatory closing step of a settled run**. Do **not** declare the PR done, and do
**not** merely *offer* to ping ("want me to request review?"), while the envelope says `should_send:true`:
just send it. **An existing approval (human or bot) is NOT a skip reason** — the ping is per-SHA and
author-agnostic, so "it's already approved" / "CodeRabbit already reviewed" does not close the gap. Do not
reason your way out of the hand-off: run it unconditionally and let the returned `should_send` decide
(only the callee's own `skip_reason`, e.g. `already_pinged_at_<sha>` or a disabled repo, skips it). The autonomous ping mentions **only** the reviewer configured in request-review's policy
(typically the AI reviewer) — it never auto-cc's the PR's human reviewers, so an unattended background run
can't cold-ping a person; ask for the cc variant only when a human explicitly requests it. Full
mode/dedup/thread detail lives in `request-review`'s SKILL + its `references/reviewer-ping.md`. If the
`request-review` skill isn't available, address-pr simply doesn't notify — drive/report/watch are unchanged.

After the request-review flow completes a send (the agent has the channel id, `ts`, and target from it),
persist the Slack thread into the PR body's hidden journey marker — the marker is **this** skill's tool —
so a fresh session in any worktree re-threads the *same* message instead of cold-starting a new ping (it
can't be re-derived from GitHub):

```bash
jq -nc --arg c "$CHANNEL_ID" --arg t "$TS" --arg r "$TARGET" \
  '{slack: {channel: $c, thread_ts: $t, target: $r}}' \
  | bash ${CLAUDE_SKILL_DIR}/scripts/journey-marker.sh write "$PR_NUMBER" "$OWNER/$REPO"
```

The reverse (read) is automatic: `setup.sh` runs `rehydrate.sh`, which reconstructs `journey.json` and the
Slack thread from this marker at the start of every run — so picking a PR up from scratch needs no manual
step. See `references/journey-schema.md` → "Picking a PR up from scratch".

## Watch (stay settled)

A settled PR can regress — a new push, a fresh review, the base moving on. Run one probe and dispatch it:

```bash
MONITOR_PROBE=$(bash ${CLAUDE_SKILL_DIR}/scripts/monitor-step.sh --pr "$PR_NUMBER" --repo "$OWNER/$REPO")
MONITOR_DECISION=$(echo "$MONITOR_PROBE" | bash ${CLAUDE_SKILL_DIR}/scripts/dispatch-monitor.sh -)
```

For `/zeus:address-pr monitor` invoked directly, first **isolate** (the `process` path edits files and pushes):
run `ensure-worktree.sh` — passing the PR number if the wake carries one, else inferring from the current
branch — and `EnterWorktree` to its `.path` when `already_inside` is false (see **Setup → Isolate in a
worktree**). Then reconstruct `OWNER`/`REPO`/`PR_NUMBER` with `identify-pr.sh --checkout` and run the same
two commands. Read `MONITOR_DECISION.action`:

- `stop` — PR merged or closed; schedule nothing.
- `restart` — regression detected; re-enter the full skill via `.restart_prompt` (defaults to
  `/zeus:address-pr`). The re-entry re-observes the changed HEAD and drives from scratch.
- `schedule` — `ScheduleWakeup(delaySeconds: .next_delay, prompt: .schedule_prompt, reason: .schedule_reason)`.
- *anything else* (the `process` path) — `.item_count` is the number of actionable items (read THAT, not
  `.filtered_path | length`). `.filtered_path` is a **file path string** pointing at the JSON payload
  (`{threads, reviews, inline_comments, conversation_comments}`) — read the file, don't measure the path.
  When `.item_count > 0`: read `handlers/reviews.md`, address the payload, publish, then ack by running the
  probe's `.completion_command` with `--acked-ids` appended, e.g.
  `bash ${CLAUDE_SKILL_DIR}/scripts/monitor-step.sh complete-process <ISO-watermark> --acked-ids "<ids>"`
  (the `complete-process` wrapper forwards to this; required whenever `item_count > 0` — pass
  `--acked-ids ""` to defer all to the next probe). Then `ScheduleWakeup` with the schedule fields the
  completion response returns; `pending_ids` stay visible to the next probe.

On each watch pass, also run the **Re-review** check below — that's what re-pings the configured reviewer when you push
changes after her first review, without you having to ask.

Watch mode uses GitHub / `gh api` as operational truth; it never treats the PR body as a state store.

## Re-review (delegated to `request-review`)

When you push changes after the first review, address-pr re-pings the reviewer in-thread — by handing the
fresh verdict to `request-review`, which owns the scoping, per-SHA dedup, and thread continuity. Runs on
each **Watch** pass and on demand via `/zeus:address-pr re-review`. Only fires for repos+reviewers configured in
`request-review`'s policy; a no-op otherwise.

Same shape as the initial hand-off — produce the verdict
(`bash ${CLAUDE_SKILL_DIR}/scripts/ready-for-review.sh --pr "$PR_NUMBER" --repo "$OWNER/$REPO"`), then **invoke the
`request-review` skill** (`re-review` mode) with it. The callee scopes, dedups per SHA, posts the
**threaded** reply, and re-stamps its own thread state; its envelope's skip reasons and the full contract
live in its `references/reviewer-ping.md`. For `/zeus:address-pr re-review`, identify the PR first
(`identify-pr.sh`, no checkout) and run the same.

## Ready (read-only probe)

`/zeus:address-pr ready [<pr_number>]` — skip the loop and watch; print the verdict and exit.

```bash
PR_JSON=$(bash ${CLAUDE_SKILL_DIR}/scripts/identify-pr.sh)
PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number'); OWNER=$(echo "$PR_JSON" | jq -r '.owner')
REPO=$(echo "$PR_JSON" | jq -r '.repo')
bash ${CLAUDE_SKILL_DIR}/scripts/ready-for-review.sh --pr "$PR_NUMBER" --repo "$OWNER/$REPO" --plain
```

Exit `0` ready / `1` not ready (`.blockers[]`) / `2` probe failure (details on stderr). Writes nothing,
mutates no state — safe from any worktree where `gh` is authenticated. Use it before pinging humans, to
verify another agent's "it's settled" claim, or as a cross-worktree health check. Pipe the verdict into
the `request-review` skill (invoked by name) for a send-ready envelope (when that skill is installed).

## Standalone handler mode

`/zeus:address-pr <handler>` — read `references/handler-contract.md`, then the named handler file, and run its
**Standalone mode** section. Skip the drive loop, report, and watch. For `reviews`, an optional author
substring narrows scope (e.g. `/zeus:address-pr reviews coderabbitai`).
