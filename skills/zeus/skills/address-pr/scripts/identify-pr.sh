#!/usr/bin/env bash
# Identify the PR for the current branch, optionally checking out the PR branch.
# Outputs JSON: { number, branch, base, owner, repo, checked_out }
#
# owner/repo are the BASE repository (where the PR lives), not the head.
# This is correct for API calls (comments, checks, threads are on the base repo).
#
# Usage: identify-pr.sh [--checkout]
#   --checkout  if the current branch isn't the PR branch, switch to it

set -euo pipefail

do_checkout=false
if [ "${1:-}" = "--checkout" ]; then
  do_checkout=true
fi

raw=$(gh pr view --json number,headRefName,baseRefName,url 2>/dev/null) || {
  echo '{"error": "No pull request found for current branch. Create one with: gh pr create"}' >&2
  exit 1
}

pr_branch=$(echo "$raw" | jq -r '.headRefName')
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
checked_out=false

if [ "$do_checkout" = true ] && [ "$pr_branch" != "$current_branch" ]; then
  # Fetch + switch. Use gh pr checkout so fork PRs work.
  if gh pr checkout "$(echo "$raw" | jq -r '.number')" >/dev/null 2>&1; then
    checked_out=true
  else
    echo "{\"error\": \"failed to check out PR branch $pr_branch\"}" >&2
    exit 1
  fi
fi

echo "$raw" | jq --argjson checked_out "$checked_out" '{
  number: .number,
  branch: .headRefName,
  base: .baseRefName,
  owner: (.url | split("/")[3]),
  repo: (.url | split("/")[4]),
  checked_out: $checked_out
}'
