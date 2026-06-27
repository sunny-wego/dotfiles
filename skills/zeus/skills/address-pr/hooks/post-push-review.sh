#!/usr/bin/env bash
# PostToolUse(Bash) hook: after a push LANDS on a branch with an open PR, nudge the
# agent to run /zeus:address-pr so review comments + checks get handled (not just
# CI). Wire it up via hooks/INSTALL.md.
#
# Why effect-based (not command-string matching):
#   Detecting "a push happened" by grepping the command string is fragile — it
#   misses pushes hidden inside wrapper scripts (e.g. create-pr's post-pr.sh runs
#   `git push` as a child process the matcher can't see) and false-matches
#   commands that merely MENTION "git push" (e.g. a grep). So hooks.json triggers
#   this script cheaply via `if` permission rules (git push / bash wrappers), but
#   the DECISION here is based on git/PR STATE, not the command:
#     - HEAD is actually on a remote branch  → a push really landed
#       (a --dry-run / rejected / failed push never advances the remote ref)
#     - an open PR exists for the branch      → address-pr has something to do
#   This mirrors investigate's stop-autolink.sh, which is likewise state-driven.
#
# Design constraints (same as the Stop guard):
#   - Best-effort: ANY unexpected condition exits 0. A PostToolUse hook must never
#     wedge the session.
#   - Cheap: local reads gate out the common cases (HEAD unpushed / already nudged)
#     before the single `gh` call, so the network hit happens ~once per pushed SHA.
#   - Bounded: nudges at most once per head SHA (marker).
#   - Session-isolation: only nudges from inside a linked git worktree, where the
#     current-branch->PR mapping can't be swapped out by a concurrent agent.
set +e

# Drain stdin (the hook input JSON); we intentionally do NOT parse the command —
# correctness comes from git/PR state below, not from the command string.
cat >/dev/null 2>&1

# Must be in a git repo.
head=$(git rev-parse HEAD 2>/dev/null) || exit 0

# Session-isolation gate — only nudge from inside a linked git worktree. In the
# shared primary checkout a concurrent agent can swap the branch underneath a
# session, making current-branch->PR untrustworthy. A linked worktree is 1:1 with
# its branch. A linked worktree's git-dir is `.../.git/worktrees/<name>`; the
# primary checkout's never is. (Matches investigate's stop-autolink.sh.)
abs_gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
case "$abs_gitdir" in
  */worktrees/*) : ;;   # linked worktree — trustworthy
  *) exit 0 ;;          # primary/shared checkout — don't nudge
esac

# Already nudged for this SHA? (cheapest gate — one nudge per head SHA.)
gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
marker_dir="$gitdir/address-pr"
marker="$marker_dir/push-nudged-$head"
[ -f "$marker" ] && exit 0

# Opt-out.
[ "${SKIP_REVIEW:-}" = "1" ] && exit 0

# Trunk pushes aren't PR work.
branch=$(git branch --show-current 2>/dev/null)
case "$branch" in main|master|"") exit 0 ;; esac

# EFFECT CHECK #1 (local, authoritative): did a push actually land? HEAD is on a
# remote-tracking branch only after a real push advances it — direct `git push`,
# a wrapper script's inner push, or `git push -u` all qualify; --dry-run / failed
# / rejected pushes do not. This is the signal the command string can't give us.
git branch -r --contains "$head" 2>/dev/null | grep -q . || exit 0

# EFFECT CHECK #2 (network, only reached once HEAD is pushed & unnudged): is there
# an open PR for this branch? Without one, address-pr has nothing to address.
pr=$(gh pr view --json number,state --jq 'select(.state=="OPEN").number' 2>/dev/null) || exit 0
[ -n "$pr" ] || exit 0

# Pushed + open PR + unnudged → nudge exactly once for this SHA.
mkdir -p "$marker_dir" 2>/dev/null
: > "$marker" 2>/dev/null
reason="IMPORTANT: HEAD ${head:0:7} is pushed and PR #$pr is open. You MUST invoke the /zeus:address-pr skill now so review comments AND checks get handled. The ONLY exception: /zeus:address-pr is already actively running in this conversation turn (to prevent loops). Running 'gh pr checks --watch' alone is NOT a substitute — it only checks CI status, not review comments."
jq -nc --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $r}}'
exit 0
