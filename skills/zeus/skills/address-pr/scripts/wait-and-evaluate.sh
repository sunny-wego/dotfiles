#!/usr/bin/env bash
# Atomic wait-then-evaluate: fold 4 LLM tool calls into 1.
#
# Steps:
#   1. wait-for-sha.sh          poll until GitHub HEAD matches local HEAD
#   2. gh pr checks --watch     block up to 600s until all checks settle
#   3. pr-status.sh > STATUS_FILE
#   4. evaluate-iteration.sh    decide next action
#
# Usage: wait-and-evaluate.sh --pr <n> <push_exit>   (PR also accepted positionally)
#   push_exit  -1 = pre-fix (initial or post-wait before any fix this round)
#                0 = just pushed fresh commits
#                1 = nothing to commit/push
#
# Iteration is read from $STATE_FILE (state.sh init must have been called).
# Max iterations is configurable via MAX_ITERATIONS env var (default 5).
#
# On --watch timeout, exits deterministically with {action: "wait", reason: "check-watch timeout"}.
#
# Outputs the merged JSON from evaluate-iteration.sh plus a `sha_match` field.
# Exit code: always 0.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

resolve_pr "$@"
pr="${PR:?Usage: wait-and-evaluate.sh --pr <n> <push_exit>}"
push_exit="${REST[0]:?push_exit required (-1, 0, or 1)}"
max_iter="${MAX_ITERATIONS:-5}"

iteration=$(bash "$SCRIPT_DIR/state.sh" iteration 2>/dev/null || echo 0)

# 1. Wait for GitHub to sync head SHA
local_sha=$(git rev-parse HEAD)
sha_json=$(bash "$SCRIPT_DIR/wait-for-sha.sh" "$pr" "$local_sha" 2>/dev/null || true)
sha_match=$(echo "${sha_json:-'{}'}" | jq -r '.matched // false' 2>/dev/null || echo false)

# 2. Watch checks — 600s timeout, non-zero exit expected on failure
# timeout(1): on macOS installed via `brew install coreutils` as `gtimeout`,
# but Claude Code runs on GNU coreutils via gtimeout too. Fall back to no
# wrapper if neither is present — `--watch` itself has no internal timeout,
# so worst case we block up to the Bash tool's 10-minute limit.
if command -v timeout >/dev/null 2>&1;  then TMO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TMO=gtimeout
else TMO=""
fi

watch_timed_out=false
watch_exit=0
if [ -n "$TMO" ]; then
  "$TMO" 600 gh pr checks "$pr" --watch >/dev/null 2>&1 || watch_exit=$?
  [ "$watch_exit" = "124" ] && watch_timed_out=true
else
  gh pr checks "$pr" --watch >/dev/null 2>&1 || watch_exit=$?
fi

# 3. Snapshot
bash "$SCRIPT_DIR/pr-status.sh" "$pr" > "$STATUS_FILE"

# 4. Deterministic timeout short-circuit
if [ "$watch_timed_out" = true ]; then
  jq -nc --argjson sha_match "$sha_match" \
    '{action: "wait", reason: "check-watch timeout (600s)", sha_match: $sha_match}'
  exit 0
fi

# 5. Evaluate
eval_json=$(bash "$SCRIPT_DIR/evaluate-iteration.sh" "$STATUS_FILE" "$push_exit" "$iteration" "$max_iter")
echo "$eval_json" | jq -c --argjson sha_match "$sha_match" '. + {sha_match: $sha_match}'
