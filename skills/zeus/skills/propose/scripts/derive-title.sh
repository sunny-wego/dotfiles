#!/usr/bin/env bash
# derive-title.sh — propose a `type(scope): description` title from a source
# file. Encodes the convention used across /zeus:propose and /zeus:create-pr so
# both skills can call the same script (vendored copy in each).
#
# Heuristics:
#   - type:
#       *fix*, *bug*, *broken*, *error*    → "fix"
#       *feat*, *add*, *introduce*, *new*   → "feat"
#       *refactor*, *cleanup*, *simplify*   → "refactor"
#       *track*, *tracking*, *follow-up*    → "chore"
#       *doc*, *readme*, *guide*            → "docs"
#       fallback                            → "feat"
#   - scope: the first plausible directory segment under apps/, packages/,
#     services/, src/, or the file's parent directory name. Falls back to
#     empty (no parens).
#   - description: the source's first non-empty line if it looks like a
#     headline (< 80 chars, no markdown heading prefix); else the first
#     "## Context" first sentence; else "<update from source>".
#
# Usage:  derive-title.sh <source-path>
# Output: one line like `feat(create-pr): seed Original Intent from issue`
# Exit 0 always — if the source is empty, prints a generic fallback.

set -euo pipefail

src="${1:?Usage: derive-title.sh <source-path>}"
if [ ! -f "$src" ]; then
  echo "derive-title: source file not found: $src" >&2
  exit 1
fi

body=$(cat "$src")
lower=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')

type="feat"
case "$lower" in
  *fix*|*bug*|*broken*|*error*) type="fix" ;;
  *refactor*|*cleanup*|*simplify*) type="refactor" ;;
  *track*|*follow-up*|*followup*) type="chore" ;;
  *doc*|*readme*|*guide*) type="docs" ;;
  *feat*|*introduce*) type="feat" ;;
esac

# Scope: first matching segment under conventional roots, else parent dir.
scope=""
candidate=$(printf '%s\n' "$body" | grep -oE '(apps|packages|services|src)/[A-Za-z0-9_-]+' | head -1 || true)
if [ -n "$candidate" ]; then
  scope="${candidate##*/}"
else
  scope=$(basename "$(dirname "$src")")
  # Skip noise: plans/, tmp/, etc.
  case "$scope" in plans|tmp|workspace|workspaces|.) scope="" ;; esac
fi

# Description: first non-heading, non-blank, non-metadata line under 80
# chars OR Context section's first sentence. Skip lines like `Status:`,
# `Closes-when:`, `<title>` placeholders.
description=$(printf '%s\n' "$body" | awk '
  /^[#`<]/ { next }
  /^[[:space:]]*$/ { next }
  /^(Status|Closes-when|Purpose|Scope|Non-goals?|Chosen):/ { next }
  {
    sub(/[[:space:]]+$/, "")
    if (length($0) > 0 && length($0) < 80) { print; exit }
  }
' || true)

if [ -z "$description" ]; then
  description=$(printf '%s\n' "$body" | awk '
    /^##[[:space:]]+Context[[:space:]]*$/ { in_section=1; next }
    in_section && /^##[[:space:]]+/ { exit }
    in_section && /^[^#[:space:]]/ {
      sub(/[[:space:]]+$/, "")
      # First sentence: up to first period.
      n = index($0, ".")
      if (n > 0) { print substr($0, 1, n-1) } else { print }
      exit
    }
  ' || true)
fi

[ -z "$description" ] && description="<update from source>"

if [ -n "$scope" ]; then
  printf '%s(%s): %s\n' "$type" "$scope" "$description"
else
  printf '%s: %s\n' "$type" "$description"
fi
