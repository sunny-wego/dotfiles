#!/usr/bin/env bash
# original-intent.sh — the single owner of the PR "## Original Intent" section
# grammar. SOURCE this (don't execute); defines functions only, no top-level code.
#
# create-pr EMITS this section (render-body.sh) and address-pr PARSES it back
# (original-intent.sh). Keeping both on ONE grammar means the heading text, the
# Purpose/Scope/Non-goals bullet labels, and the managed-block boundary can't drift
# between the writer and the reader — a stray edit to a label in one skill silently
# broke the other's parse before this was centralized.
#
# Grammar (the contract both sides honor):
#   ## Original Intent
#   - Purpose: <text>
#   - Scope: <text>
#   - Non-goals: <text>          (optional; omitted when empty)
# The section ends at the next `## ` heading OR the create-pr managed-block start
# marker, whichever comes first.

# oi_emit_from_state <state.json> — render the section from .purpose/.scope/.non_goals.
# Empty Purpose/Scope render as empty slots (validate-pr.sh then flags them); an
# empty Non-goals omits its bullet entirely.
oi_emit_from_state() {
  jq -r '
    "## Original Intent\n" +
    "- Purpose: " + (.purpose // "") + "\n" +
    "- Scope: " + (.scope // "") + "\n" +
    (if (.non_goals // "") == "" then "" else "- Non-goals: " + .non_goals + "\n" end)
  ' "$1"
}

# oi_extract_section  (body text on stdin) — print the raw section lines (heading
# included), stopping at the next `## ` heading or the managed-block start marker.
oi_extract_section() {
  awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+Original Intent[[:space:]]*$/ {
      in_section = 1
      print
      next
    }
    /^##[[:space:]]+/ {
      if (in_section) { exit }
    }
    /^<!--[[:space:]]*create-pr:managed:start[[:space:]]*-->$/ {
      if (in_section) { exit }
    }
    in_section { print }
  '
}

# oi_parse  (body text on stdin) — extract + parse the section to grammar JSON:
#   {present:false}                                    when no section is found, or
#   {present:true, section, purpose, scope [, non_goals]}
# Callers layer their own concerns (e.g. address-pr adds Closes #N + issue enrichment).
oi_parse() {
  local body section purpose scope non_goals raw_line normalized value current
  body="$(cat)"
  section="$(printf '%s' "$body" | oi_extract_section)"

  if [ -z "$section" ]; then
    jq -nc '{present: false}'
    return 0
  fi

  purpose=""; scope=""; non_goals=""; current=""
  while IFS= read -r raw_line; do
    normalized=$(printf '%s' "$raw_line" | sed -E 's/^[[:space:]]*[-*]?[[:space:]]*//')
    normalized=$(printf '%s' "$normalized" | sed -E 's/^\*\*([^*]+)\*\*[[:space:]]*:[[:space:]]*/\1: /')
    case "$normalized" in
      '## Original Intent') current="" ;;
      Purpose:*)
        value=$(printf '%s' "$normalized" | sed -E 's/^Purpose:[[:space:]]*//')
        purpose="$value"; current="purpose" ;;
      Scope:*)
        value=$(printf '%s' "$normalized" | sed -E 's/^Scope:[[:space:]]*//')
        scope="$value"; current="scope" ;;
      Non-goals:*|Non-goal:*)
        value=$(printf '%s' "$normalized" | sed -E 's/^Non-goals?:[[:space:]]*//')
        non_goals="$value"; current="non_goals" ;;
      '') current="" ;;
      *)
        if [ -n "$current" ]; then
          case "$current" in
            purpose)   purpose=$(printf '%s %s' "$purpose" "$normalized" | xargs) ;;
            scope)     scope=$(printf '%s %s' "$scope" "$normalized" | xargs) ;;
            non_goals) non_goals=$(printf '%s %s' "$non_goals" "$normalized" | xargs) ;;
          esac
        fi ;;
    esac
  done <<EOF2
$section
EOF2

  jq -nc \
    --arg section "$section" \
    --arg purpose "$purpose" \
    --arg scope "$scope" \
    --arg non_goals "$non_goals" \
    '{present: true, section: $section, purpose: $purpose, scope: $scope}
     + (if $non_goals != "" then {non_goals: $non_goals} else {} end)'
}
