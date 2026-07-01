#!/usr/bin/env bash
# Shared helpers for zeus:improve. Source this; don't execute it.
#
# zeus:improve is the *self-improvement* skill: it harvests a session's
# zeus-workflow friction, grades it, and lands durable fixes. Its own per-worktree
# run state lives under .git/improve; the cross-session LEDGER lives in the zeus
# SOURCE (so it's git-tracked in dotfiles and accumulates across repos), resolved
# via `pwd -P` so it points at the real source even when invoked through the
# symlinked install.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "improve lib: not inside a git worktree" >&2
  exit 1
fi

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/pr-ident.sh
source "$ZEUS_LIB_DIR/pr-ident.sh"
# shellcheck source=../../../lib/lock.sh
source "$ZEUS_LIB_DIR/lock.sh"
# shellcheck source=../../../lib/state.sh
source "$ZEUS_LIB_DIR/state.sh"

# Per-worktree run state (isolated: git-dir resolves to the worktree's gitdir).
STATE_DIR="$(state_root improve)"

# Durable, cross-session ledger — in the zeus SOURCE, not the worktree.
# `pwd -P` resolves the symlinked install (~/.claude/skills/zeus -> source) to the
# real source dir, so the ledger is the git-tracked one and survives reinstalls.
ZEUS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LEDGER_DIR="$ZEUS_ROOT/learnings"
LEDGER="$LEDGER_DIR/ledger.jsonl"
mkdir -p "$LEDGER_DIR"
# shellcheck disable=SC2034  # consumed by harvest.sh / ledger.sh which source this
FRICTION_FILE="$STATE_DIR/friction.json"
