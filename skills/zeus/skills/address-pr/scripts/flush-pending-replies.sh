#!/usr/bin/env bash
# Flush the per-iteration reply/resolve queue after a successful push.
#
# Why this exists: reviewers (and bots like CodeRabbit / Codex) re-review on
# new commits, so "Fixed at <SHA>" replies are only honest after the commit
# is on the remote. If the handler posts replies before the push lands and
# the push then fails on a pre-push hook, GitHub is left with orphan
# "Fixed" claims against unchanged code. This script gates posting on a
# successful push (the caller — commit-and-push.sh — only invokes us after
# `git push` returned 0).
#
# Usage: flush-pending-replies.sh --pr <n> --repo <owner/repo> --sha <short_sha>
#   (identifiers also accepted positionally: a bare number is the PR, a bare
#    owner/repo is the repo; --sha carries the just-pushed short SHA.)
#
# Behavior:
#   1. Pulls the queue via `state.sh flush-queue` (atomic read+clear).
#   2. Substitutes `{{SHA}}` in every reply body with the provided short_sha.
#   3. Posts inline replies via reply-to-comments.sh.
#   4. Posts review-body / conversation replies via reply-to-review-body.sh.
#   5. Resolves queued thread IDs via resolve-threads.sh.
#   6. Adds 👍 (`+1`) reactions to every acted-on comment so reviewers can
#      see at a glance that the comment was looked at. `inline` targets hit
#      `repos/{o}/{r}/pulls/comments/{id}/reactions`; `issue` targets hit
#      `repos/{o}/{r}/issues/comments/{id}/reactions`. (Review submission
#      bodies aren't reactable via the GitHub API — handlers skip those.)
#      GitHub returns 200 for a pre-existing reaction and 201 for a new one;
#      both count as success, so re-runs are safe.
#
# Output JSON:
#   {
#     "replied_inline": [...comment_ids],
#     "replied_body":   [...comment_ids],
#     "resolved":       [...thread_ids],
#     "reacted":        [{"target_type": "inline"|"issue", "target_id": <id>}, ...],
#     "errors":         [{"phase": "inline"|"review_body"|"resolve"|"reaction", "detail": "..."}],
#     "counts":         {"inline": N, "review_body": N, "resolves": N, "reactions": N}
#   }
#
# Exit code: 0 if everything succeeded OR queue was empty. 1 if any post
# step returned non-zero (caller surfaces via the JSON).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"; set +e  # lib enables errexit; this script handles errors inline

resolve_target "$@"
owner="$OWNER"; repo="$REPO_NAME"; pr="$PR"; sha="$SHA"
[ -n "$pr" ] && [ -n "$REPO_SLUG" ] && [ -n "$sha" ] || {
  echo "Usage: flush-pending-replies.sh --pr <n> --repo <owner/repo> --sha <short_sha>" >&2; exit 2; }

queue=$(bash "$SCRIPT_DIR/state.sh" flush-queue)

inline_count=$(echo "$queue" | jq '.replies | length')
body_count=$(echo "$queue" | jq '.review_body_replies | length')
resolve_count=$(echo "$queue" | jq '.resolves | length')
reaction_count=$(echo "$queue" | jq '(.reactions // []) | length')

errors='[]'
replied_inline='[]'
replied_body='[]'
resolved='[]'
reacted='[]'

# Empty queue → no work to do.
if [ "$inline_count" -eq 0 ] && [ "$body_count" -eq 0 ] && [ "$resolve_count" -eq 0 ] && [ "$reaction_count" -eq 0 ]; then
  jq -nc --arg sha "$sha" \
    '{replied_inline: [], replied_body: [], resolved: [], reacted: [], errors: [],
      counts: {inline: 0, review_body: 0, resolves: 0, reactions: 0},
      sha: $sha}'
  exit 0
fi

# 1. Inline replies — substitute {{SHA}} and post.
if [ "$inline_count" -gt 0 ]; then
  inline_payload=$(echo "$queue" | jq -c --arg sha "$sha" \
    '[.replies[] | .body |= gsub("\\{\\{SHA\\}\\}"; $sha)]')
  if out=$(echo "$inline_payload" \
      | bash "$SCRIPT_DIR/reply-to-comments.sh" --pr "$pr" --repo "$owner/$repo" --from - 2>&1); then
    replied_inline=$(echo "$out" | jq -c '.replied // []')
    inline_errors=$(echo "$out" | jq -c '.errors // []')
    if [ "$(echo "$inline_errors" | jq 'length')" -gt 0 ]; then
      errors=$(jq -nc --argjson e "$errors" --argjson new "$inline_errors" \
        '$e + [$new[] | {phase: "inline", detail: .}]')
    fi
  else
    safe=$(echo "$out" | head -c 500 | jq -Rs .)
    errors=$(jq -nc --argjson e "$errors" --argjson d "$safe" \
      '$e + [{phase: "inline", detail: $d}]')
  fi
