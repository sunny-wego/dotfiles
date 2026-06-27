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
#   $ANCHORS_FILE   {path: [valid RIGHT-side line numbers]} for inline comments
#   $FINDINGS_FILE  accumulated findings (validated against findings-schema.md)
#   $REVIEW_FILE    rendered GH review payload (pre-post)
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

STATE_DIR="$(git rev-parse --absolute-git-dir)/review-pr"
PR_FILE="$STATE_DIR/pr.json"
DIFF_FILE="$STATE_DIR/diff.patch"
ANCHORS_FILE="$STATE_DIR/anchors.json"
FINDINGS_FILE="$STATE_DIR/findings.json"
REVIEW_FILE="$STATE_DIR/review.json"
LOCK_DIR="$STATE_DIR/lock"

mkdir -p "$STATE_DIR"

cleanup_run_state() {
  rm -f "$PR_FILE" "$DIFF_FILE" "$ANCHORS_FILE" "$FINDINGS_FILE" "$REVIEW_FILE"
}
