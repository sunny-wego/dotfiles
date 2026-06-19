#!/usr/bin/env bash
# ping-gap.sh — do the PR's code owners still need a ping for this head SHA?
#
# request-review owns the auto-ping policy and the per-SHA ping stamp, so it —
# not the arbiter — answers "is there an outstanding notification gap?". This
# keeps arbiters (e.g. address-pr's ready-for-review.sh) pure functions of
# GitHub state: they compute readiness, then ask this script separately at
# their Report stage whether a ping is still owed.
#
# Usage: ping-gap.sh --pr <n> --repo <owner/repo> --sha <head_sha>
#   (identifiers also accepted positionally, any order.)
#
# Output JSON:
#   { "enabled": bool, "gap": bool, "reason": string }
#     enabled=false → repo not opted into auto-ping (gap is always false)
#     gap=false, reason="pinged_at_<7sha>"  → already pinged at this head
#     gap=true,  reason="no_ping_for_head"  → ping (or re-ping) still owed
#
# Exit: always 0 — this is a best-effort probe; any failure reports gap=false
# so a missing config or state file can never block a caller's settled path.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"; set +e  # lib enables errexit; this script handles its own flow

resolve_target "$@"
pr="$PR"; repo="$REPO_SLUG"; head_sha="$SHA"
[ -z "$head_sha" ] && [ "${#REST[@]}" -gt 0 ] && head_sha="${REST[0]}"
if [ -z "$pr" ] || [ -z "$repo" ] || [ -z "$head_sha" ]; then
  echo "usage: ping-gap.sh --pr <n> --repo <owner/repo> --sha <head_sha>" >&2
  echo '{"enabled":false,"gap":false,"reason":"bad_args"}'
  exit 0
fi

ap=$(bash "$SCRIPT_DIR/auto-ping.sh" "$repo" 2>/dev/null || echo '{}')
enabled=$(echo "$ap" | jq -r '.enabled // false' 2>/dev/null || echo false)

if [ "$enabled" != "true" ]; then
  echo '{"enabled":false,"gap":false,"reason":"auto_ping_disabled"}'
  exit 0
fi

pinged_sha=$(bash "$SCRIPT_DIR/review-thread.sh" sha "$pr" 2>/dev/null || echo "")

if [ -n "$pinged_sha" ] && [ "$pinged_sha" = "$head_sha" ]; then
  jq -nc --arg r "pinged_at_${pinged_sha:0:7}" '{enabled:true,gap:false,reason:$r}'
else
  echo '{"enabled":true,"gap":true,"reason":"no_ping_for_head"}'
fi
exit 0
