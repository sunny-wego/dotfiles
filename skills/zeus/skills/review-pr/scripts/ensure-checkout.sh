#!/usr/bin/env bash
# ensure-checkout.sh — guarantee review-pr has the PR's code checked out at its
# head, isolated from the invoking checkout. Two paths:
#
#   local repo  (PR lives in the repo you're standing in)  → a git worktree at
#               <main-root>/.claude/worktrees/review-pr-<n>, branch via gh pr
#               checkout (fork-safe). Cheap; reuses the existing clone's objects.
#   foreign repo (any other repo, by URL)                  → a blobless clone
#               into a scratch dir, then gh pr checkout. Needed because you can't
#               make a worktree of a repo you don't have locally.
#
# A checkout (not just `gh pr diff`) is required because the verify tier runs the
# PR's tests/migrations and the handlers read full file context, not only hunks.
#
# Usage: ensure-checkout.sh --pr <n> --repo <owner/repo> [--foreign true|false] [--sha <head>]
# Output JSON: { path, mode, created, reused, already_inside }
# Exit: 0 on success; non-zero with {"error": ...} on stderr otherwise.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/pr-ident.sh"   # resolve_pr — side-effect-free; this runs pre-isolation
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/worktree.sh"   # shared worktree engine (also side-effect-free)

# --foreign is review-pr-specific (not an identifier), so strip it before resolve_pr.
foreign=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --foreign) foreign="${2:?}"; shift 2 ;;  --foreign=*) foreign="${1#*=}"; shift ;;
    *) ARGS+=("$1"); shift ;;                 # --pr/--repo/--sha → resolve_pr
  esac
done
resolve_pr ${ARGS[@]+"${ARGS[@]}"}
pr="$PR"; slug="$REPO_SLUG"; sha="$SHA"
[ -n "$pr" ] && [ -n "$slug" ] || { echo '{"error": "ensure-checkout.sh needs --pr and --repo"}' >&2; exit 2; }

current_top=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
emit() { # emit <path> <mode> <created> <reused>
  # Seed the review-pr state dir in the checkout's OWN git dir up front, so the
  # address-pr / create-pr push+stop hooks (which bail when this dir exists — the
  # reviewer role is read-only) can't false-positive in the window between HEAD
  # landing on the PR branch here and the first lib.sh source (extract-diff.sh)
  # that would otherwise create it. Best-effort; lib.sh's own mkdir -p is idempotent.
  local gd; gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  [ -n "$gd" ] && mkdir -p "$gd/review-pr" 2>/dev/null || true
  local ai=false; [ "$current_top" = "$1" ] && ai=true
  jq -nc --arg path "$1" --arg mode "$2" --argjson created "$3" --argjson reused "$4" --argjson ai "$ai" \
    '{path:$path, mode:$mode, created:$created, reused:$reused, already_inside:$ai}'
}

# ---- foreign repo: blobless clone into a scratch dir, then checkout the PR ----
if [ "$foreign" = "true" ]; then
  scratch="${CLAUDE_JOB_DIR:-${TMPDIR:-/tmp}}/zeus-review-pr/${slug//\//-}-pr$pr"
  if [ -d "$scratch/.git" ]; then
    ( cd "$scratch" && gh pr checkout "$pr" >/dev/null 2>&1 ) \
      || { echo "{\"error\": \"refresh checkout of PR $pr failed in $scratch\"}" >&2; exit 1; }
    emit "$scratch" foreign-clone false true; exit 0
  fi
  mkdir -p "$(dirname "$scratch")"
  if ! gh repo clone "$slug" "$scratch" -- --filter=blob:none >/dev/null 2>&1; then
    echo "{\"error\": \"gh repo clone $slug failed (access? network?)\"}" >&2; exit 1
  fi
  if ! ( cd "$scratch" && gh pr checkout "$pr" >/dev/null 2>&1 ); then
    echo "{\"error\": \"gh pr checkout $pr failed in fresh clone $scratch\"}" >&2; exit 1
  fi
  emit "$scratch" foreign-clone true false; exit 0
fi

# ---- local repo: worktree of the current clone (shared engine: lib/worktree.sh) ----
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo '{"error": "not inside a git work tree, and PR is not marked foreign"}' >&2; exit 1
fi
wt_path="$(worktree_path_for review-pr "$pr")" \
  || { echo '{"error": "could not locate the main worktree root"}' >&2; exit 1; }
if ! worktree_ensure_local "$wt_path" "$pr"; then
  jq -nc --arg e "$WORKTREE_ERR" '{error:$e}' >&2; exit 1
fi
if [ "$WORKTREE_RESULT" = created ]; then emit "$wt_path" worktree true false
else emit "$wt_path" worktree false true; fi
