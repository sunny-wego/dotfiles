#!/usr/bin/env bash
# validate-pr.sh — fail fast if a PR body is missing required sections,
# so /zeus:create-pr doesn't open a half-formed PR. Mirrors /zeus:propose's
# validate-draft.sh in shape and exit semantics.
#
# Required sections:
#   ## Original Intent      (with at least Purpose and Scope bullets)
#   ## What this does
#   ## Test Plan
#   ## Rollback
#
# Soft warnings (printed, non-fatal):
#   - No managed-block delimiters (create-pr refresh won't work later)
#   - Original Intent has no Non-goals (recommended but optional)
#   - No Closes #N keyword when a journey.json issue exists (recommended)
#
# Usage:  validate-pr.sh <body-file>
# Exit:   0 on pass; 1 on missing required section.
#
# Intentional non-feature: validate-pr.sh does NOT enforce the journey
# linkage. PRs without a linked issue are still valid — independence is
# preserved per the journey contract.

set -euo pipefail

body_file="${1:-}"
if [ -z "$body_file" ] || [ ! -f "$body_file" ]; then
  echo "usage: validate-pr.sh <body-file>" >&2
  exit 2
fi

missing=()
grep -qE '^## Original Intent\b'  "$body_file" || missing+=("## Original Intent section")
grep -qE '^- Purpose:'             "$body_file" || missing+=("Original Intent: - Purpose: bullet")
grep -qE '^- Scope:'               "$body_file" || missing+=("Original Intent: - Scope: bullet")
grep -qE '^## What this does\b'    "$body_file" || missing+=("## What this does section")
grep -qE '^## Test Plan\b'         "$body_file" || missing+=("## Test Plan section")
grep -qE '^## Rollback\b'          "$body_file" || missing+=("## Rollback section")

if [ "${#missing[@]}" -gt 0 ]; then
  echo "PR body is missing required sections:" >&2
  for m in "${missing[@]}"; do
    echo "  - $m" >&2
  done
  exit 1
fi

# Soft warnings.
if ! grep -qE '<!-- create-pr:managed:start -->' "$body_file"; then
  echo "warn: no managed-block delimiters — /zeus:create-pr refresh will no-op on this body" >&2
fi
if ! grep -qE '^- Non-goals:' "$body_file"; then
  echo "warn: Original Intent has no Non-goals bullet (recommended)" >&2
fi

# Linkage hint, never enforced — see header comment.
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "$script_dir/journey.sh" ]; then
  issue_number=$(bash "$script_dir/journey.sh" issue-number 2>/dev/null || echo "")
  if [ -n "$issue_number" ] && ! grep -qiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#?'"$issue_number"'\b' "$body_file"; then
    echo "warn: journey.json links issue #$issue_number but body has no Closes #$issue_number — merge will not auto-close" >&2
  fi
fi

echo "ok"
