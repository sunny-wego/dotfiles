#!/usr/bin/env bash
# render-body.sh — render a canonical PR body from a state JSON produced by
# init-state.sh (then filled in by the agent).
#
# Usage:
#   render-body.sh <state.json>            # full body (Original Intent +
#                                          # managed block + human-owned tail)
#   render-body.sh managed-only <state.json>
#                                          # only the contents that go between
#                                          # the managed-block delimiters
#                                          # (used by refresh mode)
#
# Reads state.json; writes the rendered markdown to stdout. Empty / null
# fields render as empty slots or omit their section entirely (see below).
#
# Section policy (matches the prose contract today):
#   - Original Intent: always emitted. Empty Purpose/Scope render as the
#     literal placeholder so validate-pr.sh flags missing required content.
#   - Non-goals: omitted entirely when blank.
#   - Managed block: always present (delimited). Inside, every section is
#     emitted with a placeholder when empty, since these are part of the
#     PR contract (validate-pr.sh enforces `## What this does`, `## Test
#     Plan`, `## Rollback`).
#   - Pre-merge checks: omitted when blank (marked optional in the contract).
#   - Design Decisions / What's deliberately excluded / Logic | Architecture:
#     omitted entirely when empty (all human-owned, all optional).
#   - Closes #N: appended as a trailing line iff state.closes_issue is set.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

mode="full"
if [ "${1:-}" = "managed-only" ]; then
  mode="managed-only"
  shift
fi

state_file="${1:?Usage: render-body.sh [managed-only] <state.json>}"
if [ ! -f "$state_file" ]; then
  echo "render-body: state file not found: $state_file" >&2
  exit 1
fi
if ! jq -e . "$state_file" >/dev/null 2>&1; then
  echo "render-body: state file is not valid JSON" >&2
  exit 1
fi

