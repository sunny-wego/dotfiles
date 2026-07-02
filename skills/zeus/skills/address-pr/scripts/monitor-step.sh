#!/usr/bin/env bash
# Deterministic monitor-mode state machine wrapper.
#
# Usage:
#   monitor-step.sh --pr <n> [--repo <owner/repo>]   (identifiers also positional)
#   monitor-step.sh complete-process <pr_updated_at> [--acked-ids id1,id2,...]
#
# The default mode initializes monitor state when needed, runs monitor-probe.sh,
# updates idle/probe-failure cursors for read-only outcomes, and returns the
# next scheduling decision as compact JSON. For action=process, run the reviews
# handler against filtered_path, commit/push as needed, then call
# `monitor-step.sh complete-process <pr_updated_at> --acked-ids <ids>` before
# scheduling.
#
# The `--acked-ids` flag is the caller's explicit acknowledgement of items they
# processed from $MONITOR_FILTERED_FILE. Ids must match the `.id` field on each
# bucket entry (thread node id for threads, numeric inline-comment id for
# inline_comments, review id for reviews, issue-comment id for
# conversation_comments). When supplied, complete-process refuses to advance
# last_seen past any unacknowledged item — those stay visible on the next probe
# — and persists the acked ids to monitor state's last_acked_ids so the next
# probe's inclusive `>=` filter doesn't re-surface them.
#
# When $MONITOR_FILTERED_FILE has items, --acked-ids is required: the call
# hard-fails with non-zero exit if omitted, since silently age-ing out fetched
# items is the exact bug this skill is supposed to prevent. Empty filtered_path
# (or no file) keeps working without the flag.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

delay_for_idle_streak() {
  # Cache-aligned buckets: stay <=270s (prompt-cache stays warm) for a near-term
  # recheck, else jump to >=1200s (amortize the cache miss). The 300-1100s range
  # is the worst-of-both (pays the miss without amortizing) — skip it. See the
  # ScheduleWakeup guidance the agent honors when scheduling the next wake.
  case "$1" in
    0) echo 240 ;;
    1) echo 1200 ;;
    2) echo 1800 ;;
    *) echo 3600 ;;
  esac
}

set_last_seen_if_forward() {
  local ts="$1"
  local current

  if [ -z "$ts" ] || [ "$ts" = "null" ]; then
    return 0
  fi

  current=$(bash "$SCRIPT_DIR/monitor-state.sh" last-seen 2>/dev/null || echo "")
  if [ -z "$current" ] || [ ! "$ts" \< "$current" ]; then
    bash "$SCRIPT_DIR/monitor-state.sh" set-last-seen "$ts"
  fi
}

ensure_monitor_state() {
  local owner="$1"
  local repo="$2"
  local pr="$3"
  local head_sha started_at

  if [ -f "$MONITOR_FILE" ]; then
    return 0
  fi

  head_sha=$(gh pr view "$pr" --repo "$owner/$repo" --json headRefOid -q '.headRefOid' 2>/dev/null || echo "unknown")
  started_at=""
  if [ -f "$STATE_FILE" ]; then
    started_at=$(jq -r '.started_at // empty' "$STATE_FILE" 2>/dev/null || echo "")
  fi
  if [ -z "$started_at" ]; then
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  bash "$SCRIPT_DIR/monitor-state.sh" init "$pr" "$head_sha" "$started_at" >/dev/null
}

# Subtract 1 second from an ISO-8601 "YYYY-MM-DDTHH:MM:SSZ" timestamp.
# Portable across GNU/BSD date.
decrement_iso_one_second() {
  local ts="$1"
  date -u -d "$ts - 1 second" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -j -v-1S -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null && return 0
  return 1
}

