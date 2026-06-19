#!/usr/bin/env bash
# scaffold-draft.sh — render a canonical issue draft from inputs.
#
# The agent provides extracted sections (typically from extract-sections.sh)
# plus a title / status / closes-when. The scaffolder lays them out in the
# fixed section grammar /zeus:propose posts. Empty sections render as
# placeholders for the user to fill, except optional sections (mermaid,
# discussion_questions, references) which are omitted when blank.
#
# Inputs JSON schema:
#   {
#     title:        string  (required)
#     status:       string  (e.g. "open" | "decisions-pending" | "tracking")
#     closes_when:  string  (e.g. "merge of PR #N")
#     context:      string
#     proposal:     string  (optional — omit for pure tracking issues)
#     discussion_questions: [
#       { q: "...", options: [{label, meaning, tradeoff}], default_lean: "...", is_draft: bool }
#     ]
#     mermaid:      string  (optional)
#     whats_excluded: [ "bullet 1", "bullet 2" ]
#     verification:   [ "criterion 1", "criterion 2" ]
#     references:     [ "ref 1", "ref 2" ]
#     code_grounding: [ { claim: "...", ref: "path/to/file.ts:NNN-NNN" } ]
#                     (optional — renders as a collapsed claim→code table at the
#                      bottom; the ONLY place code citations belong. pin-refs.sh
#                      converts refs to permalinks.)
#   }
#
# Usage:  scaffold-draft.sh <state.json>
# Output: markdown draft to stdout.

set -euo pipefail

state="${1:?Usage: scaffold-draft.sh <state.json>}"
[ -f "$state" ] || { echo "scaffold-draft: state not found: $state" >&2; exit 1; }
jq -e . "$state" >/dev/null 2>&1 || { echo "scaffold-draft: state is not valid JSON" >&2; exit 1; }

