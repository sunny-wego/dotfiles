#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  original-intent.sh capture <pr_number>
  original-intent.sh parse <body-file|->
  original-intent.sh read
USAGE
  exit 1
}

read_body() {
  local source="$1"

  if [ "$source" = "-" ]; then
    cat
  else
    cat "$source"
  fi
}

# The "## Original Intent" section grammar (extract + Purpose/Scope/Non-goals parse)
# is owned by lib/original-intent.sh (sourced via lib.sh: oi_parse), shared with
# create-pr's emitter so writer and reader can't drift. This script layers the
# address-pr-specific concerns (Closes #N + linked-issue enrichment) on top.

extract_closes_number() {
  # Look for GitHub keyword variants in the PR body: closes / fixes / resolves
  # followed by #<N> (or owner/repo#<N>). Case-insensitive. Print the first
  # matched number. No match → empty.
  local source="$1"
  read_body "$source" | grep -iEo '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#?[0-9]+' \
    | head -1 | grep -oE '[0-9]+$' || true
}

enrich_from_issue() {
  # Given an issue number, fetch the issue body once and extract
  # exclusions (## What's Excluded as bullet list) and decisions
  # (resolved Default lean lines). Output is compact JSON or {}.
  local number="$1"
  local body exclusions decisions
  body=$(gh issue view "$number" --json body --jq '.body // ""' 2>/dev/null || echo "")
  if [ -z "$body" ]; then
    echo '{}'
    return 0
  fi

  exclusions=$(printf '%s\n' "$body" | awk '
    BEGIN { in_section = 0 }
    {
      if (match($0, /^##[[:space:]]+/) && substr($0, RLENGTH+1) ~ /^What.?s Excluded[[:space:]]*$/) {
        in_section = 1; next
      }
      if (in_section && /^##[[:space:]]+/) exit
      if (in_section) print
    }
  ' | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | awk 'NF' | jq -R -s 'split("\n") | map(select(length > 0))')

  decisions=$(printf '%s\n' "$body" | awk '
    BEGIN { in_section = 0; q = "" }
    /^##[[:space:]]+Discussion questions[[:space:]]*$/ { in_section = 1; next }
    in_section && /^##[[:space:]]+/ { exit }
    in_section && /^###[[:space:]]+Q[0-9]+/ {
      q = $0
      sub(/^###[[:space:]]+/, "", q)
      sub(/^Q[0-9]+[[:space:]]*[—-][[:space:]]*/, "", q)
      next
    }
    in_section && /^\*\*Default lean:\*\*/ {
      lean = $0
      sub(/^\*\*Default lean:\*\*[[:space:]]*/, "", lean)
      if (index(lean, "[draft]") == 0 && q != "") {
        printf("%s\t%s\n", q, lean)
      }
    }
  ' | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t") | {question: .[0], chosen: .[1]})')

  jq -nc --argjson exclusions "${exclusions:-[]}" --argjson decisions "${decisions:-[]}" \
    --arg number "$number" \
    '{number: ($number | tonumber? // $number), exclusions: $exclusions, decisions: $decisions}'
}

parse_source() {
  local source="$1"
  local body grammar present closes_number issue_enrichment

  body=$(read_body "$source")
  grammar=$(printf '%s' "$body" | oi_parse)          # shared grammar: {present[, section,purpose,scope,non_goals]}
  present=$(printf '%s' "$grammar" | jq -r '.present')
  closes_number=$(printf '%s' "$body" | extract_closes_number -)

  if [ "$present" != "true" ] && [ -z "$closes_number" ]; then
    jq -nc '{present: false}'
    return 0
  fi

  # Enrich with the linked issue once, only if Closes #N was found. The extra
  # `gh api` call is bounded to a single request; consumers see an `issue` field
  # with exclusions + decisions for richer scope-sensitive triage. Independence:
  # no Closes #N → no extra call → identical output.
  issue_enrichment='null'
  [ -n "$closes_number" ] && issue_enrichment=$(enrich_from_issue "$closes_number")

  # Layer the address-pr-specific `issue` onto the shared grammar object.
  printf '%s' "$grammar" | jq -c --argjson issue "$issue_enrichment" \
    '. + (if $issue != null then {issue: $issue} else {} end)'
}

cmd="${1:-}"
case "$cmd" in
  capture)
    [ "$#" -eq 2 ] || usage
    body=$(gh pr view "$2" --json body --jq '.body // ""')
    printf '%s' "$body" | parse_source - > "$ORIGINAL_INTENT_FILE"
    cat "$ORIGINAL_INTENT_FILE"
    ;;
  parse)
    [ "$#" -eq 2 ] || usage
    parse_source "$2"
    ;;
  read)
    [ -f "$ORIGINAL_INTENT_FILE" ] || { echo '{}'; exit 0; }
    cat "$ORIGINAL_INTENT_FILE"
    ;;
  *)
    usage
    ;;
esac