complete_process() {
  local pr_updated_at="${1:?Usage: monitor-step.sh complete-process <pr_updated_at> [--acked-ids id1,id2,...]}"
  shift
  local acked_ids=""
  local ack_flag_provided=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --acked-ids)
        acked_ids="${2:-}"
        ack_flag_provided=1
        shift 2 || true
        ;;
      *)
        shift
        ;;
    esac
  done

  local pending_count=0
  local pending_ids_json='[]'
  local acked_count=0
  local acked_arr='[]'

  if [ -f "$MONITOR_FILTERED_FILE" ]; then
    # Normalize all four buckets into [{id, ts}] using the same timestamp
    # fallbacks as monitor-probe.sh's client-side filter, so the partition
    # below uses the same id strings the next probe's dedup will check.
    local items_json
    items_json=$(jq -c '
      [
        ((.threads // [])[] | {
          id: (.id // ""),
          ts: (.comments.nodes[0].updated_at // .comments.nodes[0].created_at // "")
        }),
        ((.reviews // [])[] | {
          id: ((.id // .databaseId) | tostring),
          ts: (.submitted_at // .updated_at // "")
        }),
        ((.inline_comments // [])[] | {
          id: (.id | tostring),
          ts: (.updated_at // .created_at // "")
        }),
        ((.conversation_comments // [])[] | {
          id: (.id | tostring),
          ts: (.updated_at // .created_at // "")
        })
      ] | map(select(.id != "" and .ts != ""))
    ' "$MONITOR_FILTERED_FILE")

    local total
    total=$(echo "$items_json" | jq 'length')

    if [ "$ack_flag_provided" = "0" ] && [ "$total" -gt 0 ]; then
      echo "[monitor-step] complete-process: --acked-ids is required when filtered_path has items ($total item(s)). Refusing to advance last_seen. Pass --acked-ids '<id1,id2,...>', or '' to explicitly ack none and defer all items to the next probe." >&2
      exit 2
    fi

    if [ "$ack_flag_provided" = "1" ]; then
      acked_arr=$(jq -nc --arg s "$acked_ids" '$s | split(",") | map(select(length > 0))')
      local partition
      partition=$(jq -nc --argjson items "$items_json" --argjson acked "$acked_arr" '
        ($acked | map({key: ., value: true}) | from_entries) as $ack
        | ($items | map(.acked = ($ack[.id] // false)))
        | {
            acked_count:   ([.[] | select(.acked)]       | length),
            pending_count: ([.[] | select(.acked | not)] | length),
            pending_ids:   ([.[] | select(.acked | not) | .id]),
            oldest_pending_ts: ([.[] | select(.acked | not) | .ts] | min // null)
          }
      ')
      acked_count=$(echo "$partition" | jq -r '.acked_count')
      pending_count=$(echo "$partition" | jq -r '.pending_count')
      pending_ids_json=$(echo "$partition" | jq -c '.pending_ids')
      local oldest_pending
      oldest_pending=$(echo "$partition" | jq -r '.oldest_pending_ts // empty')

      if [ "$pending_count" -gt 0 ] && [ -n "$oldest_pending" ]; then
        # Pending items remain. Advance only up to (oldest_pending - 1s) so
        # the next probe's `>= $last_seen` filter still surfaces them. If we
        # can't decrement the timestamp portably, leave last_seen unchanged
        # (safest fallback — never advances past an un-acked item).
        local safe_ts
        safe_ts=$(decrement_iso_one_second "$oldest_pending" 2>/dev/null || echo "")
        if [ -n "$safe_ts" ]; then
          set_last_seen_if_forward "$safe_ts"
        fi
      else
        set_last_seen_if_forward "$pr_updated_at"
      fi
    else
      # Empty filtered_path + no flag — nothing was processed, just bump watermark.
      set_last_seen_if_forward "$pr_updated_at"
    fi
  else
    set_last_seen_if_forward "$pr_updated_at"
  fi

  # Persist the acked-id set so the next probe's inclusive `>=` filter can
  # dedup against it. Always write (even an empty array) so a fresh probe
  # never sees stale dedup state from a prior batch.
  bash "$SCRIPT_DIR/monitor-state.sh" set-last-acked "$acked_arr"

  bash "$SCRIPT_DIR/monitor-state.sh" reset-idle
  bash "$SCRIPT_DIR/monitor-state.sh" reset-probe-failures

  # Recompute the schedule from POST-ack state. Only tighten to 1m when items
  # were deferred (pending_count > 0) and warrant a soon re-probe; when nothing
  # is pending (everything acked / nothing actionable), fall back to the warm
  # idle delay instead of looping every 60s on a quiet PR.
  local cp_delay cp_reason
  if [ "${pending_count:-0}" -gt 0 ]; then
    cp_delay=60
    cp_reason="$pending_count item(s) deferred — re-probing in 1m"
  else
    cp_delay=$(delay_for_idle_streak 0)
    cp_reason="activity processed, nothing pending — next probe in $(( cp_delay / 60 ))m"
  fi

  jq -nc \
    --arg prompt "/zeus:address-pr monitor" \
    --argjson acked "$acked_count" \
    --argjson pending "$pending_count" \
    --argjson pending_ids "$pending_ids_json" \
    --argjson next_delay "$cp_delay" \
    --arg schedule_reason "$cp_reason" \
    --arg pr_updated_at "$pr_updated_at" \
    '{
      action: "schedule",
      reason: "activity processed",
      next_delay: $next_delay,
      schedule: true,
      schedule_prompt: $prompt,
      schedule_reason: $schedule_reason,
      acked_count: $acked,
      pending_count: $pending,
      pending_ids: $pending_ids,
      pr_updated_at: $pr_updated_at
    }'
}

probe() {
  local owner="$1"
  local repo="$2"
  local pr="$3"
  local probe_json action reason pr_updated failures idle_streak next_delay

  ensure_monitor_state "$owner" "$repo" "$pr"

  if ! probe_json=$(bash "$SCRIPT_DIR/monitor-probe.sh" --pr "$pr" --repo "$owner/$repo"); then
    probe_json=$(jq -nc '{action: "idle", reason: "probe_failed", pr_updated_at: null}')
  fi

  action=$(echo "$probe_json" | jq -r '.action')
  reason=$(echo "$probe_json" | jq -r '.reason // ""')
  pr_updated=$(echo "$probe_json" | jq -r '.pr_updated_at // empty')

  case "$action" in
    exit)
      bash "$SCRIPT_DIR/monitor-state.sh" clear
      echo "$probe_json" | jq -c '. + {schedule: false}'
      ;;

    escalate)
      bash "$SCRIPT_DIR/monitor-state.sh" reset-probe-failures
      echo "$probe_json" | jq -c '. + {schedule: false, restart_prompt: "/zeus:address-pr"}'
      ;;

    idle)
      if [ "$reason" = "probe_failed" ]; then
        failures=$(bash "$SCRIPT_DIR/monitor-state.sh" bump-probe-failure)
        if [ "$failures" -ge 3 ]; then
          echo "$probe_json" | jq -c --argjson failures "$failures" \
            '. + {action: "escalate", reason: "probe_failed", probe_failures: $failures, schedule: false, restart_prompt: "/zeus:address-pr"}'
          exit 0
        fi
      else
        bash "$SCRIPT_DIR/monitor-state.sh" reset-probe-failures
      fi

      idle_streak=$(bash "$SCRIPT_DIR/monitor-state.sh" bump-idle)
      set_last_seen_if_forward "$pr_updated"
      next_delay=$(delay_for_idle_streak "$idle_streak")

      echo "$probe_json" | jq -c \
        --argjson idle_streak "$idle_streak" \
        --argjson next_delay "$next_delay" \
        --arg prompt "/zeus:address-pr monitor" \
        '. + {
          idle_streak: $idle_streak,
          next_delay: $next_delay,
          schedule: true,
          schedule_prompt: $prompt,
          schedule_reason: ("idle streak=" + ($idle_streak|tostring) + ", next probe in " + (if $next_delay < 60 then "\($next_delay)s" else "\(($next_delay / 60)|floor)m" end))
        }'
      ;;

    process)
      bash "$SCRIPT_DIR/monitor-state.sh" reset-probe-failures
      # completion_command_template is a printf-style hint: the caller
      # substitutes the comma-separated id list it actually processed before
      # running it. Without the substitution, the legacy ack-less command
      # still works but emits a stderr warning per item.
      echo "$probe_json" | jq -c \
        --arg prompt "/zeus:address-pr monitor" \
        --arg cmd "bash ${SCRIPT_DIR}/monitor-step.sh complete-process ${pr_updated}" \
        --arg cmd_tmpl "bash ${SCRIPT_DIR}/monitor-step.sh complete-process ${pr_updated} --acked-ids <id1,id2,...>" \
        '. + {
          next_delay: 60,
          schedule: false,
          schedule_after_process: true,
          schedule_prompt: $prompt,
          schedule_reason: "activity found, tightening to 1m",
          completion_command: $cmd,
          completion_command_template: $cmd_tmpl
        }'
      ;;

    *)
      jq -nc --arg action "$action" --arg reason "$reason" \
        '{action: "escalate", reason: ("unknown monitor action: " + $action + " " + $reason), schedule: false, restart_prompt: "/zeus:address-pr"}'
      ;;
  esac
}

if [ "${1:-}" = "complete-process" ]; then
  shift
  complete_process "$@"
else
  resolve_target "$@"
  [ -n "$PR" ] && [ -n "$REPO_SLUG" ] || \
    usage_exit "Usage: monitor-step.sh --pr <n> [--repo <owner/repo>]"
  probe "$OWNER" "$REPO_NAME" "$PR"
fi
