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
#
# Cross-cutting helpers (with_lock, acquire_lock, resolve_pr, resolve_target) come
# from the family's single copies in zeus/lib/, sourced below — not duplicated here.

set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lib.sh: not inside a git worktree" >&2
  exit 1
fi

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/pr-ident.sh
source "$ZEUS_LIB_DIR/pr-ident.sh"
# shellcheck source=../../../lib/lock.sh
source "$ZEUS_LIB_DIR/lock.sh"

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
