#!/usr/bin/env bash
# Monitor-mode state — tracks last-seen PR activity timestamp so each wake can
# cheaply detect whether anything new has landed since the previous pass.
#
# Stored in the per-worktree STATE_DIR alongside state.json, so it's isolated
# across concurrent /zeus:address-pr runs in different worktrees. Stale monitor
# cursor/payload files are cleared on init and clear.
#
# Usage:
#   monitor-state.sh init <pr_number> <head_sha> [last_seen_override]
#                                                      # reset stale monitor files, then seed last_seen and idle_streak=0.
#                                                      # last_seen defaults to now(); callers can pass STATE_FILE.started_at
#                                                      # to make monitor's coverage window span the whole /zeus:address-pr run.
#   monitor-state.sh get                               # print full JSON (or {} if missing)
#   monitor-state.sh set-last-seen <iso8601_timestamp> # update last_seen
#   monitor-state.sh pr                                # print stored PR number
#   monitor-state.sh last-seen                         # print stored last_seen
#   monitor-state.sh bump-idle                         # increment idle_streak, print new value
#   monitor-state.sh reset-idle                        # set idle_streak = 0
#   monitor-state.sh idle-streak                       # print current idle_streak (0 if missing)
#   monitor-state.sh bump-probe-failure                # increment probe_failures, print new value
#   monitor-state.sh reset-probe-failures              # set probe_failures = 0
#   monitor-state.sh probe-failures                    # print current probe_failures (0 if missing)
#   monitor-state.sh set-last-acked <json_array>       # replace last_acked_ids atomically
#   monitor-state.sh last-acked                        # print last_acked_ids as JSON ([] if missing)
#   monitor-state.sh clear                             # delete monitor cursor + filtered payload
#
# Schema:
#   {
#     "pr": 476,
#     "last_seen": "2026-04-22T15:32:10Z",
#     "head_sha": "abc123...",
#     "idle_streak": 0,
#     "probe_failures": 0,
#     "last_acked_ids": ["thread-id", "1234567"]
#   }
#
# last_acked_ids is the dedup memory of the *previous* complete-process pass.
# Stage 2 in monitor-probe.sh uses inclusive `>=` against last_seen so items at
# the boundary second survive; without this id-set the inclusive filter would
# re-surface items we already acked in the prior probe. The set is replaced (not
# appended) on every complete-process so its size is bounded by one batch.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cmd="${1:?Usage: monitor-state.sh <init|get|set-last-seen|pr|last-seen|bump-idle|reset-idle|idle-streak|bump-probe-failure|reset-probe-failures|probe-failures|set-last-acked|last-acked|clear> ...}"

case "$cmd" in
  init)
    pr="${2:?PR number required}"
    head_sha="${3:?head_sha required}"
    last_seen_override="${4:-}"
    cleanup_monitor_artifacts
    ts="${last_seen_override:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    jq -n       --argjson pr "$pr"       --arg head "$head_sha"       --arg ts "$ts"       '{pr: $pr, last_seen: $ts, head_sha: $head, idle_streak: 0, probe_failures: 0, last_acked_ids: []}'       > "$MONITOR_FILE"
    cat "$MONITOR_FILE"
    ;;

  get)
    [ -f "$MONITOR_FILE" ] || { echo "{}"; exit 0; }
    cat "$MONITOR_FILE"
    ;;

  set-last-seen)
    ts="${2:?ISO8601 timestamp required}"
    [ -f "$MONITOR_FILE" ] || { echo "monitor state missing — run monitor-state.sh init first" >&2; exit 1; }
    tmp="$MONITOR_FILE.tmp"
    jq --arg ts "$ts" '.last_seen = $ts' "$MONITOR_FILE" > "$tmp"
    mv "$tmp" "$MONITOR_FILE"
    ;;

  pr)
    [ -f "$MONITOR_FILE" ] || { echo ""; exit 0; }
    jq -r '.pr // empty' "$MONITOR_FILE"
    ;;

  last-seen)
    [ -f "$MONITOR_FILE" ] || { echo ""; exit 0; }
    jq -r '.last_seen // empty' "$MONITOR_FILE"
    ;;

  bump-idle)
    [ -f "$MONITOR_FILE" ] || { echo "monitor state missing — run monitor-state.sh init first" >&2; exit 1; }
    tmp="$MONITOR_FILE.tmp"
    jq '.idle_streak = ((.idle_streak // 0) + 1)' "$MONITOR_FILE" > "$tmp"
    mv "$tmp" "$MONITOR_FILE"
    jq -r '.idle_streak' "$MONITOR_FILE"
    ;;

  reset-idle)
    [ -f "$MONITOR_FILE" ] || { echo "monitor state missing — run monitor-state.sh init first" >&2; exit 1; }
    tmp="$MONITOR_FILE.tmp"
    jq '.idle_streak = 0' "$MONITOR_FILE" > "$tmp"
    mv "$tmp" "$MONITOR_FILE"
    ;;

  idle-streak)
    [ -f "$MONITOR_FILE" ] || { echo "0"; exit 0; }
    jq -r '.idle_streak // 0' "$MONITOR_FILE"
    ;;

  bump-probe-failure)
    [ -f "$MONITOR_FILE" ] || { echo "monitor state missing — run monitor-state.sh init first" >&2; exit 1; }
    tmp="$MONITOR_FILE.tmp"
    jq '.probe_failures = ((.probe_failures // 0) + 1)' "$MONITOR_FILE" > "$tmp"
    mv "$tmp" "$MONITOR_FILE"
    jq -r '.probe_failures' "$MONITOR_FILE"
    ;;

  reset-probe-failures)
    [ -f "$MONITOR_FILE" ] || { echo "monitor state missing — run monitor-state.sh init first" >&2; exit 1; }
    tmp="$MONITOR_FILE.tmp"
    jq '.probe_failures = 0' "$MONITOR_FILE" > "$tmp"
    mv "$tmp" "$MONITOR_FILE"
    ;;

  probe-failures)
    [ -f "$MONITOR_FILE" ] || { echo "0"; exit 0; }
    jq -r '.probe_failures // 0' "$MONITOR_FILE"
    ;;

  set-last-acked)
    arr="${2:?JSON array of ids required}"
    [ -f "$MONITOR_FILE" ] || { echo "monitor state missing — run monitor-state.sh init first" >&2; exit 1; }
    # Validate it parses as a JSON array before writing.
    if ! echo "$arr" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "set-last-acked: argument must be a JSON array, got: $arr" >&2
      exit 1
    fi
    tmp="$MONITOR_FILE.tmp"
    jq --argjson ids "$arr" '.last_acked_ids = ($ids | map(tostring))' "$MONITOR_FILE" > "$tmp"
    mv "$tmp" "$MONITOR_FILE"
    ;;

  last-acked)
    [ -f "$MONITOR_FILE" ] || { echo "[]"; exit 0; }
    jq -c '.last_acked_ids // []' "$MONITOR_FILE"
    ;;

  clear)
    cleanup_monitor_artifacts
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac
