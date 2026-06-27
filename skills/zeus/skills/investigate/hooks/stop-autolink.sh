#!/usr/bin/env bash
# Stop hook: auto-link the current branch's PR into the active investigation.
#
# Fires at the end of any turn. No-ops instantly unless ALL hold:
#   - this worktree has an active investigation (journey state present)
#   - the current branch has an open PR
#   - that PR isn't already on the investigation board
# So it costs ~nothing on unrelated work, and goes dormant the moment an
# investigation is closed (state cleared). Install per hooks/INSTALL.md.
#
# Hooks must stay silent on success and never fail the turn — all errors swallowed.
set +e   # never fail the turn; every path exits 0 (matches address-pr's post-push-review.sh)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"

# Resolve the worktree this hook is firing in. The hook runs from the project cwd.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
# Session-isolation gate — only act from inside a linked git worktree, where the
# current-branch->PR mapping can't be swapped underneath the session by a concurrent
# agent in the shared checkout. Without this, a read-only session sitting in the
# shared checkout could link the WRONG PR into the active investigation. (Matches
# address-pr's post-push-review.sh.)
abs_gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
case "$abs_gitdir" in
  */worktrees/*) : ;;   # linked worktree — branch->PR mapping is trustworthy
  *) exit 0 ;;          # primary/shared checkout — don't link
esac
# shellcheck source=../scripts/lib.sh
source "$SKILL_DIR/scripts/lib.sh" 2>/dev/null || exit 0

epic="$(active_epic 2>/dev/null)"; [ -n "$epic" ] || exit 0           # no active investigation → dormant
# Fast path: the family's shared store may already know the branch's PR (create-pr
# records it). Fall back to gh for the branch — works with no create-pr / fresh clone.
pr="$("$SKILL_DIR/scripts/journey.sh" pr-number 2>/dev/null || true)"
[ -n "$pr" ] || pr="$(gh pr view --json number --jq .number 2>/dev/null || true)"
[ -n "$pr" ] || exit 0                                                 # no PR for branch → nothing to link

# Cheap idempotency: only act if we haven't linked this PR before (tracked in state).
linked="$(state_get '.linked_prs' 2>/dev/null)"
case ",$linked," in *",$pr,"*) exit 0;; esac

# Link it (board + closed-issue → sub-issue). Best-effort, silent.
"$SKILL_DIR/scripts/link-to-epic.sh" --pr "$pr" >/dev/null 2>&1 || exit 0
# Remember we handled it.
"$SKILL_DIR/scripts/investigate-state.sh" set linked_prs "${linked:+$linked,}$pr" >/dev/null 2>&1 || true
exit 0
