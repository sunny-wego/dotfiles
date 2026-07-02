#!/usr/bin/env bash
# Shared helpers for propose scripts. Source this; don't execute it.
#
# propose is the *issue/decision-doc* skill. Its scripts kept re-deriving the
# per-worktree state dir and the write-tmp-then-rename dance by hand; those live once
# in lib/state.sh (state_root/atomic_write/json_mutate/json_field) and are sourced
# here — never pasted (the same "one copy in lib/" rule as every other skill's lib.sh).
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "propose lib: not inside a git worktree" >&2
  exit 1
fi

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/state.sh
source "$ZEUS_LIB_DIR/state.sh"        # state_root / atomic_write / json_mutate / json_field
# shellcheck source=../../../lib/gh-issue.sh
source "$ZEUS_LIB_DIR/gh-issue.sh"     # gh_issue_number / ensure_label (shared with investigate)
# shellcheck source=../../../lib/config.sh
source "$ZEUS_LIB_DIR/config.sh"       # config_get + ZEUS_CONFIG_DIR

# One-time migration: the skill was renamed create-issue → propose. Move a pre-rename
# store into place BEFORE state_root creates the new dir, so persisted proposals keep
# resolving. Idempotent + best-effort (only moves when the old dir exists and the new
# one doesn't).
_propose_gitdir="$(git rev-parse --absolute-git-dir)"
if [ ! -d "$_propose_gitdir/propose" ] && [ -d "$_propose_gitdir/create-issue" ]; then
  mv "$_propose_gitdir/create-issue" "$_propose_gitdir/propose" 2>/dev/null || true
fi

# Per-worktree state dir (isolated: git-dir resolves to the worktree's gitdir).
# shellcheck disable=SC2034  # consumed by scripts that source this lib (state.sh, …)
STATE_DIR="$(state_root propose)"
