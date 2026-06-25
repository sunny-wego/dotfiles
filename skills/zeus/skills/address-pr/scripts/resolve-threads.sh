#!/usr/bin/env bash
# Batch-resolve review threads. One script invocation replaces N LLM tool calls.
#
# Usage: resolve-threads.sh <thread_id> [<thread_id> ...]
#
# Thread IDs are the GraphQL node IDs from fetch-review-comments.sh `threads[].id`.
#
# Outputs JSON:
#   { "resolved": ["<id>", ...], "errors": [{"id": "<id>", "error": "..."}] }
#
# Exit code: 0 if all resolved, 1 if any errors.

set -uo pipefail

resolved_json="[]"
errors_json="[]"
any_error=0

# A flaky credential/rate/network blip mid-flush would otherwise leave an
# already-replied thread unresolved (the reply posts, the resolve 401s), which
# silently regresses the PR out of "settled". Retry the resolve a bounded number
# of times on transient failures only; a real error (e.g. bad node id) fails fast.
TRANSIENT_RE='Bad credentials|HTTP 401|HTTP 403|HTTP 429|rate limit|HTTP 5[0-9][0-9]|timeout|timed out|connection reset|TLS handshake|EOF|could not resolve host'
MAX_ATTEMPTS=3

resolve_one() {
  # echoes "" + exit 0 on success; echoes the last error + exit 1 on failure.
  local id="$1" attempt=1 err
  while :; do
    if err=$(gh api graphql \
        -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }' \
        -f id="$id" 2>&1 >/dev/null); then
      printf ''
      return 0
    fi
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ] && printf '%s' "$err" | grep -Eq "$TRANSIENT_RE"; then
      sleep "$attempt" # linear backoff: 1s, 2s
      attempt=$((attempt + 1))
      continue
    fi
    printf '%s' "$err"
    return 1
  done
}

for id in "$@"; do
  [ -z "$id" ] && continue
  if err=$(resolve_one "$id"); then
    resolved_json=$(echo "$resolved_json" | jq --arg id "$id" '. + [$id]')
  else
    errors_json=$(echo "$errors_json" | jq --arg id "$id" --arg err "$err" '. + [{id: $id, error: $err}]')
    any_error=1
  fi
done

jq -nc --argjson resolved "$resolved_json" --argjson errors "$errors_json" \
  '{resolved: $resolved, errors: $errors}'

exit $any_error
