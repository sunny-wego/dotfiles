#!/usr/bin/env bash
# Fetch logs from failed GitHub Actions runs for a branch.
# Outputs: JSON array of { run_id, name, failed_jobs, log }
#
# Usage: fetch-failed-logs.sh <branch> [commit_sha]
#   commit_sha defaults to HEAD if omitted

set -euo pipefail

branch="$1"
commit="${2:-$(git rev-parse HEAD)}"

# Find failed runs for this branch at the current commit (most recent 5)
# Filtering by commit prevents returning stale failures from previous pushes.
runs=$(gh run list --branch "$branch" --commit "$commit" --status failure --limit 5 \
  --json databaseId,name,conclusion \
  --jq '[.[] | {run_id: .databaseId, name: .name}]')

count=$(echo "$runs" | jq 'length')

if [ "$count" -eq 0 ]; then
  echo '[]'
  exit 0
fi

results="[]"

for i in $(seq 0 $((count - 1))); do
  run_id=$(echo "$runs" | jq -r ".[$i].run_id")
  name=$(echo "$runs" | jq -r ".[$i].name")

  # Get failed jobs and their failed steps
  failed_jobs=$(gh run view "$run_id" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure") | {name: .name, id: .databaseId, failed_steps: [.steps[] | select(.conclusion == "failure") | .name]}]' 2>/dev/null || echo '[]')

  # Fetch failed logs (last 200 lines to avoid blowing up context)
  log=$(gh run view "$run_id" --log-failed 2>/dev/null | tail -200 || echo "(no logs available)")

  results=$(echo "$results" | jq \
    --argjson run_id "$run_id" \
    --arg name "$name" \
    --argjson failed_jobs "$failed_jobs" \
    --arg log "$log" \
    '. + [{run_id: $run_id, name: $name, failed_jobs: $failed_jobs, log: $log}]')
done

echo "$results"
