#!/usr/bin/env bash
# extract-contract.sh — surface the implementer's contract from an issue body.
#
# WHY: an issue authored by /zeus:propose is an agent-ready spec — it carries a
# ## Verification block, MUST / MUST NOT invariants, and acceptance criteria on
# purpose, "when the issue will be implemented by an agent". This pulls those out
# so create-pr's issue-contract verify gate (run when a PR has a linked issue, no
# matter who wrote the code) has something concrete to run and check against. It is
# an AID, not a gate itself: the agent still reads the whole body for intent. has_contract is
# false for a thin ticket with none of these — then the agent infers acceptance from
# the prose and says so.
#
# Heuristics (markdown, best-effort):
#   - verification : lines under a "## Verification" heading, until the next "## ".
#   - invariants   : any line containing MUST / MUST NOT (the RFC-2119 layer /zeus:propose
#                    writes load-bearing rules in), tagged with polarity.
#   - acceptance   : lines under "## Acceptance" / "Acceptance Criteria", plus a
#                    "Closes-when:" line if present.
#
# Portability: case-insensitive heading match is done with tolower()+index (BSD awk
# has no IGNORECASE), and every grep is guarded so a no-match never aborts under
# `set -e` / pipefail.
#
# Usage:  extract-contract.sh <body-file>     (or pipe the body on stdin)
# Output: {has_contract, verification:[...], invariants:[{rule,polarity}], acceptance:[...], closes_when}

set -euo pipefail

body=""
if [ "$#" -ge 1 ] && [ -f "$1" ]; then body=$(cat "$1"); else body=$(cat); fi

# Lines under a "## " heading whose text contains $1 (case-insensitive), up to the
# next "## " heading. tolower()+index keeps it working on BSD awk (no IGNORECASE).
section() {
  local want_lc; want_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  printf '%s\n' "$body" | awk -v want="$want_lc" '
    /^##[[:space:]]/ { grab = (index(tolower($0), want) > 0) ? 1 : 0; next }
    grab && NF { print }
  '
}

# Strip list/checkbox markers and trailing space; awk NF drops blank lines (never errors).
clean() { sed -E 's/^[[:space:]]*(- \[[ xX]\]|\[[ xX]\]|[-*]|[0-9]+\.)[[:space:]]*//; s/[[:space:]]+$//'; }
# awk dedups order-preserving so a Closes-when line caught by both the section scan
# and the explicit grep below lands once, not twice.
to_json_array() { clean | awk 'NF && !seen[$0]++' | jq -R . | jq -s .; }

verification=$(section 'verification' | to_json_array)
acceptance=$( { section 'acceptance'; printf '%s\n' "$body" | { grep -iE '^[[:space:]]*[*-]?[[:space:]]*Closes-?when' || true; }; } | to_json_array)

invariants=$(printf '%s\n' "$body" \
  | { grep -E '\bMUST( NOT)?\b' || true; } \
  | sed -E 's/^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]*//; s/[[:space:]]+$//' \
  | awk 'NF' \
  | jq -R '{rule: ., polarity: (if test("MUST NOT") then "forbid" else "require" end)}' \
  | jq -s .)

closes_when=$(printf '%s\n' "$body" | { grep -iE 'Closes-?when' || true; } | head -1 | sed -E 's/.*[Cc]loses-?when:?[[:space:]]*//')

has_contract=false
if [ "$(printf '%s' "$verification" | jq 'length')" -gt 0 ] \
   || [ "$(printf '%s' "$invariants" | jq 'length')" -gt 0 ] \
   || [ "$(printf '%s' "$acceptance" | jq 'length')" -gt 0 ]; then
  has_contract=true
fi

jq -nc \
  --argjson has_contract "$has_contract" \
  --argjson verification "$verification" \
  --argjson invariants "$invariants" \
  --argjson acceptance "$acceptance" \
  --arg closes_when "$closes_when" \
  '{has_contract:$has_contract, verification:$verification, invariants:$invariants, acceptance:$acceptance, closes_when:$closes_when}'
