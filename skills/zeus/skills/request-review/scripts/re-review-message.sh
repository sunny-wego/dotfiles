#!/usr/bin/env bash
# re-review-message.sh <pr_number> <owner/repo>
#
# Emit a threaded re-review ping for the PR's CODE OWNERS when the head has
# advanced past the SHA last reviewed and the PR is ready again. The script only
# FORMATS the envelope; the agent sends it (slack_send_message with thread_ts)
# and then re-stamps via `review-thread.sh set <pr> <head_sha>`.
#
# should_send is true only when ALL hold:
#   1. the repo's auto-ping config has re_review:true
#   2. an initial ping was already sent (a stored Slack thread exists)
#   3. the readiness verdict (piped in) says the PR is ready
#   4. the head SHA has advanced past the one last reviewed
# Code owners are RE-RESOLVED for the current head, so the re-ping names whoever
# owns the changed paths now. Any other repo / no thread / no advance: no-op.
#
# Output JSON:
#   { should_send, skip_reason, mode:"re_review", channel, thread_ts,
#     head_sha, compare_base, reviewers, text }
# Exit: always 0 (should_send drives behavior).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/slack-envelope.sh"   # review_gate_base
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"              # resolve_target

resolve_target "$@"   # --pr/--repo (or positional)
pr="$PR"; repo="$REPO_SLUG"
[ -n "$pr" ] && [ -n "$repo" ] || {
  echo "usage: re-review-message.sh --pr <n> [--repo <owner/repo>] (--from <file>|--from-stdin)" >&2; exit 2; }

# Verdict-agnostic: the readiness verdict is provided by the arbiter (e.g.
# address-pr's ready-for-review.sh), not computed here. Pipe it in.
ready_json=""
if [ "${#REST[@]}" -gt 0 ]; then set -- "${REST[@]}"; else set --; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --from)        ready_json="$(cat "$2")"; shift 2 ;;
    --from-stdin)  ready_json="$(cat)"; shift ;;
    *) echo "re-review-message: unknown arg $1" >&2; exit 2 ;;
  esac
done

skip() { jq -nc --arg r "$1" '{should_send:false, skip_reason:$r, mode:"re_review"}'; exit 0; }

[ -n "$ready_json" ] || { echo "re-review-message: needs a readiness verdict via --from <file> or --from-stdin" >&2; exit 2; }
echo "$ready_json" | jq -e . >/dev/null 2>&1 || { echo "re-review-message: invalid verdict JSON" >&2; exit 2; }

# 1. Per-repo re-review policy.
ap=$(bash "$SCRIPT_DIR/auto-ping.sh" "$repo")
[ "$(echo "$ap" | jq -r '.re_review')" = "true" ] || skip "re_review_disabled"

# 2. A prior ping thread must exist, so the re-review threads under it. Codeowners
# threads are always owner-directed, so there is no "is this my thread?" gate.
jr=$(bash "$SCRIPT_DIR/review-thread.sh" get "$pr" 2>/dev/null || echo '{}')
thread_ts=$(echo "$jr" | jq -r '.thread_ts // empty')
last_sha=$(echo "$jr"  | jq -r '.sha // empty')
channel=$(echo "$jr"   | jq -r '.channel // empty')
[ -n "$thread_ts" ] || skip "no_initial_ping"

# 3-4. Shared ready-gate + per-SHA dedup (same decision as the initial ping),
# using the verdict piped in above.
ready=$(echo "$ready_json" | jq -r '.ready // false')
head_sha=$(echo "$ready_json" | jq -r '.head_sha // empty')
[ -n "$head_sha" ] || skip "no_head_sha"
case "$(review_gate_base "$ready" "$last_sha" "$head_sha")" in
  not_ready)  skip "not_ready" ;;
  already:*)  skip "already_requested_at_${last_sha:0:7}" ;;
esac

# Delta since the last review, to focus the re-review.
commits=$(git rev-list --count "${last_sha}..${head_sha}" 2>/dev/null || echo "?")
files=$(git diff --name-only "${last_sha}..${head_sha}" 2>/dev/null | grep -c . || true)
compare_url="https://github.com/${repo}/compare/${last_sha}...${head_sha}"

# Re-resolve the code owners for the CURRENT head — the changed-path set may have
# moved the owners. Best-effort: a probe failure leaves an empty mention.
reviewers='[]'
set +e
reviewers=$(bash "$SCRIPT_DIR/resolve-reviewers.sh" "$pr" "$repo" 2>/dev/null)
set -e
echo "$reviewers" | jq -e 'type == "array"' >/dev/null 2>&1 || reviewers='[]'
mention=$(echo "$reviewers" | jq -r '[.[] | .display] | join(" ")')

text=$(jq -nr --arg m "$mention" --arg ls "${last_sha:0:7}" --arg hs "${head_sha:0:7}" \
   --arg commits "$commits" --arg files "$files" --arg url "$compare_url" \
  '(if $m != "" then $m + " " else "" end) +
   "please re-review and approve — updated since the last review (`" + $ls + "` → `" + $hs + "`, " +
   $commits + " commits, " + $files + " files). diff: " + $url')
# Sign the threaded re-review ping with the zeus origin tag (idempotent, best-effort).
text="$(printf '%s' "$text" | bash "$SCRIPT_DIR/watermark.sh" request-review - 2>/dev/null || printf '%s' "$text")"

jq -nc --arg ch "$channel" --arg th "$thread_ts" --arg hs "$head_sha" \
       --arg cb "$last_sha" --argjson rv "$reviewers" --arg tx "$text" \
  '{should_send:true, skip_reason:null, mode:"re_review",
    channel:$ch, thread_ts:$th, head_sha:$hs, compare_base:$cb, reviewers:$rv, text:$tx}'
