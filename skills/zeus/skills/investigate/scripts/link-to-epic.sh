#!/usr/bin/env bash
# Tie a work item into the active investigation. Idempotent.
#
#   link-to-epic.sh <issue-number>     # attach issue as a native sub-issue of the Epic + board item
#   link-to-epic.sh --pr <pr-number>   # add the PR to the board (PRs can't be sub-issues)
#
# Reads the active Epic / project from journey state. Honours DRY_RUN=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq

is_pr=0
if [ "${1:-}" = "--pr" ]; then is_pr=1; shift; fi
num="${1:?usage: link-to-epic.sh [--pr] <number>}"

epic="$(active_epic)"; [ -n "$epic" ] || die "no active investigation in this worktree (run /zeus:investigate new)"
proj="$(state_get '.project')"
slug="$(repo_slug)"; owner="$(repo_owner)"

add_to_board() { # $1 = issue/PR url
  have_project_scope || { log "no project scope — skipping board (gh auth refresh -s project to enable)"; return 0; }
  [ -n "$proj" ] || { log "no project recorded in state — skipping board"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] gh project item-add $proj --owner $owner --url $1" >&2; return 0; fi
  gh project item-add "$proj" --owner "$owner" --url "$1" --format json >/dev/null \
    && log "added to board #$proj"
}

if [ "$is_pr" = "1" ]; then
  url="$(gh pr view "$num" --json url --jq .url)"
  add_to_board "$url"
  # If the PR closes a work item, make sure that item is a sub-issue of the Epic.
  closes="$(gh pr view "$num" --json body --jq '.body' | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
  [ -n "$closes" ] && { log "PR #$num closes #$closes — linking that as a sub-issue"; exec "$0" "$closes"; }
  log "PR #$num on the board; closing it will move the bar via its linked issue."
  exit 0
fi

# Issue path: attach as native sub-issue (no-op if already attached), then board.
already="$(gh api "repos/$slug/issues/$epic/sub_issues" --jq '.[].number' 2>/dev/null | grep -xc "$num" || true)"
if [ "$already" -gt 0 ]; then
  log "#$num already a sub-issue of #$epic"
else
  child_id="$(issue_rest_id "$num")"
  run gh api --method POST "repos/$slug/issues/$epic/sub_issues" -F "sub_issue_id=$child_id" >/dev/null \
    && log "linked #$num as sub-issue of #$epic"
fi
add_to_board "https://github.com/$slug/issues/$num"
