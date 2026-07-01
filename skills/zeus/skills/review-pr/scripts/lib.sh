#!/usr/bin/env bash
# Shared helpers for review-pr scripts.
# Source (don't execute): `source "$(dirname "$0")/lib.sh"`
#
# review-pr is the *reviewer* role (the inverse of address-pr): it reviews
# someone else's PR and posts findings, rather than fixing your own. State is
# keyed per checkout under .git/review-pr/ so two reviews in two worktrees never
# collide.
#
# Provides:
#   $STATE_DIR      per-checkout dir under .git/ (isolated across worktrees)
#   $PR_FILE        resolved PR metadata (owner/repo/number/head_sha/base/url)
#   $DIFF_FILE      unified diff of the PR (gh pr diff)
#   $DELTA_DIFF_FILE  on a re-review, the diff since the last-reviewed head only
#   $ANCHORS_FILE   {path: [valid RIGHT-side line numbers]} for inline comments
#   $FINDINGS_FILE  accumulated findings (validated against findings-schema.md)
#   $TESTS_FILE     result of the changed-area test slice (run-changed-tests.sh)
#   $REVIEW_FILE    rendered GH review payload (pre-post)
#   $REVIEWED_HEAD_FILE  SHA of the head last reviewed (persists → next re-review's delta base)
#   cleanup_run_state   clear all per-run artifacts before a fresh review
#   with_lock           mkdir-based advisory lock (read-modify-write safety)
#   resolve_pr/resolve_target  identifier parsing (URL/number/slug → globals)

set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lib.sh: not inside a git worktree" >&2
  exit 1
fi

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted).
# pr-ident.sh's resolve_pr is the canonical URL-aware parser (this skill used to
# carry that variant locally).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/pr-ident.sh
source "$ZEUS_LIB_DIR/pr-ident.sh"
# shellcheck source=../../../lib/lock.sh
source "$ZEUS_LIB_DIR/lock.sh"
# shellcheck source=../../../lib/repo.sh
source "$ZEUS_LIB_DIR/repo.sh"
# shellcheck source=../../../lib/config.sh
source "$ZEUS_LIB_DIR/config.sh"
# shellcheck source=../../../lib/state.sh
source "$ZEUS_LIB_DIR/state.sh"

STATE_DIR="$(state_root review-pr)"
PR_FILE="$STATE_DIR/pr.json"
DIFF_FILE="$STATE_DIR/diff.patch"
DELTA_DIFF_FILE="$STATE_DIR/delta.patch"   # re-review: diff since $REVIEWED_HEAD_FILE (else absent)
ANCHORS_FILE="$STATE_DIR/anchors.json"
FINDINGS_FILE="$STATE_DIR/findings.json"
TESTS_FILE="$STATE_DIR/tests.json"   # changed-area test slice result (run-changed-tests.sh)
REVIEW_FILE="$STATE_DIR/review.json"
PRIOR_FILE="$STATE_DIR/prior.json"   # our own unresolved findings from earlier rounds (re-review)
SLACK_FILE="$STATE_DIR/slack-thread.json"  # Slack reply coordinate {channel, thread_ts, ...} (Slack-triggered entry point)
REVIEWED_HEAD_FILE="$STATE_DIR/reviewed-head"  # SHA of the head we last reviewed (delta base for next re-review)
LOCK_DIR="$STATE_DIR/lock"

# Wipes per-RUN scratch only. $SLACK_FILE and $REVIEWED_HEAD_FILE are deliberately
# NOT listed: like request-review's review-thread.json they must PERSIST across runs
# so a same-session re-review can reply in the original thread ($SLACK_FILE) and scope
# the new diff to the delta since the last review ($REVIEWED_HEAD_FILE). Both are
# per-PR by construction (STATE_DIR lives inside the per-PR worktree) and die with it.
cleanup_run_state() {
  rm -f "$PR_FILE" "$DIFF_FILE" "$DELTA_DIFF_FILE" "$ANCHORS_FILE" "$FINDINGS_FILE" \
        "$TESTS_FILE" "$REVIEW_FILE" "$PRIOR_FILE"
}
