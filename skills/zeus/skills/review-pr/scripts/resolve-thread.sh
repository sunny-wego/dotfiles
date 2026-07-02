#!/usr/bin/env bash
# resolve-thread.sh — close the loop on ONE prior review thread: post a reply with
# the re-review verdict and, when the finding is verified fixed, mark the thread
# resolved. This is the ONLY place review-pr writes to a thread it previously
# opened. The VERDICT is the LLM's (gated on a re-verification per
# review-contract.md); this script just executes it — it never reads or edits code.
#
# Usage:
#   resolve-thread.sh --comment-id <dbid> --thread-id <node_id> --body-file <f> [--resolve]
#     --comment-id  root comment's databaseId (reply target)  [from $PRIOR_FILE]
#     --thread-id   thread node id (required with --resolve)   [from $PRIOR_FILE]
#     --body-file   file holding the reply markdown (the verdict + fresh evidence)
#     --resolve     finding verified fixed/moot → mark the thread resolved.
#                   Omit for a still-open / can't-confirm verdict: reply only,
#                   leave the thread OPEN for the author.
# Reads owner/repo/number from $PR_FILE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

comment_id="" thread_id="" body_file="" resolve=false
while [ $# -gt 0 ]; do
  case "$1" in
    --comment-id) comment_id="${2:?}"; shift 2 ;;
    --thread-id)  thread_id="${2:?}";  shift 2 ;;
    --body-file)  body_file="${2:?}";  shift 2 ;;
    --resolve)    resolve=true; shift ;;
    *) shift ;;
  esac
done
[ -f "$PR_FILE" ] || { echo "resolve-thread: missing $PR_FILE" >&2; exit 2; }
{ [ -n "$comment_id" ] && [ -n "$body_file" ] && [ -f "$body_file" ]; } || {
  echo "resolve-thread: need --comment-id and --body-file <existing file>" >&2; exit 2; }
owner=$(jq -r .owner "$PR_FILE"); repo=$(jq -r .repo "$PR_FILE"); number=$(jq -r .number "$PR_FILE")

# Sign the re-verify reply with the zeus origin tag (idempotent; best-effort — a
# missing/failed helper leaves the body as-is). Every human-facing message review-pr
# originates carries `_via `zeus:review-pr`_`; this thread reply is one of them.
bash "$SCRIPT_DIR/watermark.sh" review-pr --in-place "$body_file" 2>/dev/null || true

# 1. Reply in-thread with the verdict.
gh api "repos/$owner/$repo/pulls/$number/comments/$comment_id/replies" \
  -f body="$(cat "$body_file")" --jq '{replied: .html_url}'

# 2. Resolve — only when the finding is verified fixed/moot.
if [ "$resolve" = "true" ]; then
  [ -n "$thread_id" ] || { echo "resolve-thread: --resolve needs --thread-id" >&2; exit 2; }
  gh api graphql -f tid="$thread_id" -f query='
    mutation($tid:ID!){ resolveReviewThread(input:{threadId:$tid}){ thread { isResolved } } }' \
    --jq '{resolved: .data.resolveReviewThread.thread.isResolved}'
fi
