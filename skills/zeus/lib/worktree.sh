#!/usr/bin/env bash
# worktree.sh — shared git-worktree engine for the PR-workflow skills. SOURCE this
# (don't execute); defines functions only, sets no shell options, runs no top-level
# code, so it is safe to source into a `set -euo pipefail` script.
#
# WHY: address-pr's ensure-worktree.sh and review-pr's ensure-checkout.sh both need
# the SAME isolate-a-PR-in-a-worktree engine — find the main root, derive the
# conventional path, reuse a registered worktree or create one, and lay the (maybe
# fork) branch down via `gh pr checkout`. That engine had drifted into two copies;
# this is the ONE copy. Each caller keeps only its own extras (address-pr: reuse a
# worktree already parked on the PR head branch; review-pr: the foreign blobless-clone
# path) and its own output JSON shape — this fragment owns just the shared mechanics.
#
# These run PRE-isolation, so callers source THIS fragment directly (like pr-ident.sh),
# never the skill's lib.sh — sourcing lib.sh would create state under the launch
# checkout's .git before the agent has entered the worktree.
#
# API (all read git state; the two mutating helpers set globals, never capture-via-subshell):
#   worktree_main_root                 → print the main worktree root (first `git worktree
#                                         list` entry). Return 1 if not in a work tree.
#   worktree_path_for <prefix> <pr>    → print <main_root>/.claude/worktrees/<prefix>-<pr>.
#   worktree_is_registered <path>      → 0 iff a worktree is registered at exactly <path>.
#   worktree_on_branch <refs/heads/b>  → print the worktree path checked out on <ref>
#                                         (empty + return 1 if none).
#   worktree_ensure_local <path> <pr>  → reuse-at-path / prune-leftover / `add --detach`,
#                                         then `gh pr checkout <pr>`. On success sets
#                                         WORKTREE_RESULT=reused|created and returns 0; on
#                                         failure sets WORKTREE_ERR=<message> and returns 1.
#                                         (Sets globals, not stdout, so the caller can read
#                                         both the result AND the error without a subshell.)

# worktree_main_root — the main worktree is always the first `git worktree list` entry;
# anchoring the conventional path there makes it identical from any worktree.
worktree_main_root() {
  local line
  while IFS= read -r line; do
    case "$line" in "worktree "*) printf '%s\n' "${line#worktree }"; return 0 ;; esac
  done < <(git worktree list --porcelain)
  return 1
}

# worktree_path_for <prefix> <pr> — the conventional isolated-worktree path.
worktree_path_for() {
  local prefix="${1:?worktree_path_for: prefix required}" pr="${2:?worktree_path_for: pr required}" mr
  mr="$(worktree_main_root)" || return 1
  printf '%s\n' "$mr/.claude/worktrees/$prefix-$pr"
}

# worktree_on_branch <refs/heads/branch> — path of the worktree on that branch, or empty.
worktree_on_branch() {
  local want="${1:?worktree_on_branch: ref required}" line cur=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur="${line#worktree }" ;;
      "branch $want") printf '%s\n' "$cur"; return 0 ;;
    esac
  done < <(git worktree list --porcelain)
  return 1
}

# worktree_is_registered <path> — is <path> a registered worktree?
worktree_is_registered() {
  local want="${1:?worktree_is_registered: path required}" line
  while IFS= read -r line; do
    case "$line" in "worktree $want") return 0 ;; esac
  done < <(git worktree list --porcelain)
  return 1
}

# worktree_ensure_local <path> <pr> — reuse/prune/create a worktree at <path> and
# check out the PR's (maybe fork) branch there via `gh pr checkout`. Delegating the
# branch checkout to gh keeps fork head refs resolving correctly. Sets WORKTREE_RESULT
# (reused|created) on success / WORKTREE_ERR on failure; returns 0/1.
worktree_ensure_local() {
  local wt_path="${1:?worktree_ensure_local: path required}" pr="${2:?worktree_ensure_local: pr required}"
  WORKTREE_RESULT=""; WORKTREE_ERR=""

  # Reuse: the conventional path is already a registered worktree (maybe parked on
  # another branch) — re-point it at the PR branch and reuse.
  if worktree_is_registered "$wt_path"; then
    if ( cd "$wt_path" && gh pr checkout "$pr" >/dev/null 2>&1 ); then
      WORKTREE_RESULT=reused; return 0
    fi
    WORKTREE_ERR="existing worktree $wt_path could not be switched to PR $pr (dirty? branch in use elsewhere?)"
    return 1
  fi

  # A leftover directory git doesn't track → prune, else refuse rather than working
  # in an unmanaged dir.
  if [ -e "$wt_path" ]; then
    git worktree prune >/dev/null 2>&1 || true
    if [ -e "$wt_path" ]; then
      WORKTREE_ERR="$wt_path exists but is not a registered worktree; remove it or run 'git worktree prune'"
      return 1
    fi
  fi

  # Create: an empty detached worktree, then let gh lay down the branch. We only
  # reach here when the branch is checked out nowhere, so no two-worktrees-one-branch.
  mkdir -p "$(dirname "$wt_path")"
  if ! git worktree add --detach "$wt_path" >/dev/null 2>&1; then
    WORKTREE_ERR="git worktree add failed for $wt_path"
    return 1
  fi
  if ! ( cd "$wt_path" && gh pr checkout "$pr" >/dev/null 2>&1 ); then
    git worktree remove --force "$wt_path" >/dev/null 2>&1 || true
    WORKTREE_ERR="gh pr checkout $pr failed in new worktree (branch checked out elsewhere, or fork access?)"
    return 1
  fi
  WORKTREE_RESULT=created; return 0
}
