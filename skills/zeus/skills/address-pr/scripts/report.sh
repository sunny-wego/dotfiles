#!/usr/bin/env bash
# Render the final address-pr report from state.json + a fresh pr-status snapshot.
#
# Usage: report.sh   (no args; emits a human-readable summary on stdout by design)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

[ -f "$STATE_FILE" ] || { echo "report.sh: no state file at $STATE_FILE — nothing to report"; exit 0; }

state=$(cat "$STATE_FILE")
pr=$(echo "$state" | jq -r '.pr')
iteration=$(echo "$state" | jq -r '.iteration')
relevance=$(echo "$state" | jq -c '[.outcomes[] | select(.handler == "pr-relevance")] | last // {}')
intent=$( [ -f "$ORIGINAL_INTENT_FILE" ] && cat "$ORIGINAL_INTENT_FILE" || echo '{}' )
intent_purpose=$(echo "$intent" | jq -r '.purpose // empty')
intent_scope=$(echo "$intent" | jq -r '.scope // empty')

status=$(bash "$SCRIPT_DIR/pr-status.sh" "$pr" 2>/dev/null || echo '{}')
all_passed=$(echo "$status" | jq -r '.all_passed // false')
mergeable=$(echo "$status" | jq -r '.mergeable // "UNKNOWN"')
behind_base=$(echo "$status" | jq -r '.behind_base // false')

aggregate=$(echo "$state" | jq '
  [.outcomes[] | select(.handler != "pr-relevance")]
  | group_by(.handler)
  | map({
      handler: .[0].handler,
      fixed: (map(.fixed // 0) | add),
      declined: (map(.declined // 0) | add),
      skipped: (map(.skipped // 0) | add),
      unresolved: (map(.unresolved // []) | add)
    })
')

if [ "$all_passed" = "true" ] && [ "$mergeable" = "MERGEABLE" ] && [ "$behind_base" != "true" ]; then
  headline="address-pr complete."
  final="All checks passing"
else
  headline="address-pr stopped after $iteration iterations."
  final="$(echo "$status" | jq -r '
    [.failed[]?] as $f
    | [.mergeable == "CONFLICTING" | select(.)] as $conf
    | (if ($f | length) > 0 then "Failing: " + ($f | join(", ")) else "" end),
      (if $conf | length > 0 then "Merge conflicts present" else "" end)
    | select(. != "")' | paste -sd '; ' -)"
  [ -z "$final" ] && final="See handler outcomes below"
fi

{
  echo "$headline"
  echo "  Iterations:   $iteration"
  if [ -n "$intent_purpose" ] || [ -n "$intent_scope" ]; then
    if [ -n "$intent_purpose" ] && [ -n "$intent_scope" ]; then
      echo "  Intent:       $intent_purpose ($intent_scope)"
    elif [ -n "$intent_purpose" ]; then
      echo "  Intent:       $intent_purpose"
    else
      echo "  Intent:       $intent_scope"
    fi
  fi
  echo "  Checks:"

  if [ "$mergeable" = "MERGEABLE" ] && [ "$behind_base" != "true" ]; then
    echo "    Merge state      ✓"
  elif [ "$mergeable" = "CONFLICTING" ]; then
    echo "    Merge state      ✗  (CONFLICTING)"
  elif [ "$behind_base" = "true" ]; then
    echo "    Merge state      ✗  (behind base)"
  else
    echo "    Merge state      ?  ($mergeable)"
  fi

  relevance_status=$(echo "$relevance" | jq -r '.status // ""')
  if [ -n "$relevance_status" ]; then
    relevance_risk=$(echo "$relevance" | jq -r '.risk // "unknown"')
    relevance_confidence=$(echo "$relevance" | jq -r '.confidence // null')
    relevance_summary=$(echo "$relevance" | jq -r '.summary // ""')

    confidence_suffix=""
    if [ "$relevance_confidence" != "null" ]; then
      confidence_suffix="; confidence=$relevance_confidence"
    fi

    if [ "$relevance_status" = "auto-continued" ] || [ "$relevance_status" = "manual-confirmed" ]; then
      echo "    Relevance check  ✓  ($relevance_status; risk=$relevance_risk$confidence_suffix)"
    else
      echo "    Relevance check  ?  ($relevance_status; risk=$relevance_risk$confidence_suffix)"
    fi

    if [ -n "$relevance_summary" ]; then
      echo "                    $relevance_summary"
    fi
  fi

  echo "$aggregate" | jq -r '
    .[] |
    if .unresolved | length == 0 then
      "    \(.handler | (. + "                  ")[0:16])✓  (\(.fixed) fixed, \(.declined) declined\(if .skipped > 0 then ", \(.skipped) skipped" else "" end))"
    else
      "    \(.handler | (. + "                  ")[0:16])✗  (\(.unresolved | length) unresolved)"
    end'

  has_unresolved=$(echo "$aggregate" | jq '[.[] | select(.unresolved | length > 0)] | length')
  if [ "$has_unresolved" -gt 0 ]; then
    echo ""
    echo "  Unresolved:"
    echo "$aggregate" | jq -r '
      .[] | select(.unresolved | length > 0) |
      .handler as $h |
      .unresolved[] |
      "    - [\($h)] \(.path // "?"):\(.line // "?") — \(.note // .body // "no detail")"'
  fi

  echo "  Final state:  $final"

  # Stale-review caveat: if the last review fetch saw GraphQL lag REST
  # (consistency.ok == false), the unresolved-thread count may be understated.
  # Monitor's first probe re-verifies the full run window, so surface it here
  # rather than leaving the agent to remember the rule. Missing file or field
  # ⇒ no caveat (treated as consistent).
  # NB: jq's `//` treats `false` as empty, so `.consistency.ok // true` would
  # mask a real false. Compare explicitly: only an exact `false` trips it;
  # a missing file or absent field reads as consistent.
  stale=$( [ -f "$REVIEWS_FILE" ] && jq -r 'if .consistency.ok == false then "false" else "true" end' "$REVIEWS_FILE" 2>/dev/null || echo true )
  if [ "$stale" = "false" ]; then
    echo "  Caveat:       review fetch may have been stale; monitor re-verifies within 60s"
  fi
}
