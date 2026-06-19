#!/usr/bin/env bash
# Commit, push, wait for GitHub to observe the pushed SHA, and evaluate the
# next loop action atomically.
#
# This script eliminates cross-tool-call state issues: the LLM runs one command
# and gets a single JSON result with both the commit outcome and a fresh loop
# decision. It intentionally delegates evaluation to wait-and-evaluate.sh so it
# does not reuse the stale pre-fix STATUS_FILE snapshot.
#
# Usage: commit-and-evaluate.sh "<commit_msg>" <iteration> <max_iterations>
#
# Outputs JSON:
#   {
#     "action": "fix"|"sweep"|"report"|"wait",
#     "reason": "...",
#     "handlers": [...],
#     "comment_handlers": [...],
#     "commit": { "staged": bool, "committed": bool, "pushed": bool, "safe_stage": {...} },
#     "flush_errors": [...]    # mirrored from .commit.flush.errors when non-empty,
#                              # so the agent's typical jq '{action, reason}'
#                              # inspection sees that some queued replies /
#                              # resolves / reactions failed to post.
#   }
#
# Exit code: always 0 (the action field drives behavior)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

msg="${1:?Usage: commit-and-evaluate.sh \"<commit_msg>\" <iteration> <max_iterations>}"
iteration="${2:?Usage: commit-and-evaluate.sh \"<commit_msg>\" <iteration> <max_iterations>}"
max_iter="${3:?Usage: commit-and-evaluate.sh \"<commit_msg>\" <iteration> <max_iterations>}"

# 1. Commit and push (exit 1 = nothing to do, which is a valid state)
push_exit=0
commit_json=$(bash "$SCRIPT_DIR/commit-and-push.sh" "$msg") || push_exit=$?

# 2. Evaluate next action using a fresh post-push status snapshot. The state
# file is initialized in SKILL.md step 1 and carries the PR number.
pr=$(jq -r '.pr // empty' "$STATE_FILE" 2>/dev/null || echo "")
if [ -n "$pr" ]; then
  eval_json=$(MAX_ITERATIONS="$max_iter" bash "$SCRIPT_DIR/wait-and-evaluate.sh" "$pr" "$push_exit")
else
  # Backward-compatible fallback for direct ad-hoc invocation.
  eval_json=$(bash "$SCRIPT_DIR/evaluate-iteration.sh" "$STATUS_FILE" "$push_exit" "$iteration" "$max_iter")
fi

# 3. Merge into single output: evaluation fields + commit details.
# Surface flush errors at the top level when present — buried under
# `.commit.flush.errors` they're invisible to the agent's typical
# `jq '{action, reason}'` inspection, which is exactly how a misrouted
# `queue-reply` against an issue-comment id silently produced an orphan
# "Fixed at <SHA>" claim with no posted reply.
flush_errors=$(echo "$commit_json" | jq -c '(.flush.errors // [])')
flush_errors_count=$(echo "$flush_errors" | jq 'length')
if [ "$flush_errors_count" -gt 0 ]; then
  jq -nc --argjson commit "$commit_json" --argjson eval "$eval_json" --argjson fe "$flush_errors" \
    '$eval + {commit: $commit, flush_errors: $fe}'
else
  jq -nc --argjson commit "$commit_json" --argjson eval "$eval_json" \
    '$eval + {commit: $commit}'
fi
