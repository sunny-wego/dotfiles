---
name: implement
description: >-
  Take a GitHub issue and implement it into working code on the current branch,
  then hand off to /zeus:create-pr. Reads the issue body as the spec (acceptance
  criteria, MUST/MUST NOT invariants, Verification block), writes the code,
  self-verifies against the issue's own contract, and leaves the branch ready for
  a PR. Works especially well on issues authored by /zeus:propose or bug-report /
  remediation issues from /zeus:investigate. Use whenever the user wants to build,
  code, or implement an issue/ticket/RFC, "do #N", "work on the issue", "turn this
  issue into code", "start implementing", or "ship the proposal" — even if they
  don't name a number (it resolves the active issue from journey.json). It runs
  autonomously, pausing only for major decisions. This is the pre-PR step that sits
  between /zeus:propose|/zeus:investigate and /zeus:create-pr; it is NOT the post-PR fix loop —
  that's /zeus:address-pr.
license: MIT
compatibility: Requires git and gh (GitHub CLI) installed and authenticated; jq. Assumes the caller already set up the worktree/branch.
metadata:
  author: sunnywong
  version: "0.1"
allowed-tools: Bash Read Write Edit Glob Grep AskUserQuestion Task Agent Skill
---

# Implement

Turn an issue into working code on the current branch, then hand the branch to `/zeus:create-pr`. The issue
body **is the spec** — when it came from `/zeus:propose` it's an agent-ready contract (acceptance criteria,
binary MUST / MUST NOT invariants, a `## Verification` block); when it's a remediation bug from
`/zeus:investigate` it carries the confirmed root cause and the evidence the fix must satisfy. Your job is to
make the code satisfy that contract and prove it before handing off.

**Boundary (keep it sharp):** this is the *pre-PR Work layer*. It produces a branch of code that
satisfies an issue. `/zeus:address-pr` is the *post-PR fix loop* (failing checks, conflicts, review
comments). Don't open or fix PRs here — implement, verify, hand off.

**Workspace is the caller's.** The coding agent already put you in a worktree on a feature branch. This
skill **never creates worktrees or branches** and does not depend on `/wgd`. It only refuses to write
into the wrong place (step 1).

**Autonomy.** Run end-to-end without check-ins. Pause for the user **only** on a *major* decision —
genuinely ambiguous or self-contradictory requirements, an architectural fork the issue doesn't settle,
or a destructive / irreversible action (data migration, deleting a public API, force-push). Routine
choices the issue implies, you make — and note them at handoff. The bar: "would a reasonable teammate
ship this without asking?" If yes, ship it.

## Workflow

### 0. Preflight

```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo (echo corrupts the JSON under zsh)
```

On `.ok == false`, surface the `.remediation[]` fixes and re-check with `preflight.sh --fix`; proceed once
`ok: true`. Full flow: **`zeus/lib/PREFLIGHT.md`**.

### 1. Precondition guard — am I somewhere safe to write?

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/precondition.sh
```

`ok:false` (detached HEAD, or the current branch is the repo default) ⇒ **stop** and tell the user the
workspace isn't ready — setting up the worktree/branch is theirs to do, not this skill's. Warnings (a
dirty worktree) are surfaced, not blocking: confirm the existing changes belong to this work before
adding to them.

### 2. Resolve the target issue

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/resolve-issue.sh "$ARG" [--repo R]
```

