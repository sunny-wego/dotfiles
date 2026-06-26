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

# with_lock <lock_dir> — advisory lock around a read-modify-write so two
# concurrent appends (e.g. fan-out handlers writing findings) can't lose each
# other's update. mkdir is atomic; a dead holder's lock is stolen; a ~5s timeout
# prevents a permanent deadlock if a holder died without cleanup.
with_lock() {
  local lock="$1" i=0 pid=""
  while ! mkdir "$lock" 2>/dev/null; do
    pid=""; [ -f "$lock/pid" ] && pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
    i=$((i + 1)); [ "$i" -ge 50 ] && { rm -rf "$lock"; continue; }
    sleep 0.1
  done
  echo $$ > "$lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" EXIT
}

# ----------------------------------------------------------------------------
# Identifier parsing (house convention; mirrors address-pr/scripts/lib.sh but
# adds full-URL support, since review-pr is pointed at arbitrary PRs by URL).
#
# resolve_pr "$@" — parse identifiers WITHOUT any network call. Sets globals:
#     PR, REPO_SLUG, OWNER, REPO_NAME, SHA   (any may be "")
#     REST=( … )                             unconsumed args, in order
#   Accepts, in any order:
#     a full URL  https://github.com/<owner>/<repo>/pull/<n>
#     --pr N | --pr=N            (also: a bare all-digits token)
#     --repo owner/repo | =form  (also: a bare token containing '/')
#     --sha X | --head-sha X | =form
resolve_pr() {
  PR=""; REPO_SLUG=""; OWNER=""; REPO_NAME=""; SHA=""; REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)                 PR="${2:?--pr needs a value}"; shift 2 ;;
      --pr=*)               PR="${1#*=}"; shift ;;
      --repo)               REPO_SLUG="${2:?--repo needs a value}"; shift 2 ;;
      --repo=*)             REPO_SLUG="${1#*=}"; shift ;;
      --sha|--head-sha)     SHA="${2:?--sha needs a value}"; shift 2 ;;
      --sha=*|--head-sha=*) SHA="${1#*=}"; shift ;;
      --)                   shift; while [ $# -gt 0 ]; do REST+=("$1"); shift; done ;;
      https://*|http://*)
        # github.com/<owner>/<repo>/pull/<n>  (also tolerates a trailing /files etc.)
        if [[ "$1" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
          OWNER="${BASH_REMATCH[1]}"; REPO_NAME="${BASH_REMATCH[2]}"
          REPO_SLUG="$OWNER/$REPO_NAME"; PR="${BASH_REMATCH[3]}"
        else
          echo "resolve: unrecognized PR URL '$1'" >&2; return 2
        fi
        shift ;;
      *)
        if   [ -z "$PR" ] && [[ "$1" =~ ^[0-9]+$ ]];  then PR="$1"
        elif [ -z "$REPO_SLUG" ] && [[ "$1" == */* ]]; then REPO_SLUG="$1"
        else REST+=("$1"); fi
        shift ;;
    esac
  done
  if [ -n "$REPO_SLUG" ] && [[ "$REPO_SLUG" != */* ]]; then
    echo "resolve: --repo must be owner/repo (got '$REPO_SLUG')" >&2; return 2
  fi
  [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  return 0
}

# resolve_target "$@" — like resolve_pr, but defaults REPO_SLUG via `gh` when the
# caller supplied neither a URL nor --repo (bare-number case: review a PR in the
# repo you're standing in).
resolve_target() {
  resolve_pr "$@"
  if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  fi
}
