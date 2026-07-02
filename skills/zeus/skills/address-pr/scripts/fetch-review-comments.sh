#!/usr/bin/env bash
# Unified fetch of ALL review comments for a PR.
# Outputs a single JSON object with 5 keys:
#   threads, reviews, inline_comments, conversation_comments, consistency
#
# consistency:
#   { ok: bool, reason: string, graphql_thread_total: int,
#     graphql_thread_fetched: int, rest_thread_roots: int }
#
# `ok == false` means GraphQL's reviewThreads index is behind REST's
# review-comments list (eventual consistency). The data in this payload
# is stale and the caller SHOULD retry. This was the silent-staleness
# failure mode observed on PR #501: Codex posted a review comment, REST
# saw it, GraphQL reviewThreads did not yet reflect it, and the final
# sweep reported 0 unresolved and declared done.
#
# Usage:
#   fetch-review-comments.sh --pr <n> [--repo <owner/repo>]   (identifiers also positional)
#
# Returns comments from ALL authors (bots + humans). Consumers filter in
# memory if they need a per-author slice — this script is
# author-agnostic by design.
#
# Unified comment shape across all buckets: every comment exposes `user` (login
# string), `created_at` / `updated_at`, and a numeric REST id — `databaseId` on
# thread comments, `id` on the REST buckets — so one selector works everywhere
# and a thread reply has its REST id (`databaseId`) in hand without a follow-up
# `gh api` call.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# Identifiers via the shared parser (lib.sh resolve_target): --pr/--repo, or
# positional in ANY order (a bare number is the PR, a bare owner/repo is the
# repo); the repo defaults to the current checkout via gh. resolve_target keeps
# the order-agnostic tolerance this script was written for, while enforcing the
# house rule that a repo is ALWAYS one `owner/repo` slug — the split
# `<owner> <repo>` form is intentionally not accepted.
resolve_target "$@"
pr="$PR"; owner="$OWNER"; repo="$REPO_NAME"
[ -n "$pr" ] && [ -n "$owner" ] && [ -n "$repo" ] || \
  usage_exit "usage: fetch-review-comments.sh --pr <n> [--repo <owner/repo>]   (identifiers also positional)"

# Per-bucket temp files under $STATE_DIR (per-worktree, isolated).
# Switched from shell-variable capture + `jq --argjson` to file-based
# input + `jq --slurpfile` because PRs with many reviewers can produce
# multi-hundred-KB JSON per bucket; combined argv blew past macOS's 1MB
# ARG_MAX and the script exited non-zero with empty stdout, silently
# starving every caller (handlers/reviews.md, monitor-probe.sh).
THREADS_TMP="$STATE_DIR/.fetch-threads.json"
THREADS_ALL_TMP="$STATE_DIR/.fetch-threads-all.json"
THREADS_PAGE_TMP="$STATE_DIR/.fetch-threads-page.json"
THREADS_NEXT_TMP="$STATE_DIR/.fetch-threads-next.json"
REVIEWS_TMP="$STATE_DIR/.fetch-reviews.json"
INLINE_TMP="$STATE_DIR/.fetch-inline.json"
CONV_TMP="$STATE_DIR/.fetch-conv.json"
trap 'rm -f "$THREADS_TMP" "$THREADS_ALL_TMP" "$THREADS_PAGE_TMP" "$THREADS_NEXT_TMP" "$REVIEWS_TMP" "$INLINE_TMP" "$CONV_TMP"' EXIT

# A. GraphQL: unresolved review threads + index totalCount. totalCount is
# used below to cross-check against REST's root-comment count. Threads are
# paginated so large PRs do not silently drop unresolved feedback after the
# first 100 review threads.
echo '[]' > "$THREADS_ALL_TMP"
gql_thread_total=0
comment_pages_truncated=false
after=""

while :; do
  gql_args=(-f owner="$owner" -f repo="$repo" -F pr="$pr")
  if [ -n "$after" ]; then
    gql_args+=(-f after="$after")
  fi

  gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $after) {
          totalCount
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            isResolved
            comments(first: 50) {
              totalCount
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                fullDatabaseId
                body
                path
                line
                createdAt
                updatedAt
                author { login }
              }
            }
          }
        }
      }
    }
  }
' "${gql_args[@]}" > "$THREADS_PAGE_TMP"

  gql_thread_total=$(jq -er '.data.repository.pullRequest.reviewThreads.totalCount' "$THREADS_PAGE_TMP")
  jq -s '.[0] + (.[1].data.repository.pullRequest.reviewThreads.nodes // [])' \
    "$THREADS_ALL_TMP" "$THREADS_PAGE_TMP" > "$THREADS_NEXT_TMP"
  mv "$THREADS_NEXT_TMP" "$THREADS_ALL_TMP"

  if jq -e 'any(.data.repository.pullRequest.reviewThreads.nodes[]?; (.isResolved == false and .comments.pageInfo.hasNextPage == true))' "$THREADS_PAGE_TMP" >/dev/null; then
    comment_pages_truncated=true
  fi

  has_next=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' "$THREADS_PAGE_TMP")
  if [ "$has_next" != "true" ]; then
    break
  fi

  after=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' "$THREADS_PAGE_TMP")
  if [ -z "$after" ]; then
    break
  fi
