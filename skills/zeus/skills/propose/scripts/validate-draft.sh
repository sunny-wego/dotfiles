#!/usr/bin/env bash
# validate-draft.sh — fail fast if a composed draft is missing required
# sections, so the skill doesn't post a half-filled issue.
#
# Required sections:
#   Status      (plain `Status:` line OR a `| **Status** | … |` header-table row)
#   Closes-when (plain `Closes-when:` line OR a `| **Closes-when** | … |` row)
#   ## Context
#   ## What's Excluded
#   ## Verification (or ## Verification / Acceptance)
#
# Soft warnings (printed but not fatal):
#   - No ## References section
#   - One or more sections tagged [draft] (unresolved inferences)
#
# Usage:  validate-draft.sh <draft-path>
# Exit:   0 on pass; 1 on missing required section.

set -euo pipefail

draft="${1:-}"; shift || true
# kind gates the conditionally-required sections. Default "implementation" = strict
# (the historical behaviour, so an un-flagged call and every existing issue are
# unchanged). decision / research / tracking relax What's Excluded + Verification to
# optional — an ADR or a research-question issue has no "acceptance criteria".
kind="implementation"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;;
    *) echo "validate-draft.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$draft" ] || [ ! -f "$draft" ]; then
  echo "usage: validate-draft.sh <draft-path> [--kind implementation|decision|research|tracking]" >&2
  exit 2
fi

missing=()
# Always required, every kind: Status, Closes-when, Context.
# Status / Closes-when may render as plain `Status: …` lines (legacy) or as rows of
# the header table (`| **Status** | … |`) — accept either form.
grep -qE '^Status:|^\|[[:space:]]*\*{0,2}Status\b' "$draft"      || missing+=("Status: line")
grep -qE '^Closes-when:|^\|[[:space:]]*\*{0,2}Closes-when\b' "$draft" || missing+=("Closes-when: line")
grep -qE '^## Context\b' "$draft"               || missing+=("## Context section")
# What's Excluded + Verification: required EXCEPT for the three known relaxed kinds.
# Fail-safe: an unknown/empty/null kind falls through to strict, so a typo or a
# missing field can never silently drop a required section.
case "$kind" in
  decision|research|tracking) ;;   # relaxed: both optional
  *)
    grep -qE "^## What'?s Excluded\b" "$draft"    || missing+=("## What's Excluded section")
    grep -qE '^## Verification\b' "$draft"        || missing+=("## Verification section")
    ;;
esac

if [ "${#missing[@]}" -gt 0 ]; then
  echo "draft is missing required sections:" >&2
  for m in "${missing[@]}"; do
    echo "  - $m" >&2
  done
  exit 1
fi

# Soft warnings.
if ! grep -qE '^## References\b' "$draft"; then
  echo "warn: no ## References section (optional but encouraged)" >&2
fi
draft_tag_count=$(grep -cE '\[draft\]' "$draft" || true)
if [ "$draft_tag_count" -gt 0 ]; then
  echo "warn: $draft_tag_count [draft] tag(s) remain — inferred content the user should accept or override" >&2
fi

# Permalinks (or raw path:line refs) inside table cells OUTSIDE <details>
# blocks hurt scanability — they belong in the collapsed code-grounding
# appendix. Soft warning only.
inline_table_refs=$(awk '
  /<details>/  { d=1 }
  /<\/details>/{ d=0 }
  !d && /^\|/ && (/github\.com\/[^ |]*\/blob\// || /[A-Za-z0-9_\/.-]+\.[a-z]+:[0-9]+/) { c++ }
  END { print c+0 }
' "$draft")
if [ "$inline_table_refs" -gt 0 ]; then
  echo "warn: $inline_table_refs table row(s) carry code refs/permalinks outside <details> — move them to the code_grounding appendix and keep cells to short phrases" >&2
fi

# A ```diff fence with no +/- lines is a misused delta block (shows no change).
# Soft warning only — see references/before-after-recipes.md.
empty_diff=$(awk '
  /^```diff[[:space:]]*$/ { indiff=1; pm=0; next }
  indiff && /^```[[:space:]]*$/ { if (pm==0) e++; indiff=0; next }
  indiff && /^[+-]/ { pm++ }
  END { print e+0 }
' "$draft")
if [ "$empty_diff" -gt 0 ]; then
  echo "warn: $empty_diff \`\`\`diff fence(s) carry no +/- lines — a delta block should show the change (see references/before-after-recipes.md)" >&2
fi

echo "ok"
