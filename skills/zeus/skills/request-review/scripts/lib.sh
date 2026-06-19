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

# Per-worktree state (isolated: git-dir resolves to the worktree's gitdir).
STATE_DIR="$(git rev-parse --absolute-git-dir)/request-review"
# shellcheck disable=SC2034  # consumed by review-thread.sh, which sources this lib
REVIEW_THREAD_FILE="$STATE_DIR/review-thread.json"
mkdir -p "$STATE_DIR"

# with_lock <lock_dir> — advisory lock around a read-modify-write so two
# concurrent invocations (e.g. a watch-driven re-review and a manual one) can't
# lose each other's update. mkdir is atomic; a dead holder's lock is stolen; a
# ~5s timeout prevents a permanent deadlock. Mirrors the family's helper.
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
# Cross-cutting identifier parsing (house convention; mirrored verbatim in
# address-pr/scripts/lib.sh — keep the two in sync).
#
# Every script that takes a PR / repo / SHA resolves them through these helpers
# so the form is identical everywhere: flags are canonical, bare positionals are
# tolerated, and the repo is ALWAYS one `owner/repo` slug (never split).
#
# resolve_pr "$@"  — parse identifiers WITHOUT any network call. Sets globals:
#     PR, REPO_SLUG, OWNER, REPO_NAME, SHA   (any may be "")
#     REST=( … )                             unconsumed args, in order
#   Accepts, in any order: --pr N|=N (or a bare all-digits token), --repo
#   owner/repo|=form (or a bare '/'-token), --sha|--head-sha X|=form. A bare
#   non-slash, non-numeric token is left in REST so a stale split `<owner>
#   <repo>` call trips the caller's usage check loudly. A non-slug --repo is
#   rejected loudly. Under `set -u`, expand REST as "${REST[@]:-}".
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

# resolve_target "$@" — like resolve_pr, but defaults REPO_SLUG via `gh` when the
# caller supplied none (for scripts that always need owner/repo).
resolve_target() {
  resolve_pr "$@"
  if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  fi
}
