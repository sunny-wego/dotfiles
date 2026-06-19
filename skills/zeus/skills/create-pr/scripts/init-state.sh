#!/usr/bin/env bash
# init-state.sh — emit a skeleton state JSON for the PR body renderer. The
# agent fills in the field values (via jq write, Edit, or a heredoc) and
# pipes the result to render-body.sh.
#
# Schema fields (all optional unless noted; render-body.sh handles missing
# values by emitting empty slots or omitting whole sections):
#
#   purpose                  string — Original Intent.Purpose (REQUIRED)
#   scope                    string — Original Intent.Scope (REQUIRED)
#   non_goals                string — Original Intent.Non-goals (recommended)
#   what_this_does           string — 2-4 sentence behavior summary (REQUIRED)
#   outcome                  array  — observable effect bullets
#   key_changes              array of {area, why}
#   test_plan.acceptance     array of strings — rendered under "**Acceptance criteria** —"
#   test_plan.manually_verified
#                            object {summary, evidence[]} — `summary` is a one-line
#                            claim a reviewer can check (rendered inline). `evidence`
#                            is a list of VERBATIM markdown blocks (fenced code with
#                            real command output, mermaid diagrams, before/after
#                            tables, or prose), each emitted as-is — separated by a
#                            blank line — inside a collapsible <details> after the
#                            summary. A plain string is still accepted (rendered
#                            inline, no <details>). See references/test-evidence-contract.md.
#   test_plan.not_tested     array of {gap, why_not, mitigation}
#   risks                    array of {risk, real, mitigation}
#   pre_merge_checks         string — optional SQL probes / drain queries
#   rollback                 string — one sentence (REQUIRED)
#   design_decisions         array of {title, body}     human-owned
#   deliberately_excluded    array of {item, why}        human-owned
#   logic                    string — optional narrative / Mermaid (human-owned)
#   closes_issue             integer — appended as "Closes #<N>" footer
#
# Usage:  init-state.sh [--with-issue <N>]
# Output: JSON skeleton to stdout. The agent edits values, then pipes to
#         render-body.sh.

set -euo pipefail

issue=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-issue) issue="$2"; shift 2 ;;
    *) echo "init-state.sh: unknown flag: $1" >&2; exit 1 ;;
  esac
done

jq -nc --arg issue "$issue" '
  {
    purpose: "",
    scope: "",
    non_goals: "",
    what_this_does: "",
    outcome: [],
    key_changes: [],
    test_plan: {
      acceptance: [],
      manually_verified: { summary: "", evidence: [] },
      not_tested: []
    },
    risks: [],
    pre_merge_checks: "",
    rollback: "",
    design_decisions: [],
    deliberately_excluded: [],
    logic: "",
    closes_issue: (if $issue == "" then null else ($issue | tonumber? // null) end)
  }
'
