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
# (same mechanism identify-pr.sh uses), so head refs on forks resolve correctly.
#
# Usage: ensure-worktree.sh [--pr <n>]   (a bare number is also accepted)
#   <pr_number>  the PR to isolate. Omitted → inferred from the current branch
#                (only works when already on the PR branch).
#
# Output JSON: { pr, branch, path, created, reused, already_inside }
# Exit: 0 on success; non-zero with {"error": ...} on stderr otherwise.

set -euo pipefail

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

# The main worktree is always the first entry of `git worktree list`. Anchoring
# the conventional path there makes it identical regardless of which worktree we
# are invoked from. Read with a line loop so paths containing spaces survive.
main_root=""
while IFS= read -r line; do
  case "$line" in "worktree "*) main_root="${line#worktree }"; break ;; esac
done < <(git worktree list --porcelain)
wt_path="$main_root/.claude/worktrees/pr-$pr"

current_top=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

emit() { # emit <path> <created> <reused>
  local ai=false; [ "$current_top" = "$1" ] && ai=true
  jq -nc --argjson pr "$pr" --arg branch "$branch" --arg path "$1" \
    --argjson created "$2" --argjson reused "$3" --argjson ai "$ai" \
    '{pr:$pr, branch:$branch, path:$path, created:$created, reused:$reused, already_inside:$ai}'
}

# Reuse 1: a registered worktree is already checked out on the PR head branch.
existing=""; cur=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) cur="${line#worktree }" ;;
    "branch $target_ref") existing="$cur"; break ;;
  esac
done < <(git worktree list --porcelain)
if [ -n "$existing" ]; then
  emit "$existing" false true
  exit 0
fi

# Reuse 2: the conventional path is already a registered worktree (maybe parked
# on another branch) — re-point it at the PR branch and reuse.
is_registered=false
while IFS= read -r line; do
  case "$line" in "worktree $wt_path") is_registered=true; break ;; esac
done < <(git worktree list --porcelain)
if [ "$is_registered" = true ]; then
  if ! ( cd "$wt_path" && gh pr checkout "$pr" >/dev/null 2>&1 ); then
    echo "{\"error\": \"existing worktree $wt_path could not be switched to PR $pr (dirty? branch in use elsewhere?)\"}" >&2
    exit 1
  fi
  emit "$wt_path" false true
  exit 0
fi

# A leftover directory at the conventional path that git doesn't track → prune,
# else refuse rather than silently working in an unmanaged dir.
if [ -e "$wt_path" ]; then
  git worktree prune >/dev/null 2>&1 || true
  if [ -e "$wt_path" ]; then
    echo "{\"error\": \"$wt_path exists but is not a registered worktree; remove it or run 'git worktree prune'\"}" >&2
    exit 1
  fi
fi

# Create: an empty detached worktree, then let gh lay down the (possibly fork)
# branch with correct tracking. We only reach here when the branch is checked out
# nowhere, so there is no two-worktrees-one-branch conflict.
mkdir -p "$(dirname "$wt_path")"
if ! git worktree add --detach "$wt_path" >/dev/null 2>&1; then
  echo "{\"error\": \"git worktree add failed for $wt_path\"}" >&2
  exit 1
fi
if ! ( cd "$wt_path" && gh pr checkout "$pr" >/dev/null 2>&1 ); then
  git worktree remove --force "$wt_path" >/dev/null 2>&1 || true
  echo "{\"error\": \"gh pr checkout $pr failed inside new worktree (branch already checked out elsewhere, or fork access?)\"}" >&2
  exit 1
fi
emit "$wt_path" true false
