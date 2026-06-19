#!/usr/bin/env bash
# review-thread.sh — request-review-owned reviewer-ping state (per worktree).
#
# Replaces the reviewer-ping fields that used to live in the shared journey.json.
# journey.sh is the cross-skill issue↔pr handoff and stays generic; the Slack
# review thread (which SHA was reviewed, and the ts/channel to thread a re-review
# under) is request-review's concern and lives here. There is no per-reviewer
# "target": the skill pings code owners, so every thread is owner-directed.
#
# Stored at $REVIEW_THREAD_FILE ($STATE_DIR/review-thread.json). It deliberately
# PERSISTS across runs (it is in no cleanup list) so a re-review can attach to
# the original ping, and it is PR-scoped: reads for a different PR return empty,
# so a stale thread from a previous PR in the same worktree is ignored.
#
# Usage:
#   review-thread.sh set <pr> <head_sha> [--thread-ts <ts>] [--channel <id>]
#       Stamp the reviewed SHA. Optional flags persist the Slack thread. Re-stamping
#       the same PR with SHA only preserves the existing thread/channel.
#   review-thread.sh get <pr>     # {sha, at, thread_ts, channel} for <pr>, else {}
#   review-thread.sh sha <pr>     # bare reviewed SHA for <pr>, else empty (dedup probe)
#   review-thread.sh clear        # remove the file
#
# Reads are tolerant: missing file or PR mismatch prints {} / "" and never errors.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cmd="${1:?Usage: review-thread.sh <set|get|sha|clear> ...}"

# Echo the stored record only if it belongs to $1 (PR scope); else {}.
_scoped() {
  [ -f "$REVIEW_THREAD_FILE" ] || { echo '{}'; return; }
  jq -c --argjson pr "$1" 'if (.pr == $pr) then . else {} end' "$REVIEW_THREAD_FILE" 2>/dev/null || echo '{}'
}

case "$cmd" in
  set)
    pr="${2:?pr number required}"; sha="${3:?head sha required}"; shift 3
    with_lock "$REVIEW_THREAD_FILE.lock"   # serialize the read-modify-write
    thread_ts=""; channel=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --thread-ts) thread_ts="${2:-}"; shift 2 ;;
        --channel)   channel="${2:-}"; shift 2 ;;
        *) echo "review-thread.sh set: unknown arg $1" >&2; exit 1 ;;
      esac
    done
    at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Start fresh when the stored record is for a different PR; otherwise merge so
    # a SHA-only re-stamp preserves the thread captured on the initial ping.
    base=$(_scoped "$pr")
    [ "$base" = "{}" ] && base=$(jq -nc --argjson pr "$pr" '{pr:$pr}')
    tmp="$REVIEW_THREAD_FILE.tmp"
    echo "$base" | jq -c --argjson pr "$pr" --arg sha "$sha" --arg at "$at" \
      --arg th "$thread_ts" --arg ch "$channel" '
      . + {pr:$pr, sha:$sha, at:$at}
      | (if $th != "" then .thread_ts = $th else . end)
      | (if $ch != "" then .channel = $ch else . end)
    ' > "$tmp"
    mv "$tmp" "$REVIEW_THREAD_FILE"
    ;;

  get)
    pr="${2:?pr number required}"
    _scoped "$pr" | jq -c '{
      sha:       (.sha // null),
      at:        (.at // null),
      thread_ts: (.thread_ts // null),
      channel:   (.channel // null)
    }'
    ;;

  sha)
    pr="${2:?pr number required}"
    _scoped "$pr" | jq -r '.sha // empty'
    ;;

  clear)
    rm -f "$REVIEW_THREAD_FILE"
    ;;

  *)
    echo "review-thread.sh: unknown command: $cmd" >&2
    exit 1
    ;;
esac
