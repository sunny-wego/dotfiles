#!/usr/bin/env bash
# find-failed-vercel-checks.sh — return failed Vercel/Preview check entries
# for a PR as JSON. Used by handlers/vercel.md so the handler doesn't carry
# inline `gh pr checks ... | jq` pipelines.
#
# Usage:  find-failed-vercel-checks.sh --pr <n> [--repo <owner/repo>]
#   (identifiers also accepted positionally.)
# Output: JSON array of {name, state, link, completedAt}.
#
# Exit codes:
#   0  one or more failed checks; JSON array printed (length >= 1)
#   0  no failed checks; "[]" printed (caller decides whether that's success)
#   1  invocation error

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

resolve_target "$@"
pr="$PR"; repo="$REPO_SLUG"
[ -n "$pr" ] || { echo "Usage: find-failed-vercel-checks.sh --pr <n> [--repo <owner/repo>]" >&2; exit 1; }

# shellcheck disable=SC2054  # gh --json field list, one arg
args=(pr checks "$pr" --json name,state,link,completedAt)
[ -n "$repo" ] && args+=(--repo "$repo")

gh "${args[@]}" \
  --jq '[.[]
    | select((.name // "") | test("vercel|preview"; "i"))
    | select(.state == "FAILURE")
  ]'
