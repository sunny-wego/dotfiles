#!/usr/bin/env bash
# State/telemetry helpers. Each handler appends its outcome per iteration;
# report.sh renders the final summary from this log.
#
# Usage:
#   state.sh init <pr_number> <branch> <base>       # fresh run, clobbers stale local state + temp files
#   state.sh iteration                              # print current iteration (0-based)
#   state.sh bump-iteration                         # increment and print new iteration
#   state.sh append <handler-name> <json>           # append handler outcome JSON to current iteration
#   state.sh read                                   # print full state JSON
#   state.sh clear                                  # clear telemetry + temp files from this worktree
#
# Reply/resolve queue (handlers stage post-push work here so replies cite
# the just-pushed SHA, not a pre-push promise):
#   state.sh queue-reply <json>                     # append {comment_id, body} for inline-thread reply
#   state.sh queue-review-body-reply <json>         # append {body, source_id?} for review-body / conversation reply
#   state.sh queue-resolve <thread_id>              # append a thread id to resolve
#   state.sh queue-reaction <json>                  # append {target_type: "inline"|"issue", target_id} for post-push 👍
#   state.sh flush-queue                            # atomically read+clear the queue, print combined JSON

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cmd="${1:?Usage: state.sh <init|iteration|bump-iteration|append|read|clear|queue-reply|queue-review-body-reply|queue-resolve|queue-reaction|flush-queue> ...}"

ensure_queue() {
  [ -f "$STATE_FILE" ] || { echo "state file missing — run state.sh init first" >&2; exit 1; }
  # Lazy-init the queue object if missing (state may have been initialised
  # before queue support shipped).
  if ! jq -e 'has("queue")' "$STATE_FILE" >/dev/null 2>&1; then
    tmp="$STATE_FILE.tmp"
    jq '. + {queue: {replies: [], review_body_replies: [], resolves: [], reactions: []}}' \
      "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
  fi
  # Lazy-add reactions for state files initialised before reaction support.
  if ! jq -e '.queue | has("reactions")' "$STATE_FILE" >/dev/null 2>&1; then
    tmp="$STATE_FILE.tmp"
    jq '.queue.reactions = []' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
  fi
}

# Serialize mutating commands so concurrent invocations can't lose updates
# (read commands — iteration/read — need no lock).
case "$cmd" in
  init|bump-iteration|append|clear|queue-reply|queue-review-body-reply|queue-resolve|queue-reaction|flush-queue)
    with_lock "$STATE_FILE.lock" ;;
esac

