#!/usr/bin/env bash
# precondition.sh — refuse to implement into the wrong place.
#
# WHY: workspace setup is the CALLER's job — the coding agent (Claude Code) puts
# us in a worktree on a feature branch before invoking this skill. This guard does
# NOT create anything (no /wgd, no branch creation); it only confirms we're somewhere
# safe to write code, so implement never dumps a feature onto the default branch or a
# detached HEAD. Same fail-safe instinct as /zeus:propose's ownership gate: a wrong target
# is invisible downstream, so catch it before the first edit.
#
# Blocks (ok:false) when:
#   - not inside a git work tree
#   - HEAD is detached (no branch to carry the work / hand to create-pr)
#   - the current branch IS the repo default (main/master) — implementing there is
#     almost always a mistake and create-pr has no feature branch to open a PR from
# Warns (ok:true, warnings[]) when:
#   - the worktree has uncommitted changes already (may be unrelated work to preserve)
#
# Usage:  precondition.sh
# Output: {ok, branch, default_branch, detached, dirty, errors, warnings}

set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$script_dir/lib.sh"

errors=(); warnings=()

detached=false
if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
  detached=true
  errors+=("HEAD is detached — implement needs a feature branch to commit onto and hand to /zeus:create-pr")
fi

default_branch=$(repo_default_branch)
if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" = "$default_branch" ]; then
  errors+=("current branch '$CURRENT_BRANCH' is the repo default — set up a feature worktree/branch first (that's the caller's job, not this skill's)")
fi

dirty=false
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  dirty=true
  warnings+=("worktree has uncommitted changes — confirm they belong to this work before adding to them")
fi

ok=true; [ "${#errors[@]}" -gt 0 ] && ok=false

jq -nc \
  --argjson ok "$ok" \
  --arg branch "$CURRENT_BRANCH" \
  --arg default_branch "$default_branch" \
  --argjson detached "$detached" \
  --argjson dirty "$dirty" \
  --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson warnings "$(printf '%s\n' "${warnings[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  '{ok:$ok, branch:$branch, default_branch:$default_branch, detached:$detached, dirty:$dirty, errors:$errors, warnings:$warnings}'
