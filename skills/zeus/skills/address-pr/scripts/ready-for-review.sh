#!/usr/bin/env bash
# ready-for-review.sh — single-shot probe: is this PR ready for human reviewers?
#
# Runs the four predicates that, together, mean "everything automated has been
# checked and nothing is blocking a human reviewer":
#   1. PR is open and not a draft
#   2. mergeable == "MERGEABLE" and not behind base
#   3. No REQUIRED check FAILURE and no PENDING checks on head SHA. "Required" =
#      in the base branch's branch-protection / ruleset required set; a failing
#      check outside it (e.g. an advisory bot review) is a warning, not a
#      blocker. If the required set is unreadable/empty, any failure blocks
#      (conservative). A still-running check means "not settled" — pinging then
#      risks a head whose gating checks later fail.
#   4. Zero unresolved review threads + GraphQL/REST consistency is OK
#
# Emits a structured answer the agent can branch on without parsing prose.
#
# Usage:
#   ready-for-review.sh <pr_number> [<owner/repo>] [--plain]
#   ready-for-review.sh --pr <n> [--repo <owner/repo>] [--plain]
#
# Output (default JSON, --plain emits a human-readable summary instead):
#   {
#     "ready": true | false,
#     "pr_number": 456,
#     "pr_url": "https://github.com/...",
#     "title": "feat(...): ...",
#     "branch": "feat/...",
#     "head_sha": "abc123...",
#     "is_draft": false,
#     "state": "OPEN",
#     "mergeable": "MERGEABLE",
#     "behind_base": false,
#     "checks": { "passing": N, "failing": N, "pending": N, "failed_names": [...] },
#     "reviews": { "unresolved_threads": N, "consistency_ok": true },
#     "linked_issue": { "number": 123, "url": "...", "title": "..." } | null,
#     "blockers": [],    // hard reasons "ready" is false (incl. ci_pending — a
#                        // ci_pending-only set means "wait", not "escalate")
#     "warnings": []     // soft signals worth surfacing
#   }
#
# Exit codes:
#   0  ready (blockers list is empty)
#   1  not ready (one or more blockers)
#   2  probe failure (could not fetch PR data; details on stderr)
#
# Independence:
#   - journey.sh lookup is best-effort. A missing journey.json or
#     unparseable state leaves `linked_issue` as null; the readiness
#     decision is unaffected.
#   - fetch-review-comments.sh's `consistency.ok == false` is treated as
#     a blocker (`stale_review_index`) so we never declare "ready" when
#     the GraphQL index is lagging REST. The monitor probe will catch
#     up shortly.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

mode="json"
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plain) mode="plain"; shift ;;
    --json)  mode="json"; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//' >&2
      exit 0
      ;;
    *) ARGS+=("$1"); shift ;;   # --pr/--repo + positional <pr> [owner/repo] → resolve_pr
  esac
done

resolve_pr "${ARGS[@]:-}"   # identifiers via the shared parser (lib.sh), not hand-rolled
pr="$PR"; repo="$REPO_SLUG"
if [ "${#REST[@]}" -gt 0 ]; then
  echo "ready-for-review: unexpected argument: ${REST[0]}" >&2; exit 2
fi
if [ -z "$pr" ]; then
  echo "usage: ready-for-review.sh <pr_number> [<owner/repo>] [--plain]" >&2
  exit 2
fi

# --- 1. PR identity + draft/state ---------------------------------------
# shellcheck disable=SC2054  # the comma list is gh's --json field arg (one element), not array separators
pr_args=(pr view "$pr" --json number,url,title,isDraft,state,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus)
[ -n "$repo" ] && pr_args+=(--repo "$repo")

if ! pr_json=$(gh "${pr_args[@]}" 2>/dev/null); then
  echo "ready-for-review: gh pr view failed for #$pr" >&2
  exit 2
fi

pr_number=$(echo "$pr_json"   | jq -r '.number')
pr_url=$(echo "$pr_json"      | jq -r '.url')
title=$(echo "$pr_json"       | jq -r '.title')
is_draft=$(echo "$pr_json"    | jq -r '.isDraft')
state=$(echo "$pr_json"       | jq -r '.state')
branch=$(echo "$pr_json"      | jq -r '.headRefName')
head_sha=$(echo "$pr_json"    | jq -r '.headRefOid')
base_branch=$(echo "$pr_json" | jq -r '.baseRefName')
mergeable=$(echo "$pr_json"   | jq -r '.mergeable')
merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus')

# Mergeable=UNKNOWN: one quick retry (server is computing). Avoid pr-status.sh's
# 3×5s retry here — readiness probes should stay fast.
if [ "$mergeable" = "UNKNOWN" ]; then
  sleep 3
  refresh=$(gh "${pr_args[@]}" 2>/dev/null || echo "{}")
  mergeable=$(echo "$refresh"   | jq -r '.mergeable // "UNKNOWN"')
  merge_state=$(echo "$refresh" | jq -r '.mergeStateStatus // ""')
fi