# emit_sections — render the free-form `sections` array for one placement slot, in
# array order. Lets genre-specific sections (Alternatives, Risks, Rollout, Security,
# Consequences, Background) be first-class + reorderable via state instead of buried
# in the `proposal` blob. Each: {heading, body, placement}; placement defaults to
# "after_proposal". Renders nothing when no section targets the slot.
emit_sections() {
  local place="$1" out
  out=$(jq -r --arg p "$place" '
    [ (.sections // [])[] | select((.placement // "after_proposal") == $p) ]
    | map("## " + (.heading // "<section>") + "\n\n" + (.body // "")) | join("\n\n")
  ' "$state")
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo
  fi
}

# Status / Closes-when as a 2-row table, rendered as the FIRST line of the body.
# The body does NOT repeat the title: GitHub already shows it above the body, so a
# title line is redundant. The title still lives in state.title (passed to
# `gh --title`), and the confirm step calls preview.sh with it explicitly (shape 1),
# so nothing depends on the body's first line being the title any more.
# Pipe chars in the values are escaped so a value like "merge of #5 | sign-off"
# can't break the table.
jq -r '
  def cell: gsub("\\|"; "\\|");
  "|  |  |\n|---|---|\n" +
  "| **Status** | " + ((.status // "open") | cell) + " |\n" +
  "| **Closes-when** | " + ((.closes_when // "<merge of PR #N — sign-off in thread — acceptance criteria below>") | cell) + " |"
' "$state"
echo

# Context (required).
echo "## Context"
jq -r '.context // "<2-4 sentences on why this exists and intended outcome>"' "$state"
echo

# Mermaid — placed right after Context, BEFORE the proposal detail, so a
# flow/architecture diagram serves as orientation (progressive disclosure:
# problem → picture → approach → detail → appendices). Only when present.
mermaid=$(jq -r '.mermaid // ""' "$state")
if [ -n "$mermaid" ]; then
  echo '## Mermaid'
  echo
  echo '```mermaid'
  printf '%s\n' "$mermaid"
  echo '```'
  echo
fi

# Custom sections targeting the slot before the proposal (e.g. Background, Glossary).
emit_sections before_proposal

# Proposal (optional — omit only for pure tracking issues with no proposal).
proposal=$(jq -r '.proposal // ""' "$state")
if [ -n "$proposal" ]; then
  echo "## Proposal / Approach"
  printf '%s\n' "$proposal"
  echo
fi

# Custom sections after the proposal — the DEFAULT slot (Alternatives Considered,
# Risks, Rollout, Security, Consequences, …).
emit_sections after_proposal

# Discussion questions (only when present).
dq_count=$(jq -r '(.discussion_questions // []) | length' "$state")
if [ "$dq_count" -gt 0 ]; then
  echo "## Discussion questions"
  echo
  # Optional intro banner (e.g. "all four locked by @reviewer / which remain open").
  banner=$(jq -r '.discussion_banner // ""' "$state")
  if [ -n "$banner" ]; then
    printf '%s\n' "$banner"
    echo
  fi
  jq -r '
    (.discussion_questions // []) | to_entries | map(
      "### Q\(.key + 1) — \(.value.q // "")\n" +
      (
        if ((.value.options // []) | length) > 0 then
          "| Option | What it means | Trade-off |\n|---|---|---|\n" +
          ((.value.options // []) | map("| **\(.label // "")** | \(.meaning // "") | \(.tradeoff // "") |") | join("\n")) + "\n"
        else
          "<list options as a table: Option / What it means / Trade-off>\n"
        end
      ) +
      "**Default lean:** " + (.value.default_lean // "") + (if (.value.is_draft // false) then " [draft]" else "" end) + "\n" +
      (if ((.value.decided // "") | length) > 0 then "**✅ Decided:** " + .value.decided + "\n" else "" end)
    ) | join("\n")
  ' "$state"
  echo
fi

# Custom sections after the discussion questions.
emit_sections after_discussion

# kind gates whether What's Excluded / Verification are required. implementation
# (default) keeps both mandatory — rendered with a placeholder when empty so the
# author fills them. Other kinds (decision / research / tracking) treat them as
# optional: render only when the author supplied content, omit the empty heading.
kind=$(jq -r '.kind // "implementation"' "$state")
# strict = render the placeholder when the section is empty (so the author fills it).
# Only the three known kinds relax; unknown/empty falls through to strict, matching
# validate-draft so the two never disagree about what's required.
case "$kind" in decision|research|tracking) strict=0 ;; *) strict=1 ;; esac

# What's Excluded.
exc_count=$(jq -r '(.whats_excluded // []) | length' "$state")
if [ "$exc_count" -gt 0 ]; then
  echo "## What's Excluded"
  jq -r '(.whats_excluded // []) | map("- " + .) | join("\n")' "$state"
  echo
elif [ "$strict" -eq 1 ]; then
  echo "## What's Excluded"
  echo "- <non-goal> — <why>"
  echo
fi

# Verification / Acceptance.
ver_count=$(jq -r '(.verification // []) | length' "$state")
if [ "$ver_count" -gt 0 ]; then
  echo "## Verification / Acceptance"
  jq -r '(.verification // []) | to_entries | map("\(.key + 1). \(.value)") | join("\n")' "$state"
  echo
elif [ "$strict" -eq 1 ]; then
  echo "## Verification / Acceptance"
  echo "1. <acceptance criterion 1>"
  echo
fi

# Custom sections after Verification, before References (rare slot).
emit_sections before_references

# References (only when present).
ref_count=$(jq -r '(.references // []) | length' "$state")
if [ "$ref_count" -gt 0 ]; then
  echo "## References"
  jq -r '(.references // []) | map("- " + .) | join("\n")' "$state"
  echo
fi

# Amendment Log (only when present) — one dated line per substantive edit, so the
# history is legible without diffing the body across amends. RFC-grade issues.
al_count=$(jq -r '(.amendment_log // []) | length' "$state")
if [ "$al_count" -gt 0 ]; then
  echo "## Amendment Log"
  jq -r '(.amendment_log // []) | map("- " + .) | join("\n")' "$state"
  echo
fi

# Code grounding appendix (only when present) — collapsed claim→code table at
# the very bottom. Keeps permalinks OUT of body tables: cite the claim here,
# keep body cells to short phrases. Refs in `path:NNN-NNN` form get pinned to
# permalinks by pin-refs.sh afterwards.
cg_count=$(jq -r '(.code_grounding // []) | length' "$state")
if [ "$cg_count" -gt 0 ]; then
  echo '<a name="code-grounding"></a>'
  echo '<details>'
  echo '<summary><b>Code grounding — claims above, pinned to the SHA in each link</b></summary>'
  echo
  echo '| Claim | Code |'
  echo '|---|---|'
  jq -r '(.code_grounding // []) | map("| \(.claim // "") | \(.ref // "") |") | join("\n")' "$state"
  echo
  echo '</details>'
  echo
fi

# Single-mention guard (invisible HTML comment) — lets audit-draft.sh enforce that
# declared terms (e.g. a rejected alternative named once) appear ≤1 time, without a
# caller re-passing --mention-once. Persisted in state, so it survives every amend.
mo_count=$(jq -r '(.mention_once // []) | length' "$state")
if [ "$mo_count" -gt 0 ]; then
  terms=$(jq -r '(.mention_once // []) | join(", ")' "$state")
  echo "<!-- audit:mention-once: $terms -->"
fi
