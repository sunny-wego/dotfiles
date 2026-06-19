#!/usr/bin/env bash
# requires-review.sh — does this issue's state warrant the review pipeline
# (Stage 1 reviewer simulation, hash stamp, Stage 2 grounding)?
#
# WHY: review used to be armed by a self-declared `depth: "rfc"` label — set by
# the same author whose blind spots the gates exist to check, so an unlabeled
# decision doc got ZERO enforcement. Instead, the trigger is DERIVED from what
# the document actually contains: the things that make an issue need review
# (open questions, empirical claims, a substantial proposal, binding invariants)
# are the things that trigger it. A tracking ticket has none → stages skip
# themselves. Both the agent (deciding to run Stage 1) and post-issue.sh (the
# hard gate) call THIS script, so decision and enforcement cannot drift.
#
# Override field `review` in state:
#   "auto"   (default) — derive from content (below)
#   "always" — force review regardless of content
#   "never"  — explicit skip; legitimate for paste-dump tracking issues, but it
#              MUST be surfaced in the pre-post confirmation (a visible choice,
#              never a silent one)
#
# Derivation (auto): any of —
#   - discussion_questions non-empty   (open decisions → discussability matters)
#   - code_grounding non-empty         (empirical claims → grounding matters)
#   - >200 words across proposal+sections+banner   (substantial design prose)
#   - MUST/MUST NOT in that prose       (binding invariants an agent will obey)
#
# Usage:  requires-review.sh <state-file>
# Output: {"required":bool,"mode":"auto|always|never","reasons":[...]}
# Exit:   0 always (the JSON carries the verdict; post-issue interprets it)

set -euo pipefail

state="${1:?Usage: requires-review.sh <state-file>}"
[ -f "$state" ] || { echo "requires-review.sh: state file not found: $state" >&2; exit 2; }

mode=$(jq -r '.review // "auto"' "$state")

case "$mode" in
  always) jq -nc '{required: true, mode: "always", reasons: ["review: \"always\" set in state"]}'; exit 0 ;;
  never)  jq -nc '{required: false, mode: "never", reasons: ["review: \"never\" set in state — MUST be surfaced in the confirmation dialog"]}'; exit 0 ;;
  auto) ;;
  *) echo "requires-review.sh: unknown review mode '$mode' (auto|always|never)" >&2; exit 2 ;;
esac

reasons=()
q=$(jq -r '.discussion_questions | length' "$state")
[ "$q" -gt 0 ] && reasons+=("$q discussion question(s)")
g=$(jq -r '.code_grounding | length' "$state")
[ "$g" -gt 0 ] && reasons+=("$g grounded claim(s)")
# Design prose = proposal + every custom section body + the discussion banner, so
# content moved OUT of `proposal` into first-class `sections` still arms review.
prose=$(jq -r '[ .proposal // "", (.sections // [] | map(.body // "") | join("\n")), .discussion_banner // "" ] | join("\n")' "$state")
w=$(printf '%s' "$prose" | wc -w | tr -d ' ')
[ "$w" -gt 200 ] && reasons+=("substantial design prose ($w words)")
if printf '%s' "$prose" | grep -qE 'MUST( NOT)?\b'; then
  reasons+=("binding MUST/MUST NOT invariants")
fi

if [ "${#reasons[@]}" -gt 0 ]; then
  printf '%s\n' "${reasons[@]}" | jq -Rcs '{required: true, mode: "auto", reasons: (split("\n") | map(select(length > 0)))}'
else
  jq -nc '{required: false, mode: "auto", reasons: ["no questions, no grounded claims, short proposal, no invariants"]}'
fi
