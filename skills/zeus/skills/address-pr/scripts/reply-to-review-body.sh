#!/usr/bin/env bash
# Batch-post replies to PR review bodies and conversation comments.
# Both use GitHub's flat issue-comments resource (no native threading for
# either), so a reply only reads as a reply if it NAMES who it answers.
#
# Addressing is guaranteed here, not left to the caller: when an item carries a
# `source_id` (the conversation comment it answers), this script looks up that
# comment's author and prepends an `@author` mention unless the body already
# names them. This is what makes a reply land as an actual reply instead of a
# context-free top-level comment — and it's what triggers bot reviewers
# (CodeRabbit, Codex), which only act on an @mention, so an "open an issue" /
# "accept" reply isn't silently inert. Items without a `source_id` (e.g. a
# review-submission body) post as-is; pre-format those with a manual
# `> [reply to @<reviewer>'s review]` header.
#
# Usage:
#   reply-to-review-body.sh --pr <n> --repo <owner/repo> [--from <bodies.json>|-]
#   (identifiers also positional; --from defaults to `-` / stdin.)
#
# bodies.json — array of {body, source_id?} objects (via --from: file path or `-` for stdin):
#   [
#     {"body": "Yes, please open an issue to track this.", "source_id": 4646250403},
#     {"body": "> [reply to @coderabbitai's review]\n\nFixed — ..."}
#   ]
# Only a `[reply to @…]` header is `>`-prefixed; the reply body stays unquoted,
# otherwise GitHub renders the whole comment as one blockquote.
#
# Outputs JSON: { "posted": [<comment_id>, ...], "errors": [{"index": N, "error": "..."}] }
# Exit code: 0 if all posted, 1 if any errors.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"; set +e  # lib enables errexit; this script handles errors inline

resolve_target "$@"
owner="$OWNER"; repo="$REPO_NAME"; pr="$PR"
[ -n "$pr" ] && [ -n "$REPO_SLUG" ] || {
  echo "Usage: reply-to-review-body.sh --pr <n> --repo <owner/repo> [--from <bodies.json>|-]" >&2; exit 2; }
bodies_src="-"
if [ "${#REST[@]}" -gt 0 ]; then set -- "${REST[@]}"; else set --; fi
while [ $# -gt 0 ]; do case "$1" in
  --from)   bodies_src="${2:?--from needs a value}"; shift 2 ;;
  --from=*) bodies_src="${1#*=}"; shift ;;
  *)        bodies_src="$1"; shift ;;
esac; done

if [ "$bodies_src" = "-" ]; then
  bodies=$(cat)
else
  bodies=$(cat "$bodies_src")
fi

posted="[]"
errors="[]"
any_error=0

SIGNOFF=$'\n\n_via `zeus:address-pr`_'

count=$(echo "$bodies" | jq 'length')
# C-style loop, NOT `seq 0 $((count-1))`: on BSD/macOS `seq 0 -1` counts down to
# "0 -1" (two values), so an empty payload would post two null-body comments.
for ((i = 0; i < count; i++)); do
  body=$(echo "$bodies" | jq -r ".[$i].body")
  source_id=$(echo "$bodies" | jq -r ".[$i].source_id // empty")

  # Guarantee the reply names who it answers (see header). `source_id` is either
  # an issue-comment id (conversation_comments bucket) OR a PR review id (reviews
  # bucket) — different id spaces, so try both resources. Keep the result only if
  # it parses as a GitHub login: on a 404 `gh api` prints the error body to
  # stdout, and that JSON must never leak into the @mention (a body then starting
  # with `@{...}` also breaks the POST below). A miss falls through to posting the
  # body unchanged rather than blocking the flush.
  if [ -n "$source_id" ]; then
    author=""
    for ep in "issues/comments/$source_id" "pulls/$pr/reviews/$source_id"; do
      cand=$(gh api "repos/$owner/$repo/$ep" --jq '.user.login' 2>/dev/null) || continue
      if printf '%s' "$cand" | grep -qE '^[A-Za-z0-9._-]+(\[bot\])?$'; then
        author="$cand"; break
      fi
    done
    if [ -n "$author" ]; then
      mention="${author%"[bot]"}"   # the @handle drops GitHub's [bot] suffix
      case "$body" in
        *"@$mention"*) ;;            # already addressed — don't double-prepend
        *) body="@$mention ${body}" ;;
      esac
    fi
  fi

  case "$body" in
    *"_via \`zeus:address-pr\`_"*) ;;
    *) body="${body}${SIGNOFF}" ;;
  esac

  # --raw-field (not --field): never interpret the value, so a body that legitimately
  # starts with "@mention" isn't mistaken for an "@file" reference by gh.
  if out=$(gh api "repos/$owner/$repo/issues/$pr/comments" \
      --method POST \
      --raw-field body="$body" 2>&1); then
    id=$(echo "$out" | jq -r '.id // empty')
    posted=$(echo "$posted" | jq --argjson id "${id:-0}" '. + [$id]')
  else
    errors=$(echo "$errors" | jq --argjson i "$i" --arg err "$out" '. + [{index: $i, error: $err}]')
    any_error=1
  fi
done

jq -nc --argjson posted "$posted" --argjson errors "$errors" \
  '{posted: $posted, errors: $errors}'

exit $any_error
