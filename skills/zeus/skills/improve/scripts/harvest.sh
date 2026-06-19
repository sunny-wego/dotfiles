#!/usr/bin/env bash
# harvest.sh — gather the QUANTITATIVE friction signals a zeus session leaves
# behind, into one JSON blob. This is harvest source (b): it corroborates
# frequency/severity. The PRIMARY source (a) — the live conversation, where the
# *why* lives — is the agent's job in SKILL.md, not this script.
#
# Reads only durable, machine-readable state (no transcript parsing):
#   .git/<wt>/address-pr/state.json    iteration depth, handler outcomes
#   .git/<wt>/address-pr/status.json   failed/pending checks at last snapshot
#   .git/<wt>/request-review/          ping markers (stop-nudged-<sha>) + thread
#   .git/<wt>/journey/pr.json          PR number/url
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

# PR: explicit flag > journey > none.
pr="${PR:-}"
if [ -z "$pr" ] && [ -x "$SCRIPT_DIR/journey.sh" ]; then
  pr="$(bash "$SCRIPT_DIR/journey.sh" pr-number 2>/dev/null || true)"
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
    address_pr: { iteration: $iteration, outcomes: $outcomes,
                  last_failed_checks: $failed, last_pending: $pending,
                  all_passed: $all_passed },
    review_ping: { nudged_shas: $ping_shas, distinct_nudges: ($ping_shas|length) },
    fix_cycles: { iteration_commits: $iter_commits, merges: $merges },
    note: "Quantitative only. Pair with the conversation (the *why*) per SKILL.md."
  }'
