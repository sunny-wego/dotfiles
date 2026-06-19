#!/usr/bin/env bash
# issue-context.sh — gather repo, branch, and HEAD SHA context for propose.
# Output: single JSON object on stdout.

set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found in PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found in PATH" >&2
  exit 1
fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not inside a git repository" >&2
  exit 1
fi

repo_full=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

# Best-effort related-issues fetch: most-recent 10 open issues. The caller
# narrows by keyword. Failures are tolerated (network / auth / private repo).
related_issues_json=$(
  gh issue list --state open --limit 10 \
    --json number,title,url 2>/dev/null \
  || echo "[]"
)

jq -n \
  --arg repo "$repo_full" \
  --arg branch "$branch" \
  --arg head_sha "$head_sha" \
  --argjson related_issues "$related_issues_json" \
  '{
    repo: $repo,
    branch: $branch,
    head_sha: $head_sha,
    related_issues: $related_issues
  }'