# --- shape guard ----------------------------------------------------------
# The emit_* helpers index object fields (.area, .label, .title, …) over each
# array element. A string where an object is expected otherwise dies mid-render
# with a cryptic jq error ("Cannot index string with string \"label\""), and the
# partial output then trips validate-pr.sh with a misleading "missing section".
# Catch it up front with a message that names the field and its required shape.
shape_err=$(jq -r '
  def check(path; want):
    ((getpath(path) // []) | map(type) | map(select(. != want)) | length) as $bad
    | if $bad > 0 then (path | join(".")) + " must be an array of " + want + "s" else empty end;
  [ check(["outcome"]; "string"),
    check(["key_changes"]; "object"),
    check(["test_plan","acceptance"]; "string"),
    check(["test_plan","not_tested"]; "object"),
    check(["risks"]; "object"),
    check(["design_decisions"]; "object"),
    check(["deliberately_excluded"]; "object")
  ] | .[0] // empty
' "$state_file")
if [ -n "$shape_err" ]; then
  {
    echo "render-body: $shape_err"
    echo "  Item shapes (see init-state.sh header):"
    echo "    outcome=[strings]  test_plan.acceptance=[strings]  key_changes={area,why}  risks={risk,real,mitigation}"
    echo "    test_plan.not_tested={gap,why_not,mitigation}"
    echo "    design_decisions={title,body}  deliberately_excluded={item,why}"
  } >&2
  exit 1
fi

# --- rendering helpers ----------------------------------------------------
# Each emit_* reads from the state and writes a markdown fragment. Returning
# an empty string means "omit this section."

emit_original_intent() {
  jq -r '
    "## Original Intent\n" +
    "- Purpose: " + (.purpose // "") + "\n" +
    "- Scope: " + (.scope // "") + "\n" +
    (if (.non_goals // "") == "" then "" else "- Non-goals: " + .non_goals + "\n" end)
  ' "$state_file"
}

emit_what_this_does() {
  jq -r '
    "## What this does\n" +
    (.what_this_does // "") + "\n"
  ' "$state_file"
}

emit_outcome() {
  jq -r '
    "## Outcome\n" +
    ((.outcome // []) | if length == 0 then "- [Observable effect — what changes or deliberately stays the same]\n" else map("- " + .) | join("\n") + "\n" end)
  ' "$state_file"
}

emit_key_changes() {
  jq -r '
    "## Key Changes\n" +
    "| Area | What changed |\n" +
    "|---|---|\n" +
    ((.key_changes // []) | if length == 0 then "| `<path or area>` | [one-line why] |\n" else map("| `" + (.area // "") + "` | " + (.why // "") + " |") | join("\n") + "\n" end)
  ' "$state_file"
}

emit_test_plan() {
  jq -r '
    "## Test Plan\n" +
    "**Acceptance criteria** — " +
    ((.test_plan.acceptance // []) | if length == 0 then "[criteria a reviewer ticks off — seeded from the linked issue (Verification section), or filled in]\n" else
      "\n" + ((map("- [ ] " + .) | join("\n")) + "\n")
    end) +
    "\n**Manually verified** — " +
    (.test_plan.manually_verified as $mv |
      (($mv == null) or ($mv == "")
       or (($mv | type) == "object" and (($mv.summary // "") == "") and ((($mv.evidence) // []) | length == 0))) as $empty |
      if $empty then
        "[one-line claim a reviewer can check]\n<details>\n<summary>Evidence & steps</summary>\n\n[verbatim proof a reviewer can independently confirm — real command + output in a fenced code block, a mermaid diagram of the path exercised, or a before/after table; redact secrets]\n</details>\n"
      elif ($mv | type) == "string" then
        $mv + "\n"
      else
        ($mv.summary // "") + "\n" +
        (if ((($mv.evidence) // []) | length) == 0 then "" else
          "<details>\n<summary>Evidence & steps</summary>\n\n" +
          (($mv.evidence) | join("\n\n")) + "\n</details>\n"
        end)
      end) +
    "\n**Not tested** — gaps + mitigation\n\n" +
    "| Gap | Why not | Mitigation |\n" +
    "|---|---|---|\n" +
    ((.test_plan.not_tested // []) | if length == 0 then "" else (map("| " + (.gap // "") + " | " + (.why_not // "") + " | " + (.mitigation // "") + " |") | join("\n")) + "\n" end)
  ' "$state_file"
}

emit_risks() {
  jq -r '
    "## Risks & Mitigations\n" +
    "| Risk | Real? | Mitigation |\n" +
    "|---|---|---|\n" +
    ((.risks // []) | if length == 0 then "| [Potential side effect] | [Low/Med/High] | [How it is prevented] |\n" else map("| " + (.risk // "") + " | " + (.real // "") + " | " + (.mitigation // "") + " |") | join("\n") + "\n" end)
  ' "$state_file"
}

emit_pre_merge() {
  jq -r '
    if (.pre_merge_checks // "") == "" then "" else
      "## Pre-merge checks (optional)\n" + .pre_merge_checks + "\n"
    end
  ' "$state_file"
}

emit_rollback() {
  jq -r '
    "## Rollback\n" +
    (.rollback // "") + "\n"
  ' "$state_file"
}

emit_design_decisions() {
  jq -r '
    if ((.design_decisions // []) | length) == 0 then "" else
      "## Design Decisions (optional, human-owned)\n" +
      "Numbered rationale for non-obvious choices. Refresh mode does not touch this section.\n\n" +
      ((.design_decisions // []) | to_entries | map("### \(.key + 1). \(.value.title // "")\n\(.value.body // "")\n") | join("\n"))
    end
  ' "$state_file"
}

emit_excluded() {
  jq -r '
    if ((.deliberately_excluded // []) | length) == 0 then "" else
      "## What'\''s deliberately excluded (optional, human-owned)\n" +
      ((.deliberately_excluded // []) | map("- " + (.item // "") + " — " + (.why // "")) | join("\n")) + "\n"
    end
  ' "$state_file"
}

emit_logic() {
  jq -r '
    if (.logic // "") == "" then "" else
      "## Logic | Architecture (optional, human-owned)\n" + .logic + "\n"
    end
  ' "$state_file"
}

emit_closes_line() {
  jq -r '
    if (.closes_issue // null) == null then "" else "Closes #\(.closes_issue)\n" end
  ' "$state_file"
}

# --- main composition ------------------------------------------------------

managed_block() {
  emit_what_this_does
  echo
  emit_outcome
  echo
  emit_key_changes
  echo
  emit_test_plan
  echo
  emit_risks
  echo
  pm=$(emit_pre_merge)
  if [ -n "$pm" ]; then
    printf '%s\n' "$pm"
  fi
  emit_rollback
}

case "$mode" in
  managed-only)
    managed_block
    ;;

  full)
    emit_original_intent
    echo
    printf '%s\n' "$MANAGED_START"
    managed_block
    printf '%s\n' "$MANAGED_END"

    dd=$(emit_design_decisions)
    [ -n "$dd" ] && { echo; printf '%s\n' "$dd"; }
    ex=$(emit_excluded)
    [ -n "$ex" ] && { echo; printf '%s\n' "$ex"; }
    lg=$(emit_logic)
    [ -n "$lg" ] && { echo; printf '%s\n' "$lg"; }

    cl=$(emit_closes_line)
    if [ -n "$cl" ]; then
      echo
      printf '%s\n' "$cl"
    fi
    ;;
esac
