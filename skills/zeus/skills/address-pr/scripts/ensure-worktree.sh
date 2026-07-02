#!/usr/bin/env bash
# ensure-worktree.sh — guarantee address-pr operates in an isolated git worktree
# for a PR, reusing an existing one or creating it. This is what lets a run
# isolate itself instead of clobbering whatever branch the invoking checkout
# happens to be on.
#
# The worktree is keyed two ways, both derivable from the PR alone so the SAME
# worktree is found again across sessions (full run, standalone handler, and the
# scheduled monitor wakes) with no persisted state:
#   1. the PR's head branch (a worktree already checked out on it → reuse), and
#   2. the conventional path <main-worktree-root>/.claude/worktrees/pr-<n>.
#
# Hard limit: a script can PREPARE a worktree but cannot move the agent's session
# into it. The caller (SKILL.md → Setup) reads `.path` and, when `.already_inside`
# is false, calls the EnterWorktree tool with that path BEFORE running setup.sh.
#
# Fork-safe: creation delegates the actual branch checkout to `gh pr checkout`
# (same mechanism pr-for-branch.sh uses), so head refs on forks resolve correctly.
#
# Usage: ensure-worktree.sh [--pr <n>]   (a bare number is also accepted)
#   <pr_number>  the PR to isolate. Omitted → inferred from the current branch
#                (only works when already on the PR branch).
#
# Output JSON: { pr, branch, path, created, reused, already_inside }
# Exit: 0 on success; non-zero with {"error": ...} on stderr otherwise.

set -euo pipefail

# Shared worktree engine (side-effect-free: functions only, no state). Sourced
# directly — NOT via the skill's lib.sh, which would create state under the launch
# checkout before the agent has entered the worktree (this runs pre-isolation).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/worktree.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo '{"error": "not inside a git work tree"}' >&2
  exit 1
fi

# Resolve the PR + its head branch. With an explicit number we can run from any
# branch (e.g. the main checkout); without one we fall back to the current branch.
# Parsed inline (not via lib.sh's resolve_pr): this runs PRE-isolation, so sourcing
# lib.sh would create state under the launch checkout's .git. --pr or a bare number.
pr_ref=""
case "${1:-}" in
  --pr)   pr_ref="${2:-}" ;;
  --pr=*) pr_ref="${1#*=}" ;;
  --*)    ;;                       # other flags ignored (none expected here)
  *)      pr_ref="${1:-}" ;;
esac

if [ -n "$pr_ref" ]; then
  raw=$(gh pr view "$pr_ref" --json number,headRefName 2>/dev/null) || {
    echo "{\"error\": \"cannot view PR $pr_ref (gh auth / network / wrong repo?)\"}" >&2
    exit 1
  }
else
  raw=$(gh pr view --json number,headRefName 2>/dev/null) || {
    echo '{"error": "no PR for the current branch — pass a PR number: ensure-worktree.sh <n>"}' >&2
    exit 1
  }
fi
pr=$(echo "$raw" | jq -r '.number')
branch=$(echo "$raw" | jq -r '.headRefName')
target_ref="refs/heads/$branch"

# The conventional path is anchored at the main worktree root (shared engine), so it
# is identical regardless of which worktree we are invoked from.
wt_path="$(worktree_path_for pr "$pr")" || {
  echo '{"error": "could not locate the main worktree root"}' >&2
  exit 1
}

current_top=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

emit() { # emit <path> <created> <reused>
  local ai=false; [ "$current_top" = "$1" ] && ai=true
  jq -nc --argjson pr "$pr" --arg branch "$branch" --arg path "$1" \
    --argjson created "$2" --argjson reused "$3" --argjson ai "$ai" \
    '{pr:$pr, branch:$branch, path:$path, created:$created, reused:$reused, already_inside:$ai}'
}

# Reuse 1 (address-pr-specific): a registered worktree is already checked out on the
# PR head branch — reuse it wherever it lives, even off the conventional path.
existing="$(worktree_on_branch "$target_ref" || true)"
if [ -n "$existing" ]; then
  emit "$existing" false true
  exit 0
fi

# Reuse 2 / prune-leftover / create — the shared engine (reuse the conventional-path
# worktree if registered, else prune a stray dir, else `git worktree add --detach`
# and `gh pr checkout`). We reach here only when the branch is checked out nowhere,
# so there is no two-worktrees-one-branch conflict.
if ! worktree_ensure_local "$wt_path" "$pr"; then
  jq -nc --arg e "$WORKTREE_ERR" '{error:$e}' >&2
  exit 1
fi
if [ "$WORKTREE_RESULT" = created ]; then emit "$wt_path" true false
else emit "$wt_path" false true; fi
