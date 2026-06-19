#!/usr/bin/env bash
# dispatch-monitor.sh — execute the deterministic branches of monitor mode
# (exit / escalate / idle) so the agent only handles `process`.
#
# Inputs:
#   $1  monitor-step.sh probe output (JSON). If "-", read JSON from stdin.
#
# Output:
#   On exit/escalate/idle: a one-line JSON instruction object the agent
#     copies into its next tool call:
#       {action: "schedule",  next_delay, schedule_prompt, schedule_reason}
#       {action: "restart",   restart_prompt}
#       {action: "stop"}                            // exit / unrecoverable
#   On process: prints the original probe JSON unchanged. The agent reads
#     `.filtered_path` and runs the reviews handler, then calls
#     `monitor-step.sh complete-process ... --acked-ids ...` directly.
#
# This script never runs a handler itself. It is a control-flow consolidation
# only — every behavioral exit the agent had today is preserved.
#
# Independence: works on every probe JSON shape that monitor-step.sh emits.
# An unknown action is forwarded to the agent (printed verbatim) rather than
# crashing, so future actions degrade gracefully.

set -euo pipefail

src="${1:-}"
if [ -z "$src" ]; then
  echo "usage: dispatch-monitor.sh <probe-json-file|-|inline-json>" >&2
  exit 1
fi

# Accept "-" for stdin, a file path, or an inline JSON string.
if [ "$src" = "-" ]; then
  probe=$(cat)
elif [ -f "$src" ]; then
  probe=$(cat "$src")
else
  probe="$src"
fi

# Validate the input parses as JSON before reading fields.
if ! echo "$probe" | jq -e . >/dev/null 2>&1; then
  echo "dispatch-monitor: input is not valid JSON" >&2
  exit 1
fi

action=$(echo "$probe" | jq -r '.action // ""')

case "$action" in
  exit)
    # PR closed/merged. monitor-state was already cleared in probe(); nothing
    # more to do. Tell the caller to stop without scheduling.
    echo "$probe" | jq -c '{action: "stop", reason: (.reason // "exit")}'
    ;;

  escalate)
    # Probe found CI/merge degradation or a persistent fetch_failed. Restart
    # the full /zeus:address-pr flow. No schedule from this path.
    echo "$probe" | jq -c '{
      action: "restart",
      reason: (.reason // "escalate"),
      restart_prompt: (.restart_prompt // "/zeus:address-pr")
    }'
    ;;

  idle)
    # No activity (or false-positive PR bump). probe() already advanced
    # last_seen and bumped idle_streak; the caller only needs to schedule
    # the next wake.
    echo "$probe" | jq -c '{
      action: "schedule",
      reason: (.reason // "idle"),
      next_delay: (.next_delay // 60),
      schedule_prompt: (.schedule_prompt // "/zeus:address-pr monitor"),
      schedule_reason: (.schedule_reason // "idle, next probe scheduled")
    }'
    ;;

  process)
    # Agent territory. Forward the probe JSON verbatim — the caller reads
    # .filtered_path, runs handlers/reviews.md, then calls
    # monitor-step.sh complete-process directly.
    printf '%s\n' "$probe"
    ;;

  *)
    # Unknown action. Forward to the agent rather than crashing so future
    # monitor-step.sh additions degrade gracefully.
    printf '%s\n' "$probe"
    ;;
esac
