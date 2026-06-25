#!/usr/bin/env bash
# Monitor-mode probe — freshness check for an open PR.
#
# Stage 1 (runs every wake, 1–2 small API calls): fetch PR state, updated_at,
# merge state, and CI check states.
#   - merged/closed → action=exit
#   - mergeable=false or mergeable_state ∈ {dirty, behind} → action=escalate (merge_state_issue)
#   - any check state=FAILURE on head SHA → action=escalate (ci_failed)
#   - updated_at <= last_seen → action=idle (no comments to process, sleep again)
#
# Stage 2 (only when Stage 1 advances past the updated_at gate): fetch all four
# comment buckets, filter to items newer than last_seen (threads are already
# unresolved-only by the GraphQL query). If nothing comment-related surfaces,
# the probe was a false positive (label / push / review approval etc) —
# action=idle, but bump last_seen so the next wake short-circuits.
#
# Usage:
#   monitor-probe.sh --pr <n> [--repo <owner/repo>]   (identifiers also positional)
#
# Outputs JSON:
#   { "action": "exit" | "escalate" | "idle" | "process",
#     "reason": "merged" | "closed_*" | "merge_state_issue" | "ci_failed" |
#               "fetch_failed" | "no_activity" | "comment_activity" | "probe_failed",
#     "last_seen": "<prev>", "pr_updated_at": "<new>",
#     "filtered_path": "/path/to/filtered.json"  // only for action=process
#   }
#
# Exit code: 0 for completed probes; exits 1 when monitor state is missing.
# Call monitor-step.sh from the skill so missing state is initialized first.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

resolve_target "$@"
owner="$OWNER"; repo="$REPO_NAME"; pr="$PR"
[ -n "$pr" ] && [ -n "$REPO_SLUG" ] || {
  echo "Usage: monitor-probe.sh --pr <n> [--repo <owner/repo>]" >&2; exit 2; }

rm -f "$MONITOR_FILTERED_FILE"

if [ ! -f "$MONITOR_FILE" ]; then
  echo "monitor state missing — run monitor-state.sh init first" >&2
  exit 1
fi

last_seen=$(jq -r '.last_seen' "$MONITOR_FILE")

# Stage 1: tiny probe — PR state + updated_at + merge state
pr_json=$(gh api "repos/$owner/$repo/pulls/$pr" --jq '{state, merged, updated_at, mergeable, mergeable_state}' 2>/dev/null) || {
  jq -nc --arg ls "$last_seen" '{action: "idle", reason: "probe_failed", last_seen: $ls, pr_updated_at: null}'
  exit 0
}

state=$(echo "$pr_json" | jq -r '.state')
merged=$(echo "$pr_json" | jq -r '.merged')
pr_updated=$(echo "$pr_json" | jq -r '.updated_at')
mergeable=$(echo "$pr_json" | jq -r '.mergeable')
mergeable_state=$(echo "$pr_json" | jq -r '.mergeable_state')

if [ "$merged" = "true" ]; then
  jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" \
    '{action: "exit", reason: "merged", last_seen: $ls, pr_updated_at: $pu}'
  exit 0
fi

if [ "$state" != "open" ]; then
  jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" --arg s "$state" \
    '{action: "exit", reason: ("closed_" + $s), last_seen: $ls, pr_updated_at: $pu}'
  exit 0
fi

# Merge-state regression — escalate to full flow. GitHub-only signal
# (no git-fetch) is weaker than pr-status.sh's behind-count check, but
# safe to run every wake and good enough to decide "escalate or not".
# mergeable=null/UNKNOWN is treated as "not degraded" — full flow retries
# with backoff if still unknown.
if [ "$mergeable" = "false" ] || [ "$mergeable_state" = "dirty" ] || [ "$mergeable_state" = "behind" ]; then
  jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" --arg ms "$mergeable_state" \
    '{action: "escalate", reason: "merge_state_issue", mergeable_state: $ms, last_seen: $ls, pr_updated_at: $pu}'
  exit 0
fi

# CI regression — escalate to full flow on any FAILURE check whose NAME is not in
# the user-accepted set. gh pr checks respects the repo flag, so this works even
# when the worktree isn't on the PR branch. The marker is read only when something
# is actually failing, so the common all-green wake keeps its single-call cost.
failed_names=$(gh pr checks "$pr" --repo "$owner/$repo" --json name,state \
  --jq '[.[] | select(.state == "FAILURE") | .name]' 2>/dev/null) || failed_names="[]"
