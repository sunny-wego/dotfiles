#!/usr/bin/env bash
# extract-sections.sh — parse a plan / proposal source and emit a JSON
# structure the issue scaffolder consumes. Mirrors create-pr's
# seed-from-issue.sh but runs against arbitrary plan markdown (not the
# fixed grammar /zeus:propose itself writes).
#
# Recognised sections (any subset may be missing):
#   ## Context                        → context
#   ## Proposal / Approach            → proposal
#   ## What's Excluded                → whats_excluded (array of bullets)
#   ## Verification / Acceptance      → verification (array of bullets)
#   ## Discussion questions           → discussion_questions (array of
#                                       {q, options, default_lean, is_draft})
#   ## References                     → references (array of bullets)
#   ```mermaid                        → mermaid (verbatim block)
#
# Usage:  extract-sections.sh <source-path>
# Output: compact JSON. Missing sections render as "" / [] so consumers
# can splat into a state file without conditionals.

set -euo pipefail

src="${1:?Usage: extract-sections.sh <source-path>}"
[ -f "$src" ] || { echo "extract-sections: source not found: $src" >&2; exit 1; }

body=$(cat "$src")

extract_section() {
  local heading="$1"
  printf '%s\n' "$body" | awk -v h="$heading" '
    BEGIN { in_section = 0 }
    {
      if (match($0, /^##[[:space:]]+/) && substr($0, RLENGTH+1) ~ "^"h"[[:space:]]*$") {
        in_section = 1
        next
      }
      if (in_section && /^##[[:space:]]+/) exit
      if (in_section) print
    }
  '
}

# Collapse multi-line text into a single inline value (Context, Proposal).
collapse_inline() {
  awk 'NF' | sed -E 's/^[[:space:]]*[-*][[:space:]]*//' \
    | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
}

# Render a section's bullet list as a JSON array of trimmed strings.
section_to_array() {
  local section="$1"
  printf '%s\n' "$section" \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/^[[:space:]]*[0-9]+\.[[:space:]]+//' \
    | awk 'NF' \
    | jq -R -s 'split("\n") | map(select(length > 0))'
}

context=$(extract_section "Context" | collapse_inline)
proposal=$(extract_section "Proposal" | collapse_inline)
[ -z "$proposal" ] && proposal=$(extract_section "Proposal / Approach" | collapse_inline)

excluded_section=$(extract_section "What's Excluded")
[ -z "$excluded_section" ] && excluded_section=$(extract_section "Whats Excluded")
whats_excluded=$(section_to_array "$excluded_section")

verification_section=$(extract_section "Verification / Acceptance")
[ -z "$verification_section" ] && verification_section=$(extract_section "Verification")
verification=$(section_to_array "$verification_section")

references=$(section_to_array "$(extract_section "References")")

# Discussion questions: a sequence of `### Q\d+ — <question>` blocks with
# an optional table and a `**Default lean:** <X>` line.
discussion_section=$(extract_section "Discussion questions")
discussion_questions=$(printf '%s\n' "$discussion_section" | awk '
  BEGIN { print "[" ; first = 1 }
  function flush() {
    if (q == "") return
    if (!first) print ","
    first = 0
    gsub(/"/, "\\\"", q)
    gsub(/"/, "\\\"", lean)
    printf "{\"q\": \"%s\", \"default_lean\": \"%s\", \"is_draft\": %s}", q, lean, (is_draft ? "true" : "false")
    q = ""; lean = ""; is_draft = 0
  }
  /^###[[:space:]]+Q[0-9]+/ {
    flush()
    line = $0
    sub(/^###[[:space:]]+/, "", line)
    sub(/^Q[0-9]+[[:space:]]*[—-][[:space:]]*/, "", line)
    q = line
    next
  }
  /^\*\*Default lean:\*\*/ {
    lean = $0
    sub(/^\*\*Default lean:\*\*[[:space:]]*/, "", lean)
    # Record draft status from the marker, then strip it — scaffold-draft
    # appends a fresh `[draft]` based on is_draft so we never double-tag.
    is_draft = (index(lean, "[draft]") > 0 ? 1 : 0)
    sub(/[[:space:]]*\[draft\][[:space:]]*$/, "", lean)
  }
  END { flush(); print "]" }
')

# Mermaid: first fenced ```mermaid block (verbatim).
mermaid=$(printf '%s\n' "$body" | awk '
  /^```mermaid[[:space:]]*$/ { in_block = 1; next }
  in_block && /^```[[:space:]]*$/ { exit }
  in_block { print }
')

jq -nc \
  --arg context "$context" \
  --arg proposal "$proposal" \
  --argjson whats_excluded "${whats_excluded:-[]}" \
  --argjson verification "${verification:-[]}" \
  --argjson references "${references:-[]}" \
  --argjson discussion_questions "${discussion_questions:-[]}" \
  --arg mermaid "$mermaid" \
  '{
    context: $context,
    proposal: $proposal,
    whats_excluded: $whats_excluded,
    verification: $verification,
    references: $references,
    discussion_questions: $discussion_questions,
    mermaid: $mermaid
  }'
