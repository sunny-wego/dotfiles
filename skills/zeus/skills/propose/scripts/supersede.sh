#!/usr/bin/env bash
# supersede.sh — the deterministic supersession sequence, in one call:
#   1. create the NEW issue (via post-issue.sh)
#   2. comment "Superseded by #<new>" on the OLD issue
#   3. close the OLD issue
#
# Use when a decision changed enough that editing in place would erase the record
# of the prior decision. (For decision-unchanged edits, amend instead — re-render
# from state + Amendment Log; no new issue.) The new body should already contain
# "Supersedes #<old>" — the script warns if it doesn't.
#
# Usage:
#   supersede.sh --old <N> --title <t> --body-file <path> [--repo o/n] [--label l]... [--state f]
#
# Prints the new issue URL. Linking/closing the old issue is best-effort and never
# undoes the newly created issue.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
old=""; title=""; body_file=""; repo=""; state_file=""; labels=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --old) old="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --label) labels+=("$2"); shift 2 ;;
    --state) state_file="$2"; shift 2 ;;
    *) echo "supersede.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$old" ] || [ -z "$title" ] || [ -z "$body_file" ]; then
  echo "usage: supersede.sh --old <N> --title <t> --body-file <path> [--repo o/n] [--label l] [--state f]" >&2
  exit 1
fi
[ -f "$body_file" ] || { echo "supersede.sh: body file not found: $body_file" >&2; exit 1; }
grep -qE "Supersedes #${old}([^0-9]|$)" "$body_file" \
  || echo "supersede.sh: warning — new body does not mention 'Supersedes #${old}'" >&2

# 1. Create the new issue.
post_args=(--title "$title" --body-file "$body_file")
[ -n "$repo" ] && post_args+=(--repo "$repo")
[ -n "$state_file" ] && post_args+=(--state "$state_file")
for l in "${labels[@]:-}"; do [ -n "$l" ] && post_args+=(--label "$l"); done
new_url=$(bash "$script_dir/post-issue.sh" "${post_args[@]}")
echo "$new_url"
new_num=$(printf '%s\n' "$new_url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+$' | head -1)

# 2 + 3. Link + close the old issue (best-effort).
if [ -n "$new_num" ]; then
  c=(issue comment "$old" --body "Superseded by #${new_num}"); [ -n "$repo" ] && c+=(--repo "$repo")
  gh "${c[@]}" >/dev/null 2>&1 || echo "supersede.sh: warning — could not comment on #$old" >&2
  x=(issue close "$old"); [ -n "$repo" ] && x+=(--repo "$repo")
  gh "${x[@]}" >/dev/null 2>&1 || echo "supersede.sh: warning — could not close #$old" >&2
fi