Resolution order is strongest-signal-first: an explicit `#N`/URL the user named (`source:"arg"`) → `journey.json .issue`
(`source:"journey"` — recorded by `/zeus:propose` or `/zeus:investigate` in this worktree) → none. **Trust
differs by source.** An explicit `#N` (or an issue you created/named in *this* session) is acted on directly.
A `source:"journey"` issue is the per-worktree handoff pointer, which can outlive the task that set it (pinned
while on `main`, then reused for unrelated work in the same checkout) — so **confirm it before writing code**:
*"Implement **#N '<title>'** (recorded in this worktree)?"*. On `determined:false` with `source:"none"`, **ask the
user which issue** (don't guess); in a non-interactive run an unconfirmable journey target is refused, not assumed.
The output's `body` is the spec; `labels`/`author` tell you the genre — a `/zeus:propose` decision doc vs an
`investigation` / `remediation` bug — so you read it with the right lens.

### 3. Read the contract

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-contract.sh <body-file>
```

This pulls out the `## Verification` steps, the MUST / MUST NOT invariants, and the acceptance criteria.
Treat it as an **aid, not a substitute** — read the full body for intent. If `has_contract:false` (a thin
ticket with no explicit criteria), infer the acceptance bar from the prose, state it back in one line,
and proceed; that inferred bar is what you'll verify against in step 5.

### 4. Implement

Write the code to satisfy the contract. Principles that keep this honest:

- **Orchestrate, don't reinvent.** Pull current API/config docs via `/find-docs` rather than guessing
  from memory; lean on the installed framework skills for idiom. To *run or observe* the app, invoke
  `/verify` or `/run` — don't hand-roll a launch.
- **Honor the invariants as binary rules.** A MUST / MUST NOT is a hard constraint, not a preference. If
  satisfying one forces a design choice the issue didn't anticipate, that's a *major* decision — pause.
- **Match the surrounding code.** Read neighbors first; mirror their naming, structure, and test style.
  Prefer the project's existing libraries and patterns over introducing new ones.
- **Commit as you go**, in logical chunks, with messages that reference the issue (`… (#N)`). Small,
  reviewable commits make the eventual PR diff legible.

### 5. Self-verify against the issue's own contract — the gate

This is the high-value step and the mirror of `/zeus:propose`'s reader test: there, a fresh reader checks the
*document* is sound; here, you check the *code* satisfies what the issue promised. Don't skip it because
"it looks done".

1. **Run every `## Verification` step.** Execute the listed commands/tests/queries verbatim (use
   `/verify` or `/run` for app-level behavior). Capture the real output — it becomes the PR's test
   evidence in the next step.
2. **Check each invariant.** For every MUST / MUST NOT, point to the code or test that enforces it. A
   MUST with nothing demonstrating it is an unmet contract, not a pass.
3. **Check acceptance criteria / Closes-when.** The condition the issue says closes it must actually hold.
4. **Loop on failure.** Fix → re-run → re-check, up to a few rounds. If a step *can't* pass for a reason
   the issue got wrong (a contradictory requirement, an impossible assertion), that's a *major* decision —
   stop and surface it with the evidence, rather than quietly weakening the test to make it green.

Full procedure, including how to package the captured output as PR test evidence: `references/self-verify.md`.

### 5.5 Review the diff before handoff

Self-verify (step 5) proves the code does what the *issue* promised; this step catches
bugs in *how* it's written — the correctness, concurrency, resilience, migration,
API-contract, and security problems a reviewer would flag — **before** the PR is
public, so the PR goes out clean instead of accumulating review rounds.

1. **Make sure the work is committed** (the review runs against a SHA).
2. **Invoke `/zeus:review-pr` by name** (the skill, never its scripts — family
   doctrine). No flag needed: review-pr auto-detects, and since you're pre-PR it
   reviews the **local working diff**, renders findings, and **hands them back**. If
   `/zeus:review-pr` isn't installed, skip this step and continue to handoff (same
   graceful fallback as step 6's create-pr check).
3. **Act on the findings as normal implement work.** Fix the Confirmed findings (and
   any Hypothesis worth acting on) the same way you fix anything else in this skill —
   edit, commit. This is ordinary coding, not a special loop: there's no fixed round
   cap and review-pr never auto-applies anything. Re-running `/zeus:review-pr` on the
   new SHA to confirm a fix is a fine option, not a mandate. Carry any findings you
   deliberately leave unfixed (e.g. a Hypothesis you judged a non-issue) into the
   handoff report so they're visible, not silently dropped.
4. **Record the reviewed SHA** so `/zeus:create-pr`'s backstop doesn't re-review the
   same tree:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/journey.sh write-review "$(git rev-parse HEAD)"
   ```
   Write this **after** the last fix commit, so the watermark names the tree that was
   actually reviewed.

### 6. Hand off to /zeus:create-pr

Leave the branch in exactly the state `/zeus:create-pr` expects, then invoke it.

1. **Ensure the issue is on the handoff bus** so `/zeus:create-pr` seeds the PR body (Original Intent, Test
   Plan checklist, Design Decisions) and appends `Closes #N` from it:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/journey.sh write-issue "<number>" "<url>" "<title>"
   ```
   This is idempotent — if `/zeus:propose` already recorded it, you're writing the same fact. (You do **not**
   write `.pr` — that namespace belongs to `/zeus:create-pr`'s `post-pr.sh`.)
2. **Make sure everything is committed** (no stray changes the PR diff would miss).
3. **Invoke `/zeus:create-pr` by name** (the skill, never its scripts — family doctrine). Hand it the captured
   verification output as test evidence so the PR's Test Plan shows real, reviewer-checkable proof. If
   `/zeus:create-pr` isn't installed, say so and stop with the branch ready — don't open the PR by hand.

End by reporting: the issue implemented, what you decided autonomously (and why), the verification result,
the diff-review outcome (findings fixed, and any you deliberately left), and the PR (or the ready-to-PR branch).

## Constraints

- **The issue body is the contract.** Implement what it says; if reality diverges from it, surface the
  divergence — don't silently implement something else.
- **Verify before handoff, always.** A green self-verify with captured evidence is what makes the PR
  trustworthy and the `/zeus:create-pr → /zeus:address-pr → /zeus:request-review` chain meaningful.
- **Stay in your lane.** No worktree creation (caller's job), no PR fixing (`/zeus:address-pr`'s job), no
  reaching into sibling skills' files (invoke them by name, pass data). Acting on `/zeus:review-pr` findings
  is in-lane — it's your own pre-PR diff — but you call review-pr for the diagnosis; you don't re-implement its review.
- **Autonomy with a brake.** Default to acting; the brake is reserved for major, ambiguous, or
  irreversible decisions — and every autonomous call gets reported at handoff so nothing is a surprise.
