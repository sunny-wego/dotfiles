#!/usr/bin/env bash
# Stop hook: when a turn ends with committed work on a feature branch that has NO
# open PR yet, nudge the agent to run /zeus:create-pr. This composes an implementer
# that doesn't open PRs itself (e.g. a built-in /goal driving from a /zeus:propose
# artifact) into the Zeus pipeline: create-pr seeds the PR from the proposal's
# journey `.issue`, runs the pre-PR review backstop (/zeus:review-pr), and opens a
# reviewer-ready PR — after which the post-push hook nudges /zeus:address-pr.
#
# State-driven, not command-driven (mirrors stop-autolink.sh / post-push-review.sh):
# the decision comes from git/PR STATE, so it composes with ANY implementer, not just
# one that announces itself. A **non-blocking** nudge (additionalContext) — the turn
# still ends; the agent acts on it when ready (so a fire before the implementer is
# truly done is harmless). Best-effort: every path exits 0; a Stop hook must never
# wedge the session. Install/auto-load: hooks/INSTALL.md.
set +e
cat >/dev/null 2>&1   # drain the hook-input JSON; the decision is from state, not it

[ "${ZEUS_SKIP_PR_SUGGEST:-}" = "1" ] && exit 0

head=$(git rev-parse HEAD 2>/dev/null) || exit 0

# Session-isolation gate — only act from a LINKED worktree (the implementer's
# isolated worktree). In the shared/primary checkout a concurrent agent can swap the
# branch underneath the session, making branch->state untrustworthy. (Matches
# stop-autolink.sh / post-push-review.sh.)
abs_gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
case "$abs_gitdir" in
  */worktrees/*) : ;;   # linked worktree — trustworthy
  *) exit 0 ;;          # primary/shared checkout — don't nudge
esac

# One nudge per head SHA (cheapest gate after the worktree check).
gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
marker="$gitdir/create-pr/pr-suggested-$head"
[ -f "$marker" ] && exit 0

# On a feature branch (never the repo default — resolved, never hard-coded main/master).
branch=$(git branch --show-current 2>/dev/null) || exit 0
[ -n "$branch" ] || exit 0
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../lib/repo.sh
source "$HOOK_DIR/../../../lib/repo.sh" 2>/dev/null || exit 0
default=$(repo_default_branch 2>/dev/null)
[ -n "$default" ] && [ "$branch" = "$default" ] && exit 0

# Clean tree = a stopping point — don't nudge mid-edit.
git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null || exit 0

# Something to PR: HEAD is ahead of the base. (origin/<default> if present, else <default>.)
base_ref=$(default_base_ref 2>/dev/null); [ -n "$base_ref" ] || base_ref="$default"
ahead=$(git rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 0)
[ "${ahead:-0}" -gt 0 ] || exit 0

# No open PR yet (the one network call — gated behind every cheap check above, so it
# runs ~once per head SHA). Use `gh pr list` (not `gh pr view`): it exits 0 with `[]`
# when the branch has no PR, so "no PR" (our nudge case) is cleanly distinguishable
# from a gh/auth/network failure (which `|| exit 0` treats as a safe no-op). If an
# open PR already exists, this isn't our case — the post-push hook handles address-pr.
prs=$(gh pr list --head "$branch" --state open --json number 2>/dev/null) || exit 0
[ "$(printf '%s' "$prs" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ] && exit 0

# Committed + on a feature branch + no PR + unnudged → suggest create-pr, once.
mkdir -p "$gitdir/create-pr" 2>/dev/null
: > "$marker" 2>/dev/null
reason="Committed work on feature branch '$branch' ($ahead commit(s) ahead of $base_ref, clean tree) with no open PR. When the implementation is complete, run the /zeus:create-pr skill — it seeds the PR from the linked issue, runs the pre-PR review backstop (/zeus:review-pr), and opens a reviewer-ready PR. (Export ZEUS_SKIP_PR_SUGGEST=1 to silence.)"
jq -nc --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $r}}'
exit 0
