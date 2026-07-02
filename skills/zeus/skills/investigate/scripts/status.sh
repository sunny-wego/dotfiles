#!/usr/bin/env bash
# Bird's-eye for the active investigation.
#
# Usage: status.sh [--write]
#   status.sh            → print the bird's-eye to the terminal (read-only).
#   status.sh --write    → ALSO re-render the managed PROGRESS block in the
#                          investigation issue body, in place.
#
# Why --write exists: the progress rollup (sub-issue bar + work-items-by-state)
# is fully derivable from GitHub, yet on a long investigation people hand-maintain
# it in the issue body (the #717 pain). --write regenerates ONLY the region between
#   <!-- investigate:managed:start -->  …  <!-- investigate:managed:end -->
# so the human-owned zone (health table with live links, narrative, closing
# criteria) is never touched. Health metrics need external queries the script
# can't run — those stay human-owned by design.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq

write=0
[ "${1:-}" = "--write" ] && write=1

epic="$(active_epic)"
[ -n "$epic" ] || { echo "No active investigation in this worktree. Run /zeus:investigate new (or this may be a fresh worktree — search open 'investigation' issues)."; exit 0; }
slug="$(repo_slug)"; proj="$(state_get '.project')"
pm="$(state_get '.report')"; [ -z "$pm" ] && pm="$(state_get '.postmortem')"  # .postmortem: pre-rename state

# --- derive the rollup (the part GitHub knows), grouped by kind ---
summary="$(gh api "repos/$slug/issues/$epic" --jq '"\(.sub_issues_summary.completed)/\(.sub_issues_summary.total) done (\(.sub_issues_summary.percent_completed)%)"' 2>/dev/null || echo "none linked yet")"
subs="$(gh api "repos/$slug/issues/$epic/sub_issues" 2>/dev/null || echo '[]')"
cnt() { printf '%s' "$subs" | jq "$1" 2>/dev/null || echo 0; }
hopen=$(cnt '[.[]|select(any(.labels[]?.name;.=="hypothesis"))|select(.state=="open")]|length')
hconf=$(cnt '[.[]|select(any(.labels[]?.name;.=="hypothesis"))|select(any(.labels[]?.name;.=="confirmed"))]|length')
hout=$(cnt  '[.[]|select(any(.labels[]?.name;.=="hypothesis"))|select(any(.labels[]?.name;.=="refuted" or .=="inconclusive"))]|length')
ropen=$(cnt '[.[]|select(any(.labels[]?.name;.=="remediation"))|select(.state=="open")]|length')
rship=$(cnt '[.[]|select(any(.labels[]?.name;.=="remediation"))|select(.state=="closed")]|length')
rows="$(printf '%s' "$subs" | jq -r '.[] |
  (if any(.labels[]?.name;.=="hypothesis") then "🔬" elif any(.labels[]?.name;.=="remediation") then "🔧" else "•" end) as $c |
  (if .state=="closed" then "✅" else "⬜" end) as $s |
  "| \($c) \($s) | #\(.number) \(.title) |"' 2>/dev/null || true)"

# --- terminal bird's-eye (always) ---
echo "Investigation #$epic  ($slug)"
gh issue view "$epic" --json title,state --jq '"  \(.state)  \(.title)"'
echo
echo "Sub-issues: $summary"
echo "Hypotheses: $hopen open · $hconf confirmed · $hout ruled out      Remediation: $ropen open · $rship shipped"
echo "Items (🔬 hypothesis · 🔧 remediation · • other):"
printf '%s\n' "$rows" | sed -E 's/^\| (.+) \| (.*) \|$/  \1 \2/' | grep . || echo "  (none)"
echo
[ -n "$pm" ] && echo "Report: $pm"
[ -n "$proj" ] && echo "Board view:  filter parent-issue:$slug#$epic on Project #$proj"
echo "Health: see the dashboard links in the issue body (live)."

[ "$write" -eq 1 ] || exit 0

# --- --write: re-render the managed progress block in the issue body ---
S="<!-- investigate:managed:start -->"
E="<!-- investigate:managed:end -->"
body="$(gh issue view "$epic" --json body --jq .body)"
if ! printf '%s' "$body" | grep -qF "$S" || ! printf '%s' "$body" | grep -qF "$E"; then
  log "issue #$epic has no managed block ($S … $E) — not writing. Add the markers (the 'new' template includes them) to enable --write."
  exit 0
fi

block="### 🗂️ Progress — *auto-rendered by \`/zeus:investigate status --write\`; do not edit between the markers*

**Sub-issues:** $summary
**Hypotheses:** $hopen open · $hconf confirmed · $hout ruled out
**Remediation:** $ropen open · $rship shipped

| | Work item (🔬 hypothesis · 🔧 remediation · • other) |
|---|---|
$( [ -n "$rows" ] && printf '%s\n' "$rows" || echo "| | _(none linked yet)_ |" )"

# Splice: replace everything between the markers with $block (markers preserved).
# The block is multi-line, so feed it to awk via a file + getline — `awk -v` mangles
# multi-line values (BSD awk truncates at the first newline).
blkf="$(mktemp)"; printf '%s\n' "$block" > "$blkf"
newbody="$(printf '%s\n' "$body" | awk -v s="$S" -v e="$E" -v bf="$blkf" '
  index($0, s) { print; while ((getline ln < bf) > 0) print ln; close(bf); skip=1; next }
  index($0, e) { skip=0; print; next }
  !skip { print }
')"
rm -f "$blkf"

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] would re-render managed block of issue #$epic:" >&2
  printf '%s\n' "$block" >&2
  exit 0
fi
bf="$(mktemp)"; printf '%s\n' "$newbody" > "$bf"
# Idempotent backfill: normally a no-op (the tag rides along from epic creation,
# outside the managed block), but ensures coverage on epics that predate the tag.
bash "$HERE/watermark.sh" investigate --in-place "$bf" 2>/dev/null || true
gh issue edit "$epic" --body-file "$bf" >/dev/null && log "re-rendered managed progress block on #$epic"
