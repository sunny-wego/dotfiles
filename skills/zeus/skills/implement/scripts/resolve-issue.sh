#!/usr/bin/env bash
# resolve-issue.sh — find the issue this run should implement, and fetch it.
#
# WHY: implement turns an issue into code, so step one is "which issue?" The
# answer comes from the strongest available signal, in order:
#   1. explicit arg — a #N, a bare number, or an issue URL the user named.
#   2. journey.json .issue — the per-worktree handoff fact written by /zeus:propose or
#      /zeus:investigate when they created the issue in THIS worktree. This is the
#      seamless path: propose an issue, then "implement it" with no number.
#   3. none — nothing to go on; the agent should ask the user for the issue.
#
# It then fetches the issue body, which IS the spec (body == render(state)): the
# acceptance criteria, MUST/MUST NOT invariants, and Verification block the
# implementer must satisfy. Labels/author come along so the agent can tell a
# /zeus:propose decision doc from an /zeus:investigate remediation bug and weight accordingly.
#
# Fetch failures fail safe: determined:false so the caller asks rather than guesses.
#
# Usage:  resolve-issue.sh [<#N | number | url>] [--repo <owner/name>]
# Output: {number,url,title,body,labels,author,state,source,determined}

set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

arg=""; repo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) arg="$1"; shift ;;
  esac
done

# Normalise an explicit arg to a bare number (accepts "#840", "840", or a URL).
num=""
if [ -n "$arg" ]; then
  num=$(printf '%s' "$arg" | grep -oE '[0-9]+' | tail -1 || true)
  source="arg"
fi

# Fall back to the journey handoff store.
if [ -z "$num" ]; then
  num=$(bash "$script_dir/journey.sh" issue-number 2>/dev/null || true)
  [ -n "$num" ] && source="journey"
fi

if [ -z "$num" ]; then
  jq -nc '{number:null, source:"none", determined:false,
           reason:"no issue given and none recorded in journey.json — ask the user for the issue number"}'
  exit 0
fi

view=(issue view "$num" --json number,title,body,url,labels,author,state)
[ -n "$repo" ] && view+=(--repo "$repo")
raw=$(gh "${view[@]}" 2>/dev/null || echo "")

if [ -z "$raw" ]; then
  jq -nc --argjson n "$num" --arg s "$source" \
    '{number:$n, source:$s, determined:false,
      reason:("could not fetch issue #"+($n|tostring)+" — wrong repo, or it does not exist")}'
  exit 0
fi

printf '%s' "$raw" | jq -c --arg s "$source" '{
  number, url, title, body, state,
  labels: [.labels[].name],
  author: .author.login,
  source: $s,
  determined: true
}'
