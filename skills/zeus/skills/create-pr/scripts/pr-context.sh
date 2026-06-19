#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  pr-context.sh <create|refresh> [pr_number|url|branch]
USAGE
  exit 1
}

mode="${1:-}"
target="${2:-}"

[ -n "$mode" ] || usage
case "$mode" in
  create|refresh) ;;
  *) usage ;;
esac

pr_json=$(detect_pr_json "$target" || true)
has_pr=false
if [ -n "$pr_json" ] && [ "$pr_json" != "null" ]; then
  has_pr=true
else
  pr_json='null'
fi

base_branch=$(detect_base_branch "$pr_json")
base_ref=$(resolve_base_ref "$base_branch")
merge_base=$(compute_merge_base "$base_ref")
range="$merge_base..HEAD"

status_porcelain=$(git status --porcelain=v1)
dirty=false
[ -n "$status_porcelain" ] && dirty=true

files_json=$(git diff --name-status "$merge_base" HEAD | jq -R -s '
  split("\n")
  | map(select(length > 0))
  | map(split("\t"))
  | map({status: .[0], path: (.[1] // "")})
')

diffstat_json=$(git diff --stat "$merge_base" HEAD | jq -R -s '
  split("\n")
  | map(select(length > 0))
')

commits_json=$(git log "$merge_base"..HEAD --pretty=format:'%H%x09%h%x09%s' | jq -R -s '
  split("\n")
  | map(select(length > 0))
  | map(split("\t"))
  | map({sha: .[0], short_sha: .[1], subject: .[2]})
')

areas_json=$(echo "$files_json" | jq '
  map(.path | split("/") | .[0])
  | map(select(length > 0))
  | unique
')

repo_dirs_json=$(cd "$REPO_ROOT" && find . -maxdepth 2 -not -path '*/.*' -type d | sed 's#^\./##' | jq -R -s '
  split("\n")
  | map(select(length > 0 and . != "."))
')

worktree_json=$(printf '%s\n' "$status_porcelain" | jq -R -s '
  split("\n")
  | map(select(length > 0))
  | map({status: .[0:2], path: .[3:]})
')

jq -nc \
  --arg mode "$mode" \
  --arg repo_root "$REPO_ROOT" \
  --arg current_branch "$CURRENT_BRANCH" \
  --arg base_branch "$base_branch" \
  --arg base_ref "$base_ref" \
  --arg merge_base "$merge_base" \
  --arg range "$range" \
  --arg managed_start "$MANAGED_START" \
  --arg managed_end "$MANAGED_END" \
  --argjson has_pr "$has_pr" \
  --argjson pr "$pr_json" \
  --argjson dirty "$dirty" \
  --argjson files "$files_json" \
  --argjson diffstat "$diffstat_json" \
  --argjson commits "$commits_json" \
  --argjson areas "$areas_json" \
  --argjson repo_dirs "$repo_dirs_json" \
  --argjson worktree "$worktree_json" \
  '{
    mode: $mode,
    repo_root: $repo_root,
    current_branch: $current_branch,
    base_branch: $base_branch,
    base_ref: $base_ref,
    merge_base: $merge_base,
    range: $range,
    has_pr: $has_pr,
    pr: $pr,
    dirty_worktree: $dirty,
    branch_files: $files,
    diffstat: $diffstat,
    commits: $commits,
    changed_areas: $areas,
    repo_dirs: $repo_dirs,
    worktree_status: $worktree,
    markers: {
      managed_start: $managed_start,
      managed_end: $managed_end
    }
  }'
