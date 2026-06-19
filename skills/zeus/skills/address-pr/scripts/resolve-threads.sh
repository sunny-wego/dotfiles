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

for id in "$@"; do
  [ -z "$id" ] && continue
  if err=$(gh api graphql \
      -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }' \
      -f id="$id" 2>&1 >/dev/null); then
    resolved_json=$(echo "$resolved_json" | jq --arg id "$id" '. + [$id]')
  else
    errors_json=$(echo "$errors_json" | jq --arg id "$id" --arg err "$err" '. + [{id: $id, error: $err}]')
    any_error=1
  fi
done

jq -nc --argjson resolved "$resolved_json" --argjson errors "$errors_json" \
  '{resolved: $resolved, errors: $errors}'

exit $any_error
