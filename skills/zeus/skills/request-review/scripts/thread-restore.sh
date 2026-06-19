#!/usr/bin/env bash
# thread-restore.sh — re-seed this worktree's review-thread state from a
# previously-persisted Slack record (e.g. the one address-pr stores in the PR
# body's hidden journey marker).
#
# request-review owns thread state, so the seeding judgment lives HERE, not in
# the caller: the reviewed SHA is recovered from the PR's latest review commit
# (any author — the skill pings code owners, so there is no single target), so a
# re-review fires iff the head advanced past it. That SHA is deliberately not in
# the marker (which omits volatile state); falls back to --head-sha. Existing
# local state is never overwritten — fills gaps only, so re-running is a no-op.
#
# Stdin:  {"channel": "C…", "thread_ts": "…"}   (a legacy "target" field is ignored)
# Usage:  thread-restore.sh --pr <n> --repo <owner/repo> [--sha <head_sha>]
#   (identifiers also accepted positionally; --head-sha is an accepted alias for --sha.)
# Output: {"restored": bool, "reason": string}
# Exit: always 0 — restoration is enrichment, never a hard dependency.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"; set +e  # lib enables errexit; this script handles its own flow

emit() { jq -nc --argjson r "$1" --arg why "$2" '{restored:$r, reason:$why}'; exit 0; }

resolve_target "$@"   # --pr/--repo/--sha (--head-sha alias), or positional
pr="$PR"; repo="$REPO_SLUG"; head_sha="$SHA"
[ -n "$pr" ] && [ -n "$repo" ] || emit false "bad_args"

record=$(cat 2>/dev/null || echo '{}')
echo "$record" | jq -e . >/dev/null 2>&1 || emit false "bad_record"

channel=$(echo "$record"   | jq -r '.channel // empty')
thread_ts=$(echo "$record" | jq -r '.thread_ts // empty')
{ [ -n "$channel" ] && [ -n "$thread_ts" ]; } || emit false "no_thread_in_record"

# Fill gaps only: a worktree that already has a thread for this PR keeps it.
existing_ts=$(bash "$SCRIPT_DIR/review-thread.sh" get "$pr" 2>/dev/null \
  | jq -r '.thread_ts // empty' 2>/dev/null || true)
[ -n "$existing_ts" ] && emit false "already_present"

# Seed the reviewed SHA from the PR's latest review commit (any author) so we
# don't spuriously re-ping (sha known) or miss a needed re-review. Fall back to head.
reviewed_sha=$(gh pr view "$pr" --repo "$repo" --json reviews \
  --jq '.reviews | sort_by(.submittedAt) | last | .commit.oid // empty' \
  2>/dev/null || true)
[ -z "$reviewed_sha" ] && reviewed_sha="$head_sha"
[ -n "$reviewed_sha" ] || emit false "no_sha_to_stamp"

if bash "$SCRIPT_DIR/review-thread.sh" set "$pr" "$reviewed_sha" \
     --thread-ts "$thread_ts" --channel "$channel" 2>/dev/null; then
  emit true "restored"
else
  emit false "stamp_failed"
fi