done

# Keep only unresolved threads, and NORMALIZE each comment node to the same
# shape the REST buckets use: `user` (login string, not GraphQL author{login}),
# `databaseId` (the numeric REST id from fullDatabaseId — what queue-reply needs,
# so a thread reply costs zero extra gh api calls), and snake_case timestamps.
# One selector (`user`, `databaseId`, `created_at`) now works across all buckets.
jq '[.[] | select(.isResolved == false)
     | .comments.nodes |= map({
         id,
         databaseId: .fullDatabaseId,
         user: (.author.login // null),
         body, path, line,
         created_at: .createdAt,
         updated_at: .updatedAt
       })]' "$THREADS_ALL_TMP" > "$THREADS_TMP"
gql_thread_fetched=$(jq 'length' "$THREADS_ALL_TMP")

# B. REST: all reviews with non-empty body
gh api --paginate "repos/$owner/$repo/pulls/$pr/reviews" \
  --jq '[.[] | select(.body != "") | {id: .id, user: .user.login, state: .state, body: .body, commit_id: .commit_id, submitted_at: .submitted_at}]' \
  | jq -s 'add // []' > "$REVIEWS_TMP"

# C. REST: all inline comments. `in_reply_to_id` is needed for the
# consistency cross-check — a top-level (root) inline comment has
# in_reply_to_id IS NULL and corresponds 1:1 to a review thread.
gh api --paginate "repos/$owner/$repo/pulls/$pr/comments" \
  --jq '[.[] | {id: .id, user: .user.login, path: .path, line: .line, body: .body, in_reply_to_id: .in_reply_to_id, diff_hunk: .diff_hunk, created_at: .created_at, updated_at: .updated_at}]' \
  | jq -s 'add // []' > "$INLINE_TMP"

# D. REST: all conversation comments
gh api --paginate "repos/$owner/$repo/issues/$pr/comments" \
  --jq '[.[] | {id: .id, user: .user.login, body: .body, created_at: .created_at, updated_at: .updated_at}]' \
  | jq -s 'add // []' > "$CONV_TMP"

# E. Cross-validate GraphQL vs REST. Every review thread has exactly
# one root inline comment (in_reply_to_id IS NULL). REST sees new
# comments immediately; GraphQL reviewThreads indexer can lag by
# tens of seconds. If REST has more roots than GraphQL has threads,
# the GraphQL payload in this response is stale.
rest_thread_roots=$(jq '[.[] | select(.in_reply_to_id == null)] | length' "$INLINE_TMP")

consistency_ok="true"
consistency_reason=""
consistency_reasons=()
if [ "$rest_thread_roots" -gt "$gql_thread_total" ]; then
  consistency_ok="false"
  consistency_reasons+=("GraphQL reviewThreads stale: REST reports $rest_thread_roots root inline comments, GraphQL reports $gql_thread_total threads")
fi
if [ "$gql_thread_total" -gt "$gql_thread_fetched" ]; then
  consistency_ok="false"
  consistency_reasons+=("GraphQL reviewThreads incomplete: fetched $gql_thread_fetched of $gql_thread_total threads")
fi
if [ "$comment_pages_truncated" = true ]; then
  consistency_ok="false"
  consistency_reasons+=("GraphQL reviewThread comments truncated at 50 comments for at least one thread")
fi

if [ "${#consistency_reasons[@]}" -gt 0 ]; then
  consistency_reason=$(printf '%s\n' "${consistency_reasons[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | join("; ")' -r)
  # Warn on stderr. Callers using the JSON output should check
  # .consistency.ok; this stderr line surfaces the issue when the
  # script is invoked interactively.
  echo "WARN fetch-review-comments: $consistency_reason" >&2
fi

jq -n \
  --slurpfile threads "$THREADS_TMP" \
  --slurpfile reviews "$REVIEWS_TMP" \
  --slurpfile inline_comments "$INLINE_TMP" \
  --slurpfile conversation_comments "$CONV_TMP" \
  --arg consistency_ok "$consistency_ok" \
  --arg consistency_reason "$consistency_reason" \
  --argjson gql_thread_total "$gql_thread_total" \
  --argjson gql_thread_fetched "$gql_thread_fetched" \
  --argjson rest_thread_roots "$rest_thread_roots" \
  '{
    threads: $threads[0],
    reviews: $reviews[0],
    inline_comments: $inline_comments[0],
    conversation_comments: $conversation_comments[0],
    consistency: {
      ok: ($consistency_ok == "true"),
      reason: $consistency_reason,
      graphql_thread_total: $gql_thread_total,
      graphql_thread_fetched: $gql_thread_fetched,
      rest_thread_roots: $rest_thread_roots
    }
  }'
