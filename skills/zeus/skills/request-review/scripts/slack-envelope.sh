#!/usr/bin/env bash
# slack-envelope.sh — sourced helpers shared by the reviewer-ping formatters
# (ready-slack-message.sh = initial ping, re-review-message.sh = re-review).
# Functions only; no side effects, no `set` changes, never posts to Slack.
#
# These centralize the base send/skip decision (ready-gate + per-SHA dedup) both
# formatters were duplicating. Wording of the "already pinged" skip differs per
# caller, so the gate returns a neutral token the caller maps to its own phrasing.

# review_gate_base <ready> <last_sha> <head_sha>
#   Echoes one of:
#     "ok"            — sendable on the shared checks (caller may add more gates)
#     "not_ready"     — ready-for-review says not ready
#     "already:<7sha>"— already pinged/requested at the current head SHA
review_gate_base() {
  local ready="$1" last="$2" head="$3"
  if [ "$ready" != "true" ]; then echo "not_ready"; return; fi
  if [ -n "$last" ] && [ "$last" = "$head" ]; then echo "already:${last:0:7}"; return; fi
  echo "ok"
}