case "$cmd" in
  init)
    pr="${2:?PR number required}"
    branch="${3:?branch required}"
    base="${4:?base required}"
    cleanup_run_state
    jq -n       --argjson pr "$pr"       --arg branch "$branch"       --arg base "$base"       --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"       '{pr: $pr, branch: $branch, base: $base, started_at: $started, iteration: 0, outcomes: [], queue: {replies: [], review_body_replies: [], resolves: [], reactions: []}}'       > "$STATE_FILE"
    cat "$STATE_FILE"
    ;;

  iteration)
    [ -f "$STATE_FILE" ] || { echo "state file missing — run state.sh init first" >&2; exit 1; }
    jq -r '.iteration' "$STATE_FILE"
    ;;

  bump-iteration)
    [ -f "$STATE_FILE" ] || { echo "state file missing — run state.sh init first" >&2; exit 1; }
    tmp="$STATE_FILE.tmp"
    jq '.iteration += 1' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    jq -r '.iteration' "$STATE_FILE"
    ;;

  append)
    handler="${2:?handler name required}"
    outcome="${3:?outcome JSON required}"
    [ -f "$STATE_FILE" ] || { echo "state file missing — run state.sh init first" >&2; exit 1; }
    tmp="$STATE_FILE.tmp"
    jq       --arg handler "$handler"       --argjson outcome "$outcome"       '.outcomes += [{iteration: .iteration, handler: $handler} + $outcome]'       "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  read)
    [ -f "$STATE_FILE" ] || { echo "{}"; exit 0; }
    cat "$STATE_FILE"
    ;;

  clear)
    cleanup_run_state
    ;;

  queue-reply)
    payload="${2:?inline-reply JSON required: comment_id+body}"
    ensure_queue
    # Validate that comment_id lives in the inline_comments bucket of the
    # most recent reviews fetch. Posting an inline reply against an
    # issue-comment id (from conversation_comments / reviews buckets) is
    # the bug this guard prevents: GitHub's pulls-comments endpoint with
    # `in_reply_to=<issue_id>` returns an error at flush time, which the
    # orchestrator captures in `.commit.flush.errors` and the agent's
    # typical `jq '{action, reason}'` inspection never sees. Fail loudly
    # here so the misroute surfaces at queue time with the right fix.
    REVIEWS_FILE="$(git rev-parse --absolute-git-dir 2>/dev/null)/address-pr/reviews.json"
    if [ -f "$REVIEWS_FILE" ]; then
      cid_check=$(echo "$payload" | jq -r '.comment_id // empty')
      if [ -n "$cid_check" ]; then
        if ! jq -e --argjson cid "$cid_check" \
            'any(.inline_comments[]?; (.id|tostring) == ($cid|tostring))' \
            "$REVIEWS_FILE" >/dev/null 2>&1; then
          if jq -e --argjson cid "$cid_check" \
              'any(.conversation_comments[]?; (.id|tostring) == ($cid|tostring))' \
              "$REVIEWS_FILE" >/dev/null 2>&1; then
            echo "queue-reply: comment_id=$cid_check is a conversation comment — use queue-review-body-reply '{\"body\": \"...\", \"source_id\": $cid_check}' instead. queue-reply is for inline-thread replies (inline_comments bucket) only." >&2
            exit 1
          elif jq -e --argjson cid "$cid_check" \
              'any(.reviews[]?; (.id|tostring) == ($cid|tostring))' \
              "$REVIEWS_FILE" >/dev/null 2>&1; then
            echo "queue-reply: comment_id=$cid_check is a review body — use queue-review-body-reply '{\"body\": \"...\", \"source_id\": $cid_check}' instead. queue-reply is for inline-thread replies (inline_comments bucket) only." >&2
            exit 1
          else
            echo "queue-reply: warning: comment_id=$cid_check not found in any reviews bucket (inline_comments / conversation_comments / reviews). Continuing — possibly a freshly-fetched id not in this snapshot — but flush may fail if the id is wrong." >&2
          fi
        fi
      fi
    fi
    tmp="$STATE_FILE.tmp"
    jq --argjson r "$payload" '.queue.replies += [$r]' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  queue-review-body-reply)
    payload="${2:?review-body reply JSON required: body}"
    ensure_queue
    # Symmetric guard: if the payload carries a `source_id`, validate that
    # it's a conversation_comments or reviews bucket id (never an inline
    # comment id). queue-reply is the right route for inline_comments.
    REVIEWS_FILE="$(git rev-parse --absolute-git-dir 2>/dev/null)/address-pr/reviews.json"
    if [ -f "$REVIEWS_FILE" ]; then
      sid_check=$(echo "$payload" | jq -r '.source_id // empty')
      if [ -n "$sid_check" ]; then
        if jq -e --argjson sid "$sid_check" \
            'any(.inline_comments[]?; (.id|tostring) == ($sid|tostring))' \
            "$REVIEWS_FILE" >/dev/null 2>&1; then
          echo "queue-review-body-reply: source_id=$sid_check is an inline comment — use queue-reply '{\"comment_id\": $sid_check, \"body\": \"...\"}' instead. queue-review-body-reply is for review-body / conversation replies only." >&2
          exit 1
        fi
      fi
    fi
    tmp="$STATE_FILE.tmp"
    jq --argjson r "$payload" '.queue.review_body_replies += [$r]' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  queue-resolve)
    thread_id="${2:?thread id required}"
    ensure_queue
    tmp="$STATE_FILE.tmp"
    jq --arg id "$thread_id" '.queue.resolves += [$id]' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  queue-reaction)
    payload="${2:?reaction JSON required: target_type ('inline'|'issue') + target_id}"
    ensure_queue
    # Validate shape so a malformed payload fails fast instead of silently
    # producing a 404 at flush time.
    if ! echo "$payload" | jq -e '
      (.target_type == "inline" or .target_type == "issue")
      and (.target_id != null)
    ' >/dev/null 2>&1; then
      echo "queue-reaction: payload must be {target_type: \"inline\"|\"issue\", target_id: <id>}" >&2
      exit 1
    fi
    tmp="$STATE_FILE.tmp"
    # De-dup on (target_type, target_id) so iterating the same comment across
    # passes doesn't queue the same reaction twice. GitHub treats repeat POSTs
    # as idempotent, but skipping locally saves API calls.
    jq --argjson r "$payload" '
      .queue.reactions |= (
        if any(.[]; .target_type == $r.target_type and (.target_id|tostring) == ($r.target_id|tostring))
        then . else . + [$r] end
      )
    ' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  flush-queue)
    # Atomically read+clear the queue. Prints the queue contents that were
    # captured; subsequent calls see an empty queue. Callers (typically
    # flush-pending-replies.sh) own the side effects after that.
    ensure_queue
    tmp="$STATE_FILE.tmp"
    jq '.queue' "$STATE_FILE"
    jq '.queue = {replies: [], review_body_replies: [], resolves: [], reactions: []}' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    exit 1
    ;;
esac
