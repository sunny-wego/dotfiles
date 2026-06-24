#!/usr/bin/env bash
# harvest.sh — gather the QUANTITATIVE friction signals a zeus session leaves
# behind, into one JSON blob. This is harvest source (b): it corroborates
# frequency/severity. The PRIMARY source (a) — the live conversation, where the
# *why* lives — is the agent's job in SKILL.md, not this script.
#
# Reads only durable, machine-readable state (no transcript parsing). Covers the
# whole issue→code→PR→review family, not just the PR pair:
#   .git/<wt>/journey/issue.json            issue number/url/title  — propose
#   .git/<wt>/journey/investigation/epic    active epic (+ report)  — investigate
#   .git/<wt>/journey/pr.json               PR number/url           — create-pr
#   git log --grep "#<issue>"               commits closing the spec — implement
#   .git/<wt>/address-pr/state.json    iteration depth, handler outcomes
#   .git/<wt>/address-pr/status.json   failed/pending checks at last snapshot
#   .git/<wt>/request-review/          ping markers (stop-nudged-<sha>) + thread
#   git log --grep "address-pr iteration" + reflog   fix-cycle count, churn
#
# Usage: harvest.sh [--pr <n>] [--repo <owner/repo>]   (both optional; defaults
# to the current worktree's journey PR). Emits JSON to stdout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

resolve_target "$@"
GITDIR="$(git rev-parse --absolute-git-dir)"
AP="$GITDIR/address-pr"
RR="$GITDIR/request-review"
JD="$GITDIR/journey"

# PR: explicit flag > journey > none.
pr="${PR:-}"
if [ -z "$pr" ] && [ -x "$SCRIPT_DIR/journey.sh" ]; then
  pr="$(bash "$SCRIPT_DIR/journey.sh" pr-number 2>/dev/null || true)"
fi

# propose state: was an issue opened, and its number/url (to query gh for revision
# churn). One file per fact under journey/ (see journey.sh).
issue=null; issue_num=""
if [ -f "$JD/issue.json" ]; then
  issue=$(jq -c '{number, url, title}' "$JD/issue.json" 2>/dev/null || echo null)
  issue_num=$(jq -r '.number // empty' "$JD/issue.json" 2>/dev/null || echo "")
fi

# investigate state: the active epic number and whether a report was published.
epic=""; report_present=false
if [ -f "$JD/investigation/epic" ]; then
  epic=$(tr -d '[:space:]' < "$JD/investigation/epic" 2>/dev/null || echo "")
fi
[ -f "$JD/investigation/report" ] && report_present=true

# implement state: commits that reference the spec issue (#N) — a proxy for how
# much code the issue took to land. Only meaningful when an issue is known.
impl_commits=0
if [ -n "$issue_num" ]; then
  impl_commits=$(git log --grep="#${issue_num}\b" --oneline 2>/dev/null | wc -l | tr -d ' ')
fi

# address-pr run state (iteration depth + handler outcomes).
iteration=0; outcomes='[]'
if [ -f "$AP/state.json" ]; then
  iteration=$(jq -r '.iteration // 0' "$AP/state.json" 2>/dev/null || echo 0)
  outcomes=$(jq -c '.outcomes // []' "$AP/state.json" 2>/dev/null || echo '[]')
fi

# Last check snapshot (which checks failed / were pending).
failed='[]'; pending=0; all_passed=null
if [ -f "$AP/status.json" ]; then
  failed=$(jq -c '.failed // []' "$AP/status.json" 2>/dev/null || echo '[]')
  pending=$(jq -r '.pending // 0' "$AP/status.json" 2>/dev/null || echo 0)
  all_passed=$(jq -r '.all_passed // null' "$AP/status.json" 2>/dev/null || echo null)
fi

# Reviewer-ping markers: one stop-nudged-<sha> file per head we nudged. Multiple
# distinct SHAs = the head advanced under the reviewer (re-pings / churn); a nudge
# on a SHA that later failed CI is a premature-ping signal (the agent cross-checks
# against git from the conversation).
ping_shas='[]'
if [ -d "$RR" ]; then
  ping_shas=$(ls "$RR" 2>/dev/null | sed -n 's/^stop-nudged-//p' | jq -R . | jq -sc . || echo '[]')
fi

# Fix-cycle count from commit markers ("address-pr iteration N") on this branch,
# and branch churn (merges/resets) from reflog — both reconstruct how hard the
# PR was to settle.
iter_commits=$(git log --grep="address-pr iteration" --oneline 2>/dev/null | wc -l | tr -d ' ')
merges=$(git log --merges --oneline -n 50 2>/dev/null | wc -l | tr -d ' ')

jq -nc \
  --arg repo "${REPO_SLUG:-}" \
  --arg pr "$pr" \
  --arg epic "$epic" \
  --argjson issue "${issue:-null}" \
  --argjson report_present "$report_present" \
  --argjson impl_commits "${impl_commits:-0}" \
  --argjson iteration "${iteration:-0}" \
  --argjson outcomes "$outcomes" \
  --argjson failed "$failed" \
  --argjson pending "${pending:-0}" \
  --argjson all_passed "${all_passed:-null}" \
  --argjson ping_shas "$ping_shas" \
  --argjson iter_commits "${iter_commits:-0}" \
  --argjson merges "${merges:-0}" \
  '{
    repo: $repo,
    pr: (if $pr == "" then null else ($pr|tonumber? // $pr) end),
    propose: { issue: $issue },
    investigate: { epic: (if $epic == "" then null else ($epic|tonumber? // $epic) end),
                   report_present: $report_present },
    implement: { spec_commits: $impl_commits },
    address_pr: { iteration: $iteration, outcomes: $outcomes,
                  last_failed_checks: $failed, last_pending: $pending,
                  all_passed: $all_passed },
    review_ping: { nudged_shas: $ping_shas, distinct_nudges: ($ping_shas|length) },
    fix_cycles: { iteration_commits: $iter_commits, merges: $merges },
    note: "Quantitative only. Pair with the conversation (the *why*) per SKILL.md."
  }'
