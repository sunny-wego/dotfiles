#!/usr/bin/env bash
# Open a hypothesis as a sub-issue of the active investigation.
#
#   hypothesis.sh "<claim>"
#
# Titles it "H<k>: <claim>" (k = next free, derived from the investigation's
# existing hypothesis sub-issues — no local map, no drift), labels it
# `hypothesis`, and attaches it as a native sub-issue (so it rides the progress
# bar). Honours DRY_RUN=1. Prints "H<k> #<num>".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq

claim="${1:?usage: hypothesis.sh \"<claim>\"}"
epic="$(active_epic)"; [ -n "$epic" ] || die "no active investigation (run /zeus:investigate new)"
slug="$(repo_slug)"

# Next H<k>: max over existing hypothesis sub-issue titles "H<k>:".
maxk="$(gh api "repos/$slug/issues/$epic/sub_issues" --jq '.[].title' 2>/dev/null \
  | grep -oE '^H[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
k=$(( ${maxk:-0} + 1 ))
title="H$k: $claim"

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] gh issue create --title \"$title\" --label hypothesis  (then attach as sub-issue of #$epic)" >&2
  echo "H$k"; exit 0
fi

body="Hypothesis under investigation #$epic.

Evidence accrues as \`E<n>\` items (tagged \`(H$k, supports|refutes)\`). Conclude with:
\`/zeus:investigate conclude H$k confirmed|refuted|inconclusive\`."
num="$(create_labeled_issue "$title" hypothesis "$body" "an investigation hypothesis")"
log "opened $title — #$num"
"$HERE/link-to-epic.sh" "$num" >/dev/null 2>&1 || log "could not auto-link #$num — run /zeus:investigate link $num"
echo "H$k #$num"
