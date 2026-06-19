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

# Per-worktree run state (isolated: git-dir resolves to the worktree's gitdir).
STATE_DIR="$(git rev-parse --absolute-git-dir)/improve"
mkdir -p "$STATE_DIR"

# Durable, cross-session ledger — in the zeus SOURCE, not the worktree.
# `pwd -P` resolves the symlinked install (~/.claude/skills/zeus -> source) to the
# real source dir, so the ledger is the git-tracked one and survives reinstalls.
ZEUS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LEDGER_DIR="$ZEUS_ROOT/learnings"
LEDGER="$LEDGER_DIR/ledger.jsonl"
mkdir -p "$LEDGER_DIR"
# shellcheck disable=SC2034  # consumed by harvest.sh / ledger.sh which source this
FRICTION_FILE="$STATE_DIR/friction.json"

# with_lock <lock_dir> — advisory lock around a read-modify-write so two runs
# can't lose each other's ledger append. mkdir is atomic; a dead holder's lock is
# stolen; a ~5s timeout prevents a permanent deadlock. Mirrors the family helper.
with_lock() {
  local lock="$1" i=0 pid=""
  while ! mkdir "$lock" 2>/dev/null; do
    pid=""; [ -f "$lock/pid" ] && pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
    i=$((i + 1)); [ "$i" -ge 50 ] && { rm -rf "$lock"; continue; }
    sleep 0.1
  done
  echo $$ > "$lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" EXIT
}

# ----------------------------------------------------------------------------
# Cross-cutting identifier parsing (house convention; mirrored verbatim from
# address-pr/request-review lib.sh — keep in sync). improve mostly operates on
# the current worktree, but harvest accepts an explicit --pr/--repo.
resolve_pr() {
  PR=""; REPO_SLUG=""; OWNER=""; REPO_NAME=""; SHA=""; REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)                 PR="${2:?--pr needs a value}"; shift 2 ;;
      --pr=*)               PR="${1#*=}"; shift ;;
      --repo)               REPO_SLUG="${2:?--repo needs a value}"; shift 2 ;;
      --repo=*)             REPO_SLUG="${1#*=}"; shift ;;
      --sha|--head-sha)     SHA="${2:?--sha needs a value}"; shift 2 ;;
      --sha=*|--head-sha=*) SHA="${1#*=}"; shift ;;
      --)                   shift; while [ $# -gt 0 ]; do REST+=("$1"); shift; done ;;
      *)
        if   [ -z "$PR" ] && [[ "$1" =~ ^[0-9]+$ ]];  then PR="$1"
        elif [ -z "$REPO_SLUG" ] && [[ "$1" == */* ]]; then REPO_SLUG="$1"
        else REST+=("$1"); fi
        shift ;;
    esac
  done
  if [ -n "$REPO_SLUG" ] && [[ "$REPO_SLUG" != */* ]]; then
    echo "resolve: --repo must be owner/repo (got '$REPO_SLUG')" >&2; return 2
  fi
  [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  return 0
}
resolve_target() {
  resolve_pr "$@"
  if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  fi
}
