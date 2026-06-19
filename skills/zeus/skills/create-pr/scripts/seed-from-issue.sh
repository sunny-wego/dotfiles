#!/usr/bin/env bash
# seed-from-issue.sh — extract reusable sections from a linked GitHub issue
# (written by /zeus:propose) so /zeus:create-pr can pre-fill Original Intent, Test
# Plan, and Design Decisions instead of starting blank.
#
# Independence: every mode falls back to empty output if the issue isn't
# fetchable. The PR body the skill produces is still valid — just less
# pre-filled.
#
# Usage:
#   seed-from-issue.sh original-intent <issue_number_or_url>
#   seed-from-issue.sh test-plan       <issue_number_or_url>
#   seed-from-issue.sh design-decisions <issue_number_or_url>
#   seed-from-issue.sh closes-line     <issue_number_or_url>
#   seed-from-issue.sh fetch           <issue_number_or_url>   # prints body to stdout
#
# Source: the RENDERED ISSUE BODY only, parsed by the section grammar the
# propose skill writes:
#   ## Context, ## Proposal, ## What's Excluded
#   ## Verification / Acceptance  (or ## Verification)
#   ## Discussion questions  (with "**Default lean:** X" — the [draft] tag
#                             means the user hasn't accepted it yet)
#
# Deliberately NOT read: propose's persisted state file
# (<gitdir>/propose/issue-<N>.state.json). That file is another skill's
# PRIVATE state — skills share data via public artifacts (the rendered body,
# journey.json, the PR-body marker), never each other's internals. The body
# loses nothing: propose's doctrine is body == render(state), so every
# seedable section is present in the body by construction — and the body path
# works identically for issues authored in other worktrees, by other people,
# or by hand. Tolerant and best-effort by design.

set -euo pipefail

cmd="${1:?Usage: seed-from-issue.sh <original-intent|test-plan|design-decisions|closes-line|fetch> <issue>}"
target="${2:-}"

if [ -z "$target" ]; then
  echo "seed-from-issue.sh: issue number or URL required" >&2
  exit 1
fi

# Normalise the target (number or URL) to a bare issue number.
issue_number() {
  printf '%s' "$target" | grep -oE '[0-9]+' | tail -1
}

# Emit bare criterion lines, one per line. Strips leading "N." / "-" / "*" and
# any existing "- [ ]" / "- [x]" checkbox prefix. render-body.sh adds the
# "- [ ]" when rendering test_plan.acceptance, so the data stays prefix-free.
strip_to_criteria() {
  awk '
    /^[[:space:]]*$/ { next }
    {
      sub(/^[[:space:]]*-[[:space:]]*\[[[:space:]xX]\][[:space:]]*/, "")
      sub(/^[[:space:]]*[0-9]+\.[[:space:]]+/, "")
      sub(/^[[:space:]]*[-*][[:space:]]+/, "")
      if (length($0) > 0) print
    }
  '
}

# Extract a markdown section by heading name. Stops at the next "## " or EOF.
# Heading match is anchored; trailing whitespace allowed. Output excludes the
# heading line itself.
extract_section() {
  local body="$1"
  local heading="$2"
  printf '%s\n' "$body" | awk -v h="$heading" '
    BEGIN { in_section = 0 }
    {
      # Match "## <heading>" exactly, allowing trailing whitespace.
      if (match($0, /^##[[:space:]]+/) && substr($0, RLENGTH+1) ~ "^"h"[[:space:]]*$") {
        in_section = 1
        next
      }
      if (in_section && /^##[[:space:]]+/) {
        exit
      }
      if (in_section) print
    }
  '
}

# Fetch the issue body once. gh prints the body raw with `--jq .body`.
fetch_body() {
  gh issue view "$target" --json body --jq '.body // ""' 2>/dev/null || true
}

# Trim leading/trailing blank lines from stdin.
trim_blanks() {
  awk 'NF{p=1} p' | awk 'BEGIN{RS=""; ORS="\n\n"} {print}' | sed -e '$d'
}

# Collapse a multi-line section into a single inline value (for Purpose / Scope).
collapse_inline() {
  # Drop blank lines, drop list markers, join into one line.
  awk 'NF' | sed -E 's/^[[:space:]]*[-*][[:space:]]*//' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/[[:space:]]+$//'
}

case "$cmd" in
  fetch)
    fetch_body
    ;;

  closes-line)
    # Normalise input to a bare number for the GitHub keyword.
    number=$(printf '%s' "$target" | grep -oE '[0-9]+' | tail -1)
    if [ -n "$number" ]; then
      echo "Closes #$number"
    fi
    ;;

  original-intent)
    body=$(fetch_body)
    if [ -z "$body" ]; then
      exit 0  # Independence: silent fall-through.
    fi
    context=$(extract_section "$body" "Context" | collapse_inline)
    proposal=$(extract_section "$body" "Proposal" | collapse_inline)
    [ -z "$proposal" ] && proposal=$(extract_section "$body" "Proposal / Approach" | collapse_inline)
    excluded=$(extract_section "$body" "What's Excluded" | collapse_inline)
    [ -z "$excluded" ] && excluded=$(extract_section "$body" "Whats Excluded" | collapse_inline)

    # Render the three Original Intent bullets. Purpose comes from Context,
    # Scope from Proposal, Non-goals from What's Excluded. Any missing piece
    # is rendered as an empty placeholder so the author sees the slot.
    {
      printf -- '- Purpose: %s\n' "${context:-}"
      printf -- '- Scope: %s\n'   "${proposal:-}"
      if [ -n "$excluded" ]; then
        printf -- '- Non-goals: %s\n' "$excluded"
      fi
    }
    ;;

  test-plan)
    body=$(fetch_body)
    if [ -z "$body" ]; then
      exit 0
    fi
    # /zeus:propose writes "## Verification / Acceptance" or "## Verification".
    section=$(extract_section "$body" "Verification / Acceptance")
    [ -z "$section" ] && section=$(extract_section "$body" "Verification")
    if [ -z "$section" ]; then
      exit 0
    fi

    printf '%s\n' "$section" | strip_to_criteria
    ;;

  design-decisions)
    body=$(fetch_body)
    if [ -z "$body" ]; then
      exit 0
    fi
    section=$(extract_section "$body" "Discussion questions")
    if [ -z "$section" ]; then
      exit 0
    fi

    # Walk the section. For each `### Q… — <question>` block, look for a
    # `**Default lean:** <X>` line. If the lean line does NOT contain
    # "[draft]", emit a numbered Design Decision. [draft] means the user
    # hasn't accepted the inferred lean, so don't promote it.
    printf '%s\n' "$section" | awk '
      BEGIN { idx = 0; q = ""; lean = ""; collecting = 0 }
      function flush() {
        if (q != "" && lean != "" && index(lean, "[draft]") == 0) {
          idx++
          # Strip the leading "Q\d+ — " prefix from the question if present.
          sub(/^Q[0-9]+[[:space:]]*[—-][[:space:]]*/, "", q)
          printf("### %d. %s\n", idx, q)
          printf("Chosen: %s\n\n", lean)
        }
        q = ""; lean = ""
      }
      /^###[[:space:]]+Q[0-9]+/ {
        flush()
        line = $0
        sub(/^###[[:space:]]+/, "", line)
        q = line
        next
      }
      /^\*\*Default lean:\*\*/ {
        lean = $0
        sub(/^\*\*Default lean:\*\*[[:space:]]*/, "", lean)
        next
      }
      END { flush() }
    '
    ;;

  *)
    echo "seed-from-issue.sh: unknown mode: $cmd" >&2
    exit 1
    ;;
esac
