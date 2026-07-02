#!/usr/bin/env bash
# Shared helpers for request-review. Source this; don't execute it.
#
# request-review is the *notifier*: given a readiness verdict (produced by an
# arbiter such as address-pr's ready-for-review.sh and piped in), it decides
# whether/how to notify a reviewer. It owns only its own per-worktree thread
# state here; it never computes the verdict itself.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "request-review lib: not inside a git worktree" >&2
  exit 1
fi

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/pr-ident.sh
source "$ZEUS_LIB_DIR/pr-ident.sh"
# shellcheck source=../../../lib/dispatch.sh
source "$ZEUS_LIB_DIR/dispatch.sh"   # usage_exit / need / unknown_verb (exit 2 on usage)
# shellcheck source=../../../lib/lock.sh
source "$ZEUS_LIB_DIR/lock.sh"
# shellcheck source=../../../lib/state.sh
source "$ZEUS_LIB_DIR/state.sh"

# Per-worktree state (isolated: git-dir resolves to the worktree's gitdir).
STATE_DIR="$(state_root request-review)"
# shellcheck disable=SC2034  # consumed by review-thread.sh, which sources this lib
REVIEW_THREAD_FILE="$STATE_DIR/review-thread.json"
