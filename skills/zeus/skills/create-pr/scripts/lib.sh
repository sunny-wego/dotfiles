#!/usr/bin/env bash
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "create-pr lib: not inside a git repository" >&2
  exit 1
fi

# shellcheck disable=SC2034  # REPO_ROOT/MANAGED_* are consumed by scripts that source this lib
REPO_ROOT="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
# shellcheck disable=SC2034
MANAGED_START='<!-- create-pr:managed:start -->'
# shellcheck disable=SC2034
MANAGED_END='<!-- create-pr:managed:end -->'

repo_default_branch() {
  gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
}

branch_merge_base() {
  if [ -n "$CURRENT_BRANCH" ]; then
    git config --get "branch.$CURRENT_BRANCH.gh-merge-base" 2>/dev/null || true
  fi
}

detect_pr_json() {
  local target="${1:-}"

  if [ -n "$target" ]; then
    gh pr view "$target" --json number,title,body,url,baseRefName,headRefName,isDraft 2>/dev/null
  else
    gh pr view --json number,title,body,url,baseRefName,headRefName,isDraft 2>/dev/null
  fi
}

detect_base_branch() {
  local pr_json="${1:-}"
  local configured=""

  if [ -n "$pr_json" ] && [ "$pr_json" != "null" ]; then
    echo "$pr_json" | jq -r '.baseRefName'
    return 0
  fi

  configured=$(branch_merge_base)
  if [ -n "$configured" ]; then
    echo "$configured"
    return 0
  fi

  repo_default_branch
}

resolve_base_ref() {
  local base_branch="$1"

  if git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    echo "origin/$base_branch"
  elif git show-ref --verify --quiet "refs/heads/$base_branch"; then
    echo "$base_branch"
  else
    echo "$base_branch"
  fi
}

compute_merge_base() {
  local base_ref="$1"
  local merge_base=""

  merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null || true)
  if [ -z "$merge_base" ]; then
    merge_base=$(git rev-list --max-parents=0 HEAD | tail -n1)
  fi

  echo "$merge_base"
}