# --- 2. Behind base -----------------------------------------------------
# Same logic as pr-status.sh: GitHub's BEHIND state is only set under
# "require up to date" branch protection, so fall back to git rev-list.
behind_base=false
if [ "$merge_state" = "BEHIND" ]; then
  behind_base=true
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git fetch origin "$base_branch" --quiet 2>/dev/null || true
  if git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    count=$(git rev-list --count "HEAD..origin/$base_branch" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] && behind_base=true
  fi
fi

# --- 3. CI checks -------------------------------------------------------
# shellcheck disable=SC2054  # gh --json field list, one arg
checks_args=(pr checks "$pr" --json name,state,link)
[ -n "$repo" ] && checks_args+=(--repo "$repo")
checks=$(gh "${checks_args[@]}" --jq '[.[] | {name, state, url: .link}]' 2>/dev/null || echo "[]")

failing_count=$(echo "$checks" | jq '[.[] | select(.state == "FAILURE")] | length')
pending_count=$(echo "$checks" | jq '[.[] | select(.state == "PENDING")] | length')
passing_count=$(echo "$checks" | jq '[.[] | select(.state == "SUCCESS")] | length')
failed_names=$(echo "$checks"  | jq '[.[] | select(.state == "FAILURE") | .name]')

# --- 4. Review threads --------------------------------------------------
# Derive owner/repo for fetch-review-comments.sh from --repo or from the PR URL,
# then pass the combined owner/repo slug (no split form anywhere).
if [ -n "$repo" ]; then
  owner="${repo%%/*}"; repo_name="${repo##*/}"
else
  parts=$(echo "$pr_url" | sed -E 's#https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1 \2#')
  owner=$(echo "$parts" | awk '{print $1}')
  repo_name=$(echo "$parts" | awk '{print $2}')
fi

if reviews=$(bash "$SCRIPT_DIR/fetch-review-comments.sh" "$pr_number" "$owner/$repo_name" 2>/dev/null); then
  unresolved_threads=$(echo "$reviews" | jq '(.threads // []) | length')
  consistency_ok=$(echo "$reviews"    | jq '.consistency.ok // false')
  consistency_reason=$(echo "$reviews" | jq -r '.consistency.reason // ""')
else
  unresolved_threads=-1
  consistency_ok=false
  consistency_reason="fetch-review-comments.sh failed"
fi

# --- 5. Linked issue (best-effort) --------------------------------------
linked_issue="null"
if [ -x "$SCRIPT_DIR/journey.sh" ]; then
  issue_payload=$(bash "$SCRIPT_DIR/journey.sh" lookup 2>/dev/null || echo "{}")
  if echo "$issue_payload" | jq -e '.issue.number // empty' >/dev/null 2>&1; then
    linked_issue=$(echo "$issue_payload" | jq -c '.issue')
  fi
fi

# --- 6. Blockers + warnings ---------------------------------------------
blockers='[]'
warnings='[]'

add_blocker() {
  blockers=$(echo "$blockers" | jq --arg b "$1" '. + [$b]')
}
add_warning() {
  warnings=$(echo "$warnings" | jq --arg w "$1" '. + [$w]')
}

case "$state" in
  CLOSED)
    [ "$(echo "$pr_json" | jq -r '.state')" = "CLOSED" ] && add_blocker "closed"
    ;;
  MERGED)
    add_blocker "merged"
    ;;
esac

[ "$is_draft" = "true" ] && add_blocker "draft"

case "$mergeable" in
  CONFLICTING) add_blocker "merge_conflict" ;;
  UNKNOWN)     add_blocker "mergeable_unknown" ;;
esac

[ "$behind_base" = "true" ] && add_blocker "behind_base"