[ -n "$failed_names" ] || failed_names="[]"
if [ "$(echo "$failed_names" | jq 'length')" != "0" ]; then
  # Subtract the user-accepted set (durable in the PR-body journey marker).
  # Accepted checks are de-facto-gate failures the human explicitly chose to
  # proceed past (settled-by-decision in SKILL.md); re-escalating on them would
  # loop straight back to the same already-answered AskUserQuestion. The set
  # survives a fresh session/worktree wake via the marker; a NEW failing check
  # beyond the accepted set still escalates.
  accepted_checks=$(bash "$SCRIPT_DIR/journey-marker.sh" read "$pr" "$owner/$repo" 2>/dev/null \
    | jq -c '.accepted_checks // []' 2>/dev/null) || accepted_checks="[]"
  [ -n "$accepted_checks" ] || accepted_checks="[]"
  unaccepted=$(jq -nc --argjson f "$failed_names" --argjson a "$accepted_checks" \
    '($a | map({key: ., value: true}) | from_entries) as $acc
     | [ $f[] | select($acc[.] // false | not) ]' 2>/dev/null || echo "[]")
  if [ "$(echo "$unaccepted" | jq 'length')" != "0" ]; then
    jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" --argjson names "$unaccepted" \
      '{action: "escalate", reason: "ci_failed", failed_count: ($names|length), failed_names: $names, last_seen: $ls, pr_updated_at: $pu}'
    exit 0
  fi
fi

# String comparison is safe for ISO8601 timestamps (lexicographic == chronological).
# Stage 1 uses inclusive >= so same-second activity isn't stranded at the gate.
# Stage 2 also uses inclusive >= against last_seen; dedup against the previous
# probe's acked-id set (last_acked_ids) prevents already-handled items from
# resurfacing. GitHub timestamps are 1s resolution, so boundary collisions
# between last_seen and a fresh comment's submitted_at/updated_at are common —
# strict > would silently drop those.
if [ ! "$pr_updated" \< "$last_seen" ]; then
  :  # pr_updated >= last_seen — fall through to Stage 2
else
  jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" \
    '{action: "idle", reason: "no_activity", last_seen: $ls, pr_updated_at: $pu}'
  exit 0
fi

# Stage 2: full fetch + client-side filter by updated_at >= last_seen, with
# id-based dedup against last_acked_ids. Threads are already filtered to
# isResolved=false by fetch-review-comments.sh.
# Fetch failure → escalate (not idle) so the next /zeus:address-pr full run retries
# with its own error surfaces. Sleeping on a persistent fetch error would
# starve the loop of every signal it depends on.
all=$(bash "$SCRIPT_DIR/fetch-review-comments.sh" "$pr" "$owner/$repo") || {
  jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" \
    '{action: "escalate", reason: "fetch_failed", last_seen: $ls, pr_updated_at: $pu}'
  exit 0
}

last_acked=$(jq -c '.last_acked_ids // []' "$MONITOR_FILE")

filtered=$(echo "$all" | jq --arg ls "$last_seen" --argjson acked "$last_acked" '
  ($acked | map({key: tostring, value: true}) | from_entries) as $ack
  | {
      threads:               [ .threads[]               | select(($ack[(.id | tostring)] // false) | not) ],
      reviews:               [ .reviews[]               | select((.submitted_at // .updated_at // "") >= $ls) | select(($ack[((.id // .databaseId) | tostring)] // false) | not) ],
      inline_comments:       [ .inline_comments[]       | select((.updated_at // .created_at // "") >= $ls) | select(($ack[(.id | tostring)] // false) | not) ],
      conversation_comments: [ .conversation_comments[]
        | select((.updated_at // .created_at // "") >= $ls)
        | select(($ack[(.id | tostring)] // false) | not)
        # Drop in-place-edited bot STATUS comments (deploy preview, quality gate,
        # auto-generated review summary / in-progress / rate-limit notes): they
        # re-edit on every push and would re-surface as comment_activity, pinning
        # the watch at the floor delay so the idle backoff never engages.
        # Author-scoped, never a blanket drop — human top-level comments are kept,
        # and actionable review feedback arrives as threads/inline/reviews (above).
        | select(((.user // "") | test("vercel\\[bot\\]$|sonar.*\\[bot\\]$")) | not)
        | select((((.user // "") == "coderabbitai[bot]") and ((.body // "") | test("auto-generated comment|review in progress|rate limited"; "i"))) | not) ]
    }
')

nonempty=$(echo "$filtered" | jq '[.threads, .reviews, .inline_comments, .conversation_comments] | map(length) | add')

if [ "$nonempty" = "0" ]; then
  # False positive — PR bumped for a non-comment reason. Advance last_seen.
  jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" \
    '{action: "idle", reason: "non_comment_activity", last_seen: $ls, pr_updated_at: $pu}'
  exit 0
fi

echo "$filtered" > "$MONITOR_FILTERED_FILE"

jq -nc --arg ls "$last_seen" --arg pu "$pr_updated" --arg fp "$MONITOR_FILTERED_FILE" --argjson n "$nonempty" \
  '{action: "process", reason: "comment_activity", last_seen: $ls, pr_updated_at: $pu, filtered_path: $fp, item_count: $n}'