fi

# 2. Review-body / conversation replies — same substitution.
if [ "$body_count" -gt 0 ]; then
  body_payload=$(echo "$queue" | jq -c --arg sha "$sha" \
    '[.review_body_replies[] | .body |= gsub("\\{\\{SHA\\}\\}"; $sha)]')
  if out=$(echo "$body_payload" \
      | bash "$SCRIPT_DIR/reply-to-review-body.sh" --pr "$pr" --repo "$owner/$repo" --from - 2>&1); then
    replied_body=$(echo "$out" | jq -c '.posted // []')
    body_errors=$(echo "$out" | jq -c '.errors // []')
    if [ "$(echo "$body_errors" | jq 'length')" -gt 0 ]; then
      errors=$(jq -nc --argjson e "$errors" --argjson new "$body_errors" \
        '$e + [$new[] | {phase: "review_body", detail: .}]')
    fi
  else
    safe=$(echo "$out" | head -c 500 | jq -Rs .)
    errors=$(jq -nc --argjson e "$errors" --argjson d "$safe" \
      '$e + [{phase: "review_body", detail: $d}]')
  fi
fi

# 3. Resolves — batch.
if [ "$resolve_count" -gt 0 ]; then
  thread_ids=$(echo "$queue" | jq -r '.resolves[]')
  # shellcheck disable=SC2086
  if out=$(bash "$SCRIPT_DIR/resolve-threads.sh" $thread_ids 2>&1); then
    resolved=$(echo "$out" | jq -c '.resolved // []')
    resolve_errors=$(echo "$out" | jq -c '.errors // []')
    if [ "$(echo "$resolve_errors" | jq 'length')" -gt 0 ]; then
      errors=$(jq -nc --argjson e "$errors" --argjson new "$resolve_errors" \
        '$e + [$new[] | {phase: "resolve", detail: .}]')
    fi
  else
    safe=$(echo "$out" | head -c 500 | jq -Rs .)
    errors=$(jq -nc --argjson e "$errors" --argjson d "$safe" \
      '$e + [{phase: "resolve", detail: $d}]')
  fi
fi

# 4. Reactions — POST `+1` to every queued comment so reviewers see at a
# glance that the comment was looked at. Idempotent on GitHub's side; we
# also de-dup locally in state.sh queue-reaction.
if [ "$reaction_count" -gt 0 ]; then
  for i in $(seq 0 $((reaction_count - 1))); do
    tt=$(echo "$queue" | jq -r ".reactions[$i].target_type")
    tid=$(echo "$queue" | jq -r ".reactions[$i].target_id")
    case "$tt" in
      inline) endpoint="repos/$owner/$repo/pulls/comments/$tid/reactions" ;;
      issue)  endpoint="repos/$owner/$repo/issues/comments/$tid/reactions" ;;
      *)
        errors=$(jq -nc --argjson e "$errors" --arg tt "$tt" --arg tid "$tid" \
          '$e + [{phase: "reaction", detail: ("unknown target_type=" + $tt + " target_id=" + $tid)}]')
        continue
        ;;
    esac
    if react_err=$(gh api "$endpoint" \
        --method POST \
        -H "Accept: application/vnd.github+json" \
        --raw-field content=+1 2>&1 >/dev/null); then
      reacted=$(echo "$reacted" | jq --arg tt "$tt" --arg tid "$tid" \
        '. + [{target_type: $tt, target_id: $tid}]')
    else
      safe=$(echo "$react_err" | head -c 500 | jq -Rs .)
      errors=$(jq -nc --argjson e "$errors" --arg tt "$tt" --arg tid "$tid" --argjson d "$safe" \
        '$e + [{phase: "reaction", target_type: $tt, target_id: $tid, detail: $d}]')
    fi
  done
fi

jq -nc \
  --argjson ri "$replied_inline" \
  --argjson rb "$replied_body" \
  --argjson rs "$resolved" \
  --argjson rx "$reacted" \
  --argjson err "$errors" \
  --argjson ic "$inline_count" \
  --argjson bc "$body_count" \
  --argjson rc "$resolve_count" \
  --argjson xc "$reaction_count" \
  --arg sha "$sha" \
  '{replied_inline: $ri, replied_body: $rb, resolved: $rs, reacted: $rx, errors: $err,
    counts: {inline: $ic, review_body: $bc, resolves: $rc, reactions: $xc},
    sha: $sha}'

# Non-zero exit if any phase reported errors so caller can branch.
if [ "$(echo "$errors" | jq 'length')" -gt 0 ]; then
  exit 1
fi