# A failing check is only a hard blocker if it actually GATES the merge. Determine
# the base branch's REQUIRED status checks from classic branch protection + the
# rulesets engine (union; either source alone may define them). A failure whose
# name is NOT in a successfully-determined required set is non-gating (e.g. an
# advisory bot review check failing on rate-limit/billing) — surface it as a
# warning, not a blocker, so it can't force a spurious escalation or block a
# reviewer ping. If the required set is empty or unreadable (no admin token),
# stay CONSERVATIVE: any failure blocks, since a non-required check can still be
# a de-facto gate (a repo-level fact zeus can't know generically).
required_known=false
required_contexts='[]'
if [ "$failing_count" -gt 0 ] && [ -n "$owner" ] && [ -n "$repo_name" ] && [ -n "$base_branch" ]; then
  classic=$(gh api "repos/$owner/$repo_name/branches/$base_branch/protection/required_status_checks" 2>/dev/null || echo "")
  rules=$(gh api "repos/$owner/$repo_name/rules/branches/$base_branch" 2>/dev/null || echo "")
  if [ -n "$classic" ] || [ -n "$rules" ]; then
    required_known=true
    required_contexts=$(jq -nc \
      --argjson c "${classic:-null}" \
      --argjson r "${rules:-null}" '
      ( ( ($c.contexts // []) )
        + ( ($c.checks // []) | map(.context) )
        + ( ($r // []) | map(select(.type == "required_status_checks")
              | .parameters.required_status_checks // []) | add // [] | map(.context) )
      ) | map(select(. != null)) | unique' 2>/dev/null || echo '[]')
  fi
fi
if [ "$failing_count" -gt 0 ]; then
  if [ "$required_known" = "true" ] && [ "$(echo "$required_contexts" | jq 'length')" -gt 0 ]; then
    required_failing_count=$(echo "$checks" | jq --argjson req "$required_contexts" \
      '[.[] | select(.state == "FAILURE") | select(.name as $n | ($req | index($n)) != null)] | length')
    [ "$required_failing_count" -gt 0 ] && add_blocker "ci_failing"
    [ "$((failing_count - required_failing_count))" -gt 0 ] && add_warning "ci_failing_nonrequired"
  else
    # Required set empty/unreadable -> conservative: treat every failure as gating.
    add_blocker "ci_failing"
  fi
fi
# A still-running check means "not settled" — a reviewer pinged now may review a
# head whose gating checks then fail. So PENDING is a blocker, not a soft warning.
# Callers that drive a loop (address-pr Report) should treat a ci_pending-only
# blocker as "wait/re-probe", not as a reason to escalate to the user.
[ "$pending_count" -gt 0 ] && add_blocker "ci_pending"

if [ "$unresolved_threads" = "-1" ]; then
  add_blocker "review_fetch_failed"
elif [ "$unresolved_threads" -gt 0 ]; then
  add_blocker "unresolved_reviews"
fi

[ "$consistency_ok" = "false" ] && add_blocker "stale_review_index"

ready=true
[ "$(echo "$blockers" | jq 'length')" -gt 0 ] && ready=false

# NOTE: the verdict is deliberately a PURE function of GitHub state. Whether
# the reviewer has been *notified* is request-review's concern (it owns the
# ping policy and the per-SHA stamp) — callers that care invoke the
# request-review SKILL by name with this verdict at their Report stage; its
# returned envelope answers the gap question (should_send / skip_reason).
# Keeping that out of here means the same verdict is emitted whether or not
# sibling skills are installed.

# --- 7. Emit ------------------------------------------------------------
payload=$(jq -nc \
  --argjson pr_number "$pr_number" \
  --arg pr_url "$pr_url" \
  --arg title "$title" \
  --arg branch "$branch" \
  --arg head_sha "$head_sha" \
  --argjson is_draft "$is_draft" \
  --arg state "$state" \
  --arg mergeable "$mergeable" \
  --argjson behind_base "$behind_base" \
  --argjson passing "$passing_count" \
  --argjson failing "$failing_count" \
  --argjson pending "$pending_count" \
  --argjson failed_names "$failed_names" \
  --argjson unresolved_threads "$unresolved_threads" \
  --argjson consistency_ok "$consistency_ok" \
  --arg consistency_reason "$consistency_reason" \
  --argjson linked_issue "$linked_issue" \
  --argjson blockers "$blockers" \
  --argjson warnings "$warnings" \
  --argjson ready "$ready" \
  '{
    ready: $ready,
    pr_number: $pr_number,
    pr_url: $pr_url,
    title: $title,
    branch: $branch,
    head_sha: $head_sha,
    is_draft: $is_draft,
    state: $state,
    mergeable: $mergeable,
    behind_base: $behind_base,
    checks: {
      passing: $passing,
      failing: $failing,
      pending: $pending,
      failed_names: $failed_names
    },
    reviews: {
      unresolved_threads: $unresolved_threads,
      consistency_ok: $consistency_ok,
      consistency_reason: $consistency_reason
    },
    linked_issue: $linked_issue,
    blockers: $blockers,
    warnings: $warnings
  }')

case "$mode" in
  json)
    echo "$payload" | jq .
    ;;
  plain)
    echo "$payload" | jq -r '
      (if .ready then "READY" else "NOT READY" end) + " — #\(.pr_number) " + .title + "\n" +
      "  URL: \(.pr_url)\n" +
      "  Branch: \(.branch) @ \(.head_sha[0:7])\n" +
      "  State: \(.state)" + (if .is_draft then " (draft)" else "" end) + "\n" +
      "  Mergeable: \(.mergeable)" + (if .behind_base then " (behind base)" else "" end) + "\n" +
      "  Checks: \(.checks.passing) passing, \(.checks.failing) failing, \(.checks.pending) pending" +
      (if (.checks.failed_names | length) > 0 then " [\(.checks.failed_names | join(", "))]" else "" end) + "\n" +
      "  Reviews: \(.reviews.unresolved_threads) unresolved" + (if .reviews.consistency_ok then "" else " (index stale: \(.reviews.consistency_reason))" end) + "\n" +
      (if .linked_issue then "  Issue:  #\(.linked_issue.number) \(.linked_issue.title // "")\n" else "" end) +
      (if (.blockers | length) > 0 then "  Blockers: " + (.blockers | join(", ")) + "\n" else "" end) +
      (if (.warnings | length) > 0 then "  Warnings: " + (.warnings | join(", ")) + "\n" else "" end)
    '
    ;;
esac

[ "$ready" = "true" ] && exit 0 || exit 1
