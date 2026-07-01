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
# Output: {"required":bool,"mode":"auto|always|never","reasons":[...],"build_ready_required":bool}
#         (build_ready_required = the execution axis: a merge-closing work-order
#          whose contract is still prose — see the build-ready block below)
# Exit:   0 always (the JSON carries the verdict; post-issue interprets it)

set -euo pipefail

state="${1:?Usage: requires-review.sh <state-file>}"
[ -f "$state" ] || { echo "requires-review.sh: state file not found: $state" >&2; exit 2; }

mode=$(jq -r '.review // "auto"' "$state")

# ── build-ready axis (independent of the review/align axis) ───────────────────
# The review axis (below) gates DISCUSSION readiness. But a merge-closing
# implementation issue is ALSO a work-order an agent executes — and can pass every
# review gate with its load-bearing contract left as prose (issue #988). Derive a
# SEPARATE trigger so Stage 1 also runs the implementer persona. Fire when the
# issue closes on a PR MERGE (a work-order — a decision doc closes on alignment)
# AND carries code signals (a source-file citation, an apps/src/lib/packages path,
# or a versioned route) AND has no MUST/MUST NOT yet (invariants already present ⇒
# the author did the contract work; don't nag). Surfaced in every output; enforced
# — as a consent-nudge, not a block — by review-gate.sh.
cw=$(jq -r '.closes_when // ""' "$state")
allprose=$(jq -r '[ .proposal // "", (.sections // [] | map(.body // "") | join("\n")) ] | join("\n")' "$state")
build_ready_required=false
if printf '%s' "$cw" | grep -qiE '\bmerge|\bpull request\b' \
   && printf '%s' "$allprose" | grep -qE '`[A-Za-z0-9_./-]+\.(ts|tsx|js|jsx|py|go|rs|sql|sh)`|(^|[^A-Za-z])(apps|src|lib|packages)/|/v[0-9]+/' \
   && ! printf '%s' "$allprose" | grep -qE 'MUST( NOT)?\b'; then
  build_ready_required=true
fi

# Merge the build axis into every verdict, then exit. Computed above the mode
# switch so `always`/`never`/`auto` all carry it.
emit() { printf '%s' "$1" | jq -c --argjson br "$build_ready_required" '. + {build_ready_required: $br}'; exit 0; }

case "$mode" in
  always) emit '{"required": true, "mode": "always", "reasons": ["review: \"always\" set in state"]}' ;;
  never)  emit '{"required": false, "mode": "never", "reasons": ["review: \"never\" set in state — MUST be surfaced in the confirmation dialog"]}' ;;
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
  emit "$(printf '%s\n' "${reasons[@]}" | jq -Rcs '{required: true, mode: "auto", reasons: (split("\n") | map(select(length > 0)))}')"
else
  emit '{"required": false, "mode": "auto", "reasons": ["no questions, no grounded claims, short proposal, no invariants"]}'
fi
