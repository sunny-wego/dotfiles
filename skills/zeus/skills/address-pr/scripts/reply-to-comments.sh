#!/usr/bin/env bash
# Batch-reply to inline review comments. One script invocation replaces N LLM tool calls.
#
# Usage:
#   reply-to-comments.sh --pr <n> --repo <owner/repo> [--from <pairs.json>|-]
#   (identifiers also positional; --from defaults to `-` / stdin.)
#
# pairs.json — array of {comment_id, body} objects (passed via --from as a file
# path OR as `-` to read from stdin; stdin is the default).
#
# Example pairs.json:
#   [
#     {"comment_id": 12345, "body": "Fixed — extracted helper."},
#     {"comment_id": 12346, "body": "Not addressing: intentional approach."}
#   ]
#
# Outputs JSON: { "replied": [<id>, ...], "errors": [{"id": <id>, "error": "..."}] }
# Exit code: 0 if all replied, 1 if any errors.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"; set +e  # lib enables errexit; this script handles errors inline

resolve_target "$@"
owner="$OWNER"; repo="$REPO_NAME"; pr="$PR"
[ -n "$pr" ] && [ -n "$REPO_SLUG" ] || {
  echo "Usage: reply-to-comments.sh --pr <n> --repo <owner/repo> [--from <pairs.json>|-]" >&2; exit 2; }
pairs_src="-"
if [ "${#REST[@]}" -gt 0 ]; then set -- "${REST[@]}"; else set --; fi
while [ $# -gt 0 ]; do case "$1" in
  --from)   pairs_src="${2:?--from needs a value}"; shift 2 ;;
  --from=*) pairs_src="${1#*=}"; shift ;;
  *)        pairs_src="$1"; shift ;;
esac; done

if [ "$pairs_src" = "-" ]; then
  pairs=$(cat)
else
  pairs=$(cat "$pairs_src")
fi

replied="[]"
errors="[]"
any_error=0

SIGNOFF=$'\n\n_via `zeus:address-pr`_'

count=$(echo "$pairs" | jq 'length')
# C-style loop, NOT `seq 0 $((count-1))`: on BSD/macOS `seq 0 -1` counts down to
# "0 -1" (two values), so an empty payload would try two null-id replies.
for ((i = 0; i < count; i++)); do
  id=$(echo "$pairs" | jq -r ".[$i].comment_id")
  body=$(echo "$pairs" | jq -r ".[$i].body")

  case "$body" in
    *"_via \`zeus:address-pr\`_"*) ;;
    *) body="${body}${SIGNOFF}" ;;
  esac

  if err=$(gh api "repos/$owner/$repo/pulls/$pr/comments" \
      --method POST \
      --field body="$body" \
      --field in_reply_to="$id" 2>&1 >/dev/null); then
    replied=$(echo "$replied" | jq --argjson id "$id" '. + [$id]')
  else
    errors=$(echo "$errors" | jq --argjson id "$id" --arg err "$err" '. + [{id: $id, error: $err}]')
    any_error=1
  fi
done

jq -nc --argjson replied "$replied" --argjson errors "$errors" \
  '{replied: $replied, errors: $errors}'

exit $any_error
