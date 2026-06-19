#!/usr/bin/env bash
# rehydrate.sh — reconstruct per-worktree cross-skill state from the PR itself,
# so a fresh session (new clone/worktree, empty .git) can "pick up" a PR.
#
# The PR body's hidden journey marker (journey-marker.sh) is the durable anchor;
# GitHub is the safety net. We only ever FILL GAPS — never overwrite local state
# that this worktree already has — so re-running mid-session is a no-op and a
# worktree that drove the PR from the start is unaffected.
#
# What it restores:
#   - journey.json .issue     ← marker.issue (or GitHub closingIssuesReferences)
#   - journey.json .investigation  ← marker.investigation
#   - the Slack review thread  ← NOT restored here. The marker's slack record
#       {channel, thread_ts, target} is only EXTRACTED and returned as
#       `slack_record`; the agent passes it as DATA when invoking the
#       request-review SKILL (by name — skills never call each other's files),
#       which owns thread state and the reviewed-SHA seeding judgment.
#
# Usage: rehydrate.sh --pr <n> [--repo <owner/repo>] [--sha <head_sha>]
#   (identifiers are also accepted positionally, any order: a bare number is the
#    PR, a bare owner/repo is the repo; repo defaults to the current checkout.)
# Output: compact JSON of what was restored (best-effort; every step is guarded).
# Exit: always 0 — rehydration is enrichment, never a hard dependency.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

resolve_target "$@"
pr="$PR"; owner="$OWNER"; repo="$REPO_NAME"; head_sha="$SHA"
[ -z "$head_sha" ] && [ "${#REST[@]}" -gt 0 ] && head_sha="${REST[0]}"
[ -n "$pr" ] && [ -n "$REPO_SLUG" ] || {
  echo "usage: rehydrate.sh --pr <n> [--repo <owner/repo>] [--sha <head>]" >&2; exit 2; }

restored_issue=false
restored_investigation=false

marker=$(bash "$SCRIPT_DIR/journey-marker.sh" read "$pr" "$owner/$repo" 2>/dev/null || echo '{}')
echo "$marker" | jq -e . >/dev/null 2>&1 || marker='{}'

# --- journey.json: issue (marker, else closingIssuesReferences already folded in by read) ---
m_issue=$(echo "$marker" | jq -r '.issue // empty')
if [ -n "$m_issue" ] && [ -z "$(bash "$SCRIPT_DIR/journey.sh" issue-number 2>/dev/null || true)" ]; then
  bash "$SCRIPT_DIR/journey.sh" write-issue "$m_issue" \
    "https://github.com/$owner/$repo/issues/$m_issue" "" 2>/dev/null && restored_issue=true || true
fi

# --- journey.json: investigation epic ---
m_investigation=$(echo "$marker" | jq -r '.investigation // empty')
if [ -n "$m_investigation" ] && [ -z "$(bash "$SCRIPT_DIR/journey.sh" investigation-epic 2>/dev/null || true)" ]; then
  bash "$SCRIPT_DIR/journey.sh" write-investigation "$m_investigation" 2>/dev/null && restored_investigation=true || true
fi

# --- Slack review thread (delegated — request-review owns thread state) ---
# Only EXTRACT the marker's slack record (the marker is this skill's tool).
# Restoration is request-review's judgment: the agent hands `slack_record` as
# DATA when invoking the request-review skill by name (see its SKILL.md →
# Invocation contract), and request-review re-seeds its own thread state
# (fill-gaps-only). A null record means request-review starts cold — the same
# degradation as when that skill isn't installed at all.
m_slack=$(echo "$marker" | jq -c '.slack // empty')
[ -z "$m_slack" ] && m_slack='null'

jq -nc \
  --argjson issue "$restored_issue" \
  --argjson investigation "$restored_investigation" \
  --argjson slack "$m_slack" \
  --argjson marker_present "$([ "$marker" = '{}' ] && echo false || echo true)" \
  '{rehydrated: {issue: $issue, investigation: $investigation}, slack_record: $slack, marker_present: $marker_present}'
