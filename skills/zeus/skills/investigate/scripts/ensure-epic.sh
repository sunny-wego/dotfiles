#!/usr/bin/env bash
# Create-or-locate the investigation issue, add it to the board, record state, and
# print the saved-view URL for the user to create (views are UI-only).
#
# Usage:
#   ensure-epic.sh --slug <slug> [--report <path>] [--title "..."] [--project <n>]
#
# If an investigation is already recorded in state, this is a no-op that re-prints
# the view URL. The report (--report) is OPTIONAL — investigations graduate to a
# durable report only when warranted. Honours DRY_RUN=1. Body from assets/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq
SKILL_DIR="$(cd "$HERE/.." && pwd)"

slug="" report="" title="" project=""
while [ $# -gt 0 ]; do case "$1" in
  --slug) slug="$2"; shift 2;;
  --report|--report) report="$2"; shift 2;;   # --report kept as an alias
  --title) title="$2"; shift 2;;
  --project) project="$2"; shift 2;;
  *) die "unknown arg: $1";;
esac; done
[ -n "$slug" ] || die "--slug required"

existing="$(active_epic)"
if [ -n "$existing" ]; then
  log "investigation already active: #$existing"; epic="$existing"
else
  [ -n "$title" ] || title="Investigation: $slug"
  body_tpl="$SKILL_DIR/assets/epic-dashboard.md"
  reposlug="$(repo_slug)"
  body="$(sed -e "s|{{SLUG}}|$slug|g" \
              -e "s|{{REPORT}}|${report:-(no report yet — \`/zeus:investigate report --open\` to add one)}|g" \
              -e "s|{{REPO}}|$reposlug|g" "$body_tpl")"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] gh issue create --title \"$title\" --label investigation  (body from template)" >&2
    epic="DRYRUN"
  else
    epic="$(create_labeled_issue "$title" investigation "$body" "tracked by /zeus:investigate")"
    log "created investigation #$epic"
  fi
fi

# Record state (private to this skill).
"$HERE/investigate-state.sh" set slug "$slug"
[ -n "$report" ] && "$HERE/investigate-state.sh" set report "$report"
[ "$epic" != "DRYRUN" ] && "$HERE/investigate-state.sh" set epic "$epic"
[ -n "$project" ] && "$HERE/investigate-state.sh" set project "$project"

# NOTE: no cross-skill journey publish. /zeus:investigate is general (not investigation-
# specific), so it does NOT auto-label sibling PRs. Fix PRs link in precisely via
# `remediate` (the bug's "Closes #N" + cross-refs), not a blunt active-investigation flag.

# Add the investigation issue to the board if we can.
proj="$(state_get '.project')"
[ "$epic" != "DRYRUN" ] && add_to_board "https://github.com/$(repo_slug)/issues/$epic"

# Print the per-investigation view URL to save (UI-only step).
if [ -n "$proj" ] && [ "$epic" != "DRYRUN" ]; then
  cat >&2 <<EOF

  ▶ Save this view once on Project #$proj (view creation is UI-only):
    New view → filter:  parent-issue:$(repo_slug)#$epic
    Layout: Board, group by Status.  Then paste its URL into the issue's board link.
EOF
fi
echo "$epic"
