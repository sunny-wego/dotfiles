#!/usr/bin/env bash
# detect-target.sh — decide whether review-pr reviews a LOCAL working diff (pre-PR)
# or a REMOTE open PR, WITHOUT the caller having to say which. Runs pre-isolation
# (like identify-pr.sh): pure resolution, no checkout, no state dir.
#
# Auto is the default; flags are overrides. Decision order — FIRST MATCH WINS:
#   1. --local / --base <ref>   → LOCAL   (explicit override; wins even if a PR exists)
#   2. a PR number / URL arg    → REMOTE  (explicit override; delegates to identify-pr.sh)
#   3. no flag, no arg          → auto-detect from the CURRENT branch:
#        - no open PR                                  → LOCAL  (you're pre-PR)
#        - open PR, but local diverges from its head
#          (dirty tree OR HEAD != pushed PR head)      → LOCAL  (review real on-disk state)
#        - open PR, clean tree AND HEAD == PR head      → REMOTE (review the PR)
#   The divergence check stops us reviewing a stale pushed PR head while local work
#   has moved on. The --local override (1) and a PR arg (2) still win.
#
# Output JSON:
#   LOCAL : { "mode":"local",  head_sha, base, branch, note? }
#   REMOTE: { "mode":"remote", owner, repo, number, head_sha, base, url, title, foreign }
#           (identify-pr.sh's shape, plus "mode")
# Exit: 0 on success; non-zero with {"error":...} on stderr otherwise.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

local_flag=false base="" pr_ref="" repo_slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local)            local_flag=true; shift ;;
    --base)             base="${2:?--base needs a ref}"; shift 2 ;;
    --base=*)           base="${1#*=}"; shift ;;
    --repo)             repo_slug="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*)           repo_slug="${1#*=}"; shift ;;
    https://*|http://*) pr_ref="$1"; shift ;;
    *)  if   [[ "$1" =~ ^[0-9]+$ ]]; then pr_ref="$1"
        elif [[ "$1" == */* ]];      then repo_slug="$1"
        fi; shift ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo '{"error":"detect-target: not inside a git work tree"}' >&2; exit 1; }

default_base() {
  local ref
  if ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
    echo "${ref#refs/remotes/}"; return
  fi
  local c
  for c in origin/main origin/master main master; do
    git rev-parse --verify --quiet "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  echo main
}

emit_local() { # emit_local <note>
  local head branch b
  head=$(git rev-parse HEAD 2>/dev/null) || { echo '{"error":"detect-target: no HEAD commit"}' >&2; exit 1; }
  branch=$(git branch --show-current 2>/dev/null || echo "")
  b="$base"; [ -z "$b" ] && b=$(default_base)
  jq -nc --arg h "$head" --arg b "$b" --arg br "$branch" --arg note "${1:-}" \
    '{mode:"local", head_sha:$h, base:$b, branch:$br} + (if $note != "" then {note:$note} else {} end)'
}

emit_remote() { # emit_remote <pr-ref> [--repo slug] — delegate to identify-pr.sh
  local out
  out=$(bash "$SCRIPT_DIR/identify-pr.sh" "$@") || { echo "$out" >&2; exit 1; }
  echo "$out" | jq -c '. + {mode:"remote"}'
}

# 1. explicit LOCAL override
if [ "$local_flag" = true ] || [ -n "$base" ]; then
  emit_local ""
  exit 0
fi

# 2. explicit PR arg → REMOTE
if [ -n "$pr_ref" ]; then
  if [ -n "$repo_slug" ]; then emit_remote "$pr_ref" --repo "$repo_slug"; else emit_remote "$pr_ref"; fi
  exit 0
fi

# 3. auto-detect from the current branch (one gh call for number + head)
prinfo=$(gh pr view --json number,headRefOid 2>/dev/null || true)
prnum=$(printf '%s' "$prinfo" | jq -r '.number // empty' 2>/dev/null || true)
if [ -z "$prnum" ]; then
  emit_local ""                       # no open PR for this branch → pre-PR, local
  exit 0
fi

pr_head=$(printf '%s' "$prinfo" | jq -r '.headRefOid // empty')
head=$(git rev-parse HEAD 2>/dev/null || echo "")
dirty=false
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then dirty=true; fi

if [ "$dirty" = true ] || [ "$head" != "$pr_head" ]; then
  emit_local "PR #$prnum is open but your branch has unpushed/uncommitted changes — reviewing local working state"
else
  emit_remote "$prnum"                # clean and at the pushed PR head → review the PR
fi
