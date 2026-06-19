#!/usr/bin/env bash
# Shared helpers for address-pr scripts.
# Source (don't execute): `source "$(dirname "$0")/lib.sh"`
#
# Provides:
#   $STATE_DIR              per-worktree dir under .git/ (isolated across worktrees)
#   $STATUS_FILE            latest pr-status snapshot
#   $STATE_FILE             telemetry log (handler outcomes per iteration)
#   $ORIGINAL_INTENT_FILE   parsed Original Intent context captured at startup
#   $MONITOR_FILE           monitor-mode cursor state
#   $MONITOR_FILTERED_FILE  reduced review payload for monitor wakes
#   $REVIEWS_FILE           full review payload for the reviews handler
#   $REVIEWS_FILTERED_FILE  author-filtered review payload for standalone mode
#   $REVIEWS_DIGEST_FILE    compact review digest for first-pass triage
#   $CONFLICTS_FILE         merge-conflict path list
#   $CONFLICT_FILES_FILE    merge-conflict path list as JSON
#   $RELEVANCE_INPUT_FILE   relevance-check prompt package JSON
#   cleanup_run_artifacts   clear temp/snapshot files without removing telemetry
#   cleanup_run_state       clear telemetry + temp files before a fresh run
#   cleanup_monitor_artifacts clear monitor cursor/payload files
#   acquire_lock            mkdir-based advisory lock (macOS-compatible, auto-releases on exit)

set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lib.sh: not inside a git worktree" >&2
  exit 1
fi

STATE_DIR="$(git rev-parse --absolute-git-dir)/address-pr"
STATUS_FILE="$STATE_DIR/status.json"
STATE_FILE="$STATE_DIR/state.json"
ORIGINAL_INTENT_FILE="$STATE_DIR/original-intent.json"
MONITOR_FILE="$STATE_DIR/monitor.json"
MONITOR_FILTERED_FILE="$STATE_DIR/monitor-filtered.json"
REVIEWS_FILE="$STATE_DIR/reviews.json"
REVIEWS_FILTERED_FILE="$STATE_DIR/reviews.filtered.json"
REVIEWS_DIGEST_FILE="$STATE_DIR/reviews.digest.json"
CONFLICTS_FILE="$STATE_DIR/conflicts.txt"
CONFLICT_FILES_FILE="$STATE_DIR/conflict-files.json"
RELEVANCE_INPUT_FILE="$STATE_DIR/relevance-input.json"
LOCK_DIR="$STATE_DIR/lock"

mkdir -p "$STATE_DIR"

cleanup_monitor_artifacts() {
  rm -f     "$MONITOR_FILE"     "$MONITOR_FILTERED_FILE"
}

cleanup_run_artifacts() {
  rm -f     "$STATUS_FILE"     "$ORIGINAL_INTENT_FILE"     "$REVIEWS_FILE"     "$REVIEWS_FILTERED_FILE"     "$REVIEWS_DIGEST_FILE"     "$CONFLICTS_FILE"     "$CONFLICT_FILES_FILE"     "$RELEVANCE_INPUT_FILE"     "$MONITOR_FILTERED_FILE"     /tmp/.address-pr-status.json     /tmp/.address-pr-conflicts.txt     /tmp/.address-pr-conflict-files.json     /tmp/.address-pr-relevance-input.json     /tmp/reviews.json     /tmp/reviews.filtered.json     /tmp/reviews.digest.json
}

cleanup_run_state() {
  cleanup_run_artifacts
  cleanup_monitor_artifacts
  rm -f "$STATE_FILE"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  local pid=""
  [ -f "$LOCK_DIR/pid" ] && pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "Another /zeus:address-pr is already running in this worktree (pid $pid). Wait for it to finish or remove $LOCK_DIR." >&2
    exit 1
  fi

  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
}

# with_lock <lock_dir> — advisory lock around a read-modify-write so two
# concurrent invocations (e.g. a monitor wake and a manual re-review) can't lose
# each other's update. mkdir is atomic; a dead holder's lock is stolen; a ~5s
# timeout prevents a permanent deadlock if a holder died without cleanup. Each
# short-lived script invocation acquires once and releases on EXIT.
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
# request-review/scripts/lib.sh — keep the two in sync).
#
# Every script that takes a PR / repo / SHA resolves them through these helpers
# so the form is identical everywhere: flags are canonical, bare positionals are
# tolerated, and the repo is ALWAYS one `owner/repo` slug (never split). This is
# the fix for the arg-positioning sprawl that let `<pr> <owner> <repo>` and
# `<pr> <owner/repo>` coexist and silently misparse.
#
# resolve_pr "$@"  — parse identifiers WITHOUT any network call. Sets globals:
#     PR, REPO_SLUG, OWNER, REPO_NAME, SHA   (any may be "")
#     REST=( … )                             unconsumed args, in order
#   Accepts, in any order:
#     --pr N | --pr=N            (also: a bare all-digits token)
#     --repo owner/repo | =form  (also: a bare token containing '/')
#     --sha X | --head-sha X | =form
#   A bare non-slash, non-numeric token is left in REST — so a stale split
#   `<owner> <repo>` call surfaces as leftover args and trips the caller's own
#   usage check LOUDLY instead of being silently misread. A `--repo` value that
#   is not owner/repo-shaped is rejected loudly.
#   Note: under `set -u`, expand REST as "${REST[@]:-}" or guard on ${#REST[@]}.
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
