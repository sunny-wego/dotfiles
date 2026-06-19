#!/usr/bin/env bash
# Snapshot PR check status + merge state.
# Outputs JSON: { checks, mergeable, merge_state_status, behind_base, head_sha, all_passed, failed, pending }
#
# Usage: pr-status.sh --pr <n>   (a bare number is also accepted)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

resolve_pr "$@"
pr="${PR:?Usage: pr-status.sh --pr <n>}"

# All checks as structured JSON
checks=$(gh pr checks "$pr" --json name,state,link \
  --jq '[.[] | {name: .name, state: .state, url: .link}]')

# Merge state + head SHA (retry UNKNOWN up to 3 times)
pr_data=$(gh pr view "$pr" --json mergeable,headRefOid,mergeStateStatus \
  -q '{mergeable: .mergeable, head_sha: .headRefOid, merge_state_status: .mergeStateStatus}')
mergeable=$(echo "$pr_data" | jq -r '.mergeable')
head_sha=$(echo "$pr_data" | jq -r '.head_sha')
merge_state_status=$(echo "$pr_data" | jq -r '.merge_state_status')

retries=0
while [ "$mergeable" = "UNKNOWN" ] && [ "$retries" -lt 3 ]; do
  sleep 5
  pr_refresh=$(gh pr view "$pr" --json mergeable,mergeStateStatus \
    -q '{mergeable: .mergeable, merge_state_status: .mergeStateStatus}')
  mergeable=$(echo "$pr_refresh" | jq -r '.mergeable')
  merge_state_status=$(echo "$pr_refresh" | jq -r '.merge_state_status')
  retries=$((retries + 1))
done

# Detect branch behind base — GitHub's mergeStateStatus="BEHIND" is only set
# when branch protection requires "up to date". Fall back to git rev-list count
# against the base branch so we catch it regardless of protection settings.
fetch_error=""
if [ "$merge_state_status" = "BEHIND" ]; then
  behind_base=true
else
  base_branch=$(gh pr view "$pr" --json baseRefName -q '.baseRefName')
  if ! fetch_error=$(git fetch origin "$base_branch" --quiet 2>&1); then
    : # fetch failed — surface in output so loop can decide
  fi
  behind_count=$(git rev-list --count HEAD.."origin/$base_branch" 2>/dev/null || echo "0")
  behind_base=$([ "$behind_count" -gt 0 ] && echo "true" || echo "false")
fi

# Derived fields
all_passed=$(echo "$checks" | jq '[.[] | select(.state != "SUCCESS" and .state != "SKIPPED" and .state != "NEUTRAL")] | length == 0')
failed=$(echo "$checks" | jq '[.[] | select(.state == "FAILURE") | .name]')
pending=$(echo "$checks" | jq '[.[] | select(.state == "PENDING")] | length')

# Live approval on the current head (stateless — recomputed every pass, no
# per-reviewer/per-PR list is persisted anywhere). True iff some NON-author
# reviewer's LATEST review is APPROVED *and* was submitted against the current
# head SHA (commit_id == head_sha, so a stale pre-push approval doesn't count).
# This is the generic "generally agreed in a comment" signal: the drive loop
# uses it to stop sweeping nitpicks, because every nit commit would dismiss the
# approval and force a re-review (see evaluate-iteration.sh rule 1).
#
# Author-agnostic by construction — it keys off GitHub's universal APPROVED
# state, never a specific reviewer login, so any number of reviewers is handled
# without bookkeeping. Fail-open to false: a flaky reviews fetch must NEVER
# block driving, so any error here leaves the loop in its normal (sweeping)
# behavior rather than wedging it.
approved_at_head=false
nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
if [ -n "$nwo" ]; then
  pr_author=$(gh pr view "$pr" --json author -q '.author.login' 2>/dev/null || echo "")
  reviews_json=$(gh api --paginate "repos/$nwo/pulls/$pr/reviews" \
      --jq '[.[] | {user: .user.login, state, commit_id, submitted_at}]' 2>/dev/null \
      | jq -s 'add // []' 2>/dev/null || echo '[]')
  approved_at_head=$(echo "$reviews_json" | jq -r --arg sha "$head_sha" --arg author "$pr_author" '
      [ .[] | select(.user != null and .user != $author) ]
      | group_by(.user)
      | map(max_by(.submitted_at) | (.state == "APPROVED" and .commit_id == $sha))
      | any' 2>/dev/null || echo false)
  [ "$approved_at_head" = "true" ] || approved_at_head=false
fi

jq -n \
  --argjson checks "$checks" \
  --arg mergeable "$mergeable" \
  --arg merge_state_status "$merge_state_status" \
  --argjson behind_base "$behind_base" \
  --arg head_sha "$head_sha" \
  --argjson all_passed "$all_passed" \
  --argjson failed "$failed" \
  --argjson pending "$pending" \
  --argjson approved_at_head "$approved_at_head" \
  --arg fetch_error "$fetch_error" \
  '{checks: $checks, mergeable: $mergeable, merge_state_status: $merge_state_status, behind_base: $behind_base, head_sha: $head_sha, all_passed: $all_passed, failed: $failed, pending: $pending, approved_at_head: $approved_at_head}
   + if $fetch_error != "" then {fetch_error: $fetch_error} else {} end'
