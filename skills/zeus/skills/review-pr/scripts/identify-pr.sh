#!/usr/bin/env bash
# identify-pr.sh — resolve a PR reference (URL, number, or number+repo) to its
# canonical metadata, with ONE network call. Pure resolution: no checkout, no
# state dir (runs pre-isolation, like address-pr's ensure-worktree).
#
# Usage:
#   identify-pr.sh https://github.com/<owner>/<repo>/pull/<n>
#   identify-pr.sh <n>                 # repo inferred from cwd via `gh repo view`
#   identify-pr.sh <n> --repo owner/repo
#
# Output JSON: { owner, repo, number, head_sha, base, url, title, foreign }
#   foreign = true when the PR's repo differs from the repo of the current cwd
#             (tells ensure-checkout.sh whether a worktree of cwd will work or a
#             clone is needed).
# Exit: 0 on success; non-zero with {"error": ...} on stderr otherwise.

set -euo pipefail

owner="" repo="" num="" slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) slug="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*) slug="${1#*=}"; shift ;;
    https://*|http://*)
      if [[ "$1" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[3]}"
      else
        echo "{\"error\": \"unrecognized PR URL: $1\"}" >&2; exit 2
      fi
      shift ;;
    *) if [[ "$1" =~ ^[0-9]+$ ]]; then num="$1"; elif [[ "$1" == */* ]]; then slug="$1"; fi; shift ;;
  esac
done

if [ -z "$num" ]; then
  echo '{"error": "no PR number or URL given. Pass a URL or a number (with --repo for a foreign repo)."}' >&2
  exit 2
fi
if [ -z "$owner" ] && [ -n "$slug" ]; then owner="${slug%%/*}"; repo="${slug#*/}"; fi
if [ -z "$owner" ]; then
  slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$slug" ] && { owner="${slug%%/*}"; repo="${slug#*/}"; }
fi
if [ -z "$owner" ] || [ -z "$repo" ]; then
  echo '{"error": "could not resolve owner/repo. Pass a URL or --repo owner/repo."}' >&2
  exit 2
fi

raw=$(gh pr view "$num" --repo "$owner/$repo" \
        --json number,headRefOid,baseRefName,url,title 2>/dev/null) || {
  echo "{\"error\": \"cannot view PR $num in $owner/$repo (gh auth / network / wrong repo?)\"}" >&2
  exit 1
}

cwd_slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
foreign=true
[ "$cwd_slug" = "$owner/$repo" ] && foreign=false

echo "$raw" | jq \
  --arg owner "$owner" --arg repo "$repo" --argjson foreign "$foreign" '{
    owner: $owner,
    repo: $repo,
    number: .number,
    head_sha: .headRefOid,
    base: .baseRefName,
    url: .url,
    title: .title,
    foreign: $foreign
  }'
