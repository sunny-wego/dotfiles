#!/usr/bin/env bash
# detect-target.sh — decide WHAT review-pr reviews and WHOSE work it is, without
# the caller having to say. Runs pre-isolation (no checkout, no state dir).
#
# Two orthogonal axes:
#   source = local | remote   — WHERE the diff is (local working tree vs an open PR)
#   role   = self  | peer     — WHOSE work it is (mine → hand findings back; someone
#                               else's → post comments as a reviewer)
# Locality is NOT authorship: reviewing my OWN open PR is source=remote, role=self.
#
# Auto by default; flags/arg are overrides. Decision order — FIRST MATCH WINS:
#   1. --local / --base <ref>   → source=local (role self; pre-PR work is always mine)
#   2. a PR number / URL arg    → source=remote
#   3. no flag, no arg          → auto from the CURRENT branch:
#        - no open PR                              → source=local (pre-PR)
#        - open PR, local diverges from its head
#          (dirty tree OR HEAD != pushed head)     → source=local (review on-disk state)
#        - open PR, clean & HEAD == pushed head     → source=remote
#   role: source=local ⇒ self. source=remote ⇒ self if the PR author is the
#   authenticated user, else peer. `--as self|peer` overrides role explicitly.
#
# Output JSON:
#   { "source":"local"|"remote", "role":"self"|"peer",
#     local : head_sha, base, branch, note?
#     remote: owner, repo, number, head_sha, base, url, title, author, foreign }
# Exit: 0 on success; non-zero with {"error":...} on stderr otherwise.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZEUS_LIB_DIR="$(cd "$SCRIPT_DIR/../../../lib" && pwd)"
# shellcheck source=../../../lib/repo.sh
source "$ZEUS_LIB_DIR/repo.sh"

local_flag=false base="" pr_ref="" repo_slug="" as_role=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local)            local_flag=true; shift ;;
    --base)             base="${2:?--base needs a ref}"; shift 2 ;;
    --base=*)           base="${1#*=}"; shift ;;
    --as)               as_role="${2:?--as needs self|peer}"; shift 2 ;;
    --as=*)             as_role="${1#*=}"; shift ;;
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

# role for a remote PR: self when its author is the authenticated user, else peer.
# Unknown viewer (gh down) → peer; peer without --submit only dry-runs, so nothing
# is posted by accident. --as overrides.
remote_role() { # remote_role <author_login>
  [ -n "$as_role" ] && { printf '%s\n' "$as_role"; return; }
  local me; me="$(gh api user --jq .login 2>/dev/null || true)"
  if [ -n "$me" ] && [ "$me" = "$1" ]; then printf 'self\n'; else printf 'peer\n'; fi
}

emit_local() { # emit_local <note>
  local head branch b role
  head=$(git rev-parse HEAD 2>/dev/null) || { echo '{"error":"detect-target: no HEAD commit"}' >&2; exit 1; }
  branch=$(current_branch)
  b="$base"; [ -z "$b" ] && b=$(default_base_ref_git)   # git-only: a local emit must not block on gh
  role="${as_role:-self}"
  jq -nc --arg h "$head" --arg b "$b" --arg br "$branch" --arg role "$role" --arg note "${1:-}" \
    '{source:"local", role:$role, head_sha:$h, base:$b, branch:$br} + (if $note != "" then {note:$note} else {} end)'
}

emit_remote() { # emit_remote <pr-ref> [--repo slug]
  local out role
  out=$(bash "$SCRIPT_DIR/identify-pr.sh" "$@") || { echo "$out" >&2; exit 1; }
  role="$(remote_role "$(printf '%s' "$out" | jq -r '.author // ""')")"
  printf '%s' "$out" | jq -c --arg role "$role" '. + {source:"remote", role:$role}'
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

# 3. auto-detect from the current branch. Probe with `gh pr list` (not `gh pr view`):
# it exits 0 with `[]` for a genuine no-PR, and non-zero ONLY on a real gh failure —
# so we can tell "you're pre-PR" from "GitHub is unreachable" instead of silently
# treating both as local (mirrors suggest-pr.sh). gh down → local WITH a note, never
# a silent misroute; review is read-only either way.
branch=$(current_branch)
if prlist=$(gh pr list --head "$branch" --state open --json number,headRefOid,author 2>/dev/null); then
  prnum=$(printf '%s' "$prlist" | jq -r '.[0].number // empty' 2>/dev/null || true)
  if [ -z "$prnum" ]; then
    emit_local ""                     # no open PR for this branch → pre-PR, local
    exit 0
  fi
else
  emit_local "couldn't reach GitHub to check for an open PR — reviewing local working state"
  exit 0
fi

pr_head=$(printf '%s' "$prlist" | jq -r '.[0].headRefOid // empty')
head=$(git rev-parse HEAD 2>/dev/null || echo "")
dirty=false
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then dirty=true; fi

if [ "$dirty" = true ] || [ "$head" != "$pr_head" ]; then
  emit_local "PR #$prnum is open but your branch has unpushed/uncommitted changes — reviewing local working state"
else
  emit_remote "$prnum"                # clean and at the pushed PR head → review the PR
fi
