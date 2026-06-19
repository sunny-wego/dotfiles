#!/usr/bin/env bash
# Summarize a fetch-review-comments.sh payload into a compact triage digest.
#
# Usage:
#   review-digest.sh <reviews_json> [excerpt_chars]
#
# Output:
#   {
#     counts: {threads, reviews, inline_comments, conversation_comments},
#     consistency: {...},
#     items: [
#       {
#         bucket, id, author, path, line, updated_at,
#         body_chars, body_excerpt,
#         has_suggestion, has_ai_prompt, has_question,
#         selector
#       }
#     ]
#   }

set -euo pipefail

reviews_file="${1:?Usage: review-digest.sh <reviews_json> [excerpt_chars]}"
excerpt_chars="${2:-360}"

case "$excerpt_chars" in
  ''|*[!0-9]*)
    echo "excerpt_chars must be a positive integer" >&2
    exit 1
    ;;
esac

jq --argjson excerpt "$excerpt_chars" '
  def text($body): ($body // "");
  def compact($body):
    text($body)
    | gsub("[[:space:]]+"; " ")
    | if length > $excerpt then .[0:$excerpt] + "..." else . end;
  def flags($body): {
    body_chars: (text($body) | length),
    body_excerpt: compact($body),
    has_suggestion: (text($body) | test("```suggestion"; "i")),
    has_ai_prompt: (text($body) | test("Prompt for AI Agents"; "i")),
    has_question: (text($body) | test("\\?"))
  };

  (.threads // []) as $threads |
  (.reviews // []) as $reviews |
  (.inline_comments // []) as $inline |
  (.conversation_comments // []) as $conversation |
  {
    counts: {
      threads: ($threads | length),
      reviews: ($reviews | length),
      inline_comments: ($inline | length),
      conversation_comments: ($conversation | length)
    },
    consistency: (.consistency // {ok: true, reason: ""}),
    items:
      (
        [
          $threads[] |
          (.comments.nodes[0] // {}) as $c |
          {
            bucket: "threads",
            id: .id,
            thread_id: .id,
            comment_id: ($c.databaseId // null),
            author: ($c.user // null),
            path: ($c.path // null),
            line: ($c.line // null),
            created_at: ($c.created_at // null),
            updated_at: ($c.updated_at // null),
            comments_count: (.comments.totalCount // (.comments.nodes | length)),
            comments_truncated: ((.comments.totalCount // 0) > ((.comments.nodes // []) | length)),
            selector: {bucket: "threads", thread_id: .id, comment_id: ($c.databaseId // null)}
          } + flags($c.body)
        ] +
        [
          $reviews[] |
          {
            bucket: "reviews",
            id: .id,
            review_id: .id,
            author: (.user // null),
            state: (.state // null),
            submitted_at: (.submitted_at // null),
            updated_at: (.submitted_at // null),
            commit_id: (.commit_id // null),
            selector: {bucket: "reviews", review_id: .id}
          } + flags(.body)
        ] +
        [
          $inline[] |
          {
            bucket: "inline_comments",
            id: .id,
            comment_id: .id,
            author: (.user // null),
            path: (.path // null),
            line: (.line // null),
            in_reply_to_id: (.in_reply_to_id // null),
            created_at: (.created_at // null),
            updated_at: (.updated_at // .created_at // null),
            selector: {bucket: "inline_comments", comment_id: .id}
          } + flags(.body)
        ] +
        [
          $conversation[] |
          {
            bucket: "conversation_comments",
            id: .id,
            comment_id: .id,
            author: (.user // null),
            created_at: (.created_at // null),
            updated_at: (.updated_at // .created_at // null),
            selector: {bucket: "conversation_comments", comment_id: .id}
          } + flags(.body)
        ]
      )
  }
' "$reviews_file"
