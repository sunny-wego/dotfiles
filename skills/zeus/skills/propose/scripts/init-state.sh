#!/usr/bin/env bash
# init-state.sh — emit the COMPLETE state-JSON skeleton the issue renderer consumes.
#
# WHY: the state schema is the contract between the agent (fills values) and
# scaffold-draft (renders). Keeping it here, in code, makes it one source of truth
# instead of scattered across SKILL.md prose — and gives the conversation source
# path (no file to extract from) a deterministic starting point instead of
# hand-assembling JSON from a prose field list. Every key exists, so scaffold-draft
# renders predictable empty slots for unfilled sections and a later amend never has
# to invent the shape.
#
# Schema (all optional unless noted; scaffold-draft omits or placeholder-fills empties):
#   title           string — issue title (REQUIRED before post; also passed to post-issue)
#   status          string — Status: line (REQUIRED)
#   closes_when     string — Closes-when: line (REQUIRED)
#   context         string — ## Context (REQUIRED)
#   kind            string — "implementation" (default) | "decision" | "research" | "tracking".
#                            Gates which sections are REQUIRED: implementation requires both
#                            What's Excluded + Verification; the other kinds relax both to
#                            optional (a research/question or ADR-style decision doc has no
#                            "acceptance criteria"). Status/Closes-when/Context required for all.
#   proposal        string — ## Proposal / Approach (blank for pure tracking issues)
#   sections        array of {heading, body, placement} — FIRST-CLASS extra sections so genre-
#                            specific blocks (Alternatives, Risks, Rollout, Security, Consequences,
#                            Background) don't have to be buried in `proposal`. Rendered in array
#                            order at one of four slots via `placement`:
#                              "before_proposal" | "after_proposal" (default) |
#                              "after_discussion" | "before_references"
#                            body is free markdown (tables, <details>, fences all fine).
#   discussion_questions  array of {q, options:[{label,meaning,tradeoff}], default_lean, is_draft, decided}
#                            `decided` (optional): a locked decision — renders a "✅ Decided:" line
#                            under the question so a settled Q reads as a record, not an open ask.
#   discussion_banner string — optional intro rendered right under "## Discussion questions"
#                            (e.g. "all four locked by @reviewer" / which remain open).
#   mermaid         string — verbatim mermaid block (no fences)
#   whats_excluded  array  — ## What's Excluded bullets (REQUIRED for kind=implementation)
#   verification    array  — ## Verification / Acceptance items (REQUIRED for kind=implementation)
#   references      array  — ## References bullets
#   amendment_log   array  — RFC-grade: "<date> — <change> (amend|supersede)" lines
#   code_grounding  array of {claim, ref}  — collapsed appendix; ref as path:NNN-NNN
#   mention_once    array  — terms the audit enforces appear ≤1 time (renders the guard comment)
#   review          string — "auto" (default) | "always" | "never". Review is DERIVED from
#                            content by requires-review.sh (questions / grounded claims /
#                            substantial proposal / invariants) — this field only overrides.
#                            "never" must be a visible choice in the confirmation dialog.
#   reader_test     bool   — stamped true by the agent after the Stage-1 reviewer simulation;
#                            post-issue refuses a review-required post without it; rehydrate clears it
#   reader_test_hash string — state-hash.sh value at stamp time; post-issue refuses when the
#                            current state hash differs (state edited after the test → fixes are
#                            untested). Stamp both together; rehydrate clears both.
#
# Usage:
#   init-state.sh                       # empty skeleton (conversation source)
#   init-state.sh --from <source-file>  # skeleton + extract-sections merged in (file source)
# Output: state JSON to stdout.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
from=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) from="$2"; shift 2 ;;
    *) echo "init-state.sh: unknown flag: $1" >&2; exit 1 ;;
  esac
done

skeleton=$(jq -nc '{
  title: "", status: "open", closes_when: "",
  context: "", kind: "implementation", proposal: "", sections: [],
  discussion_questions: [], discussion_banner: "", mermaid: "",
  whats_excluded: [], verification: [], references: [],
  amendment_log: [], code_grounding: [], mention_once: [],
  review: "auto", reader_test: false, reader_test_hash: ""
}')

if [ -n "$from" ]; then
  [ -f "$from" ] || { echo "init-state.sh: source not found: $from" >&2; exit 1; }
  extracted=$(bash "$script_dir/extract-sections.sh" "$from" 2>/dev/null || echo '{}')
  # Deep-merge the extracted content OVER the skeleton: `*` recurses objects and
  # lets extracted keys win, while the skeleton supplies every key the source
  # didn't carry (status/closes_when/title/code_grounding/amendment_log/…).
  printf '%s\n%s\n' "$skeleton" "$extracted" | jq -s '.[0] * .[1]'
else
  printf '%s\n' "$skeleton"
fi
