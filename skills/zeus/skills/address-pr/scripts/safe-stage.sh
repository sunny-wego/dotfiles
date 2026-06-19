#!/usr/bin/env bash
# Stage files safely — detects untracked debris outside known dirs
# and stages only relevant files when debris exists.
#
# Usage: safe-stage.sh
#
# Exit codes:
#   0 = Files staged successfully
#   1 = Nothing to stage
#
# Stdout: JSON { "method": "all"|"selective", "staged": [...], "skipped": [...] }

set -euo pipefail

# Known source directories — untracked files outside these are considered debris.
# NOTE: Debris filtering only applies to NEW untracked files.
# Modified tracked files are always staged regardless of path (line 59).
KNOWN_PATTERNS='src/|apps/|packages/|\.github/|public/|lib/|test/|tests/|__tests__/|\.changeset/'

# Tracked changes (modified, deleted, renamed)
tracked=$(git diff --name-only HEAD 2>/dev/null || true)
staged_already=$(git diff --name-only --cached 2>/dev/null || true)

# New untracked files (respects .gitignore)
untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)

# Check if there's anything to stage
if [ -z "$tracked" ] && [ -z "$staged_already" ] && [ -z "$untracked" ]; then
  jq -nc '{method: "none", staged: [], skipped: []}'
  exit 1
fi

# Classify untracked files
debris_files=""
clean_untracked=""

if [ -n "$untracked" ]; then
  while IFS= read -r file; do
    if echo "$file" | grep -qE "^($KNOWN_PATTERNS)" ; then
      clean_untracked="${clean_untracked}${file}"$'\n'
    else
      debris_files="${debris_files}${file}"$'\n'
    fi
  done <<< "$untracked"
fi

# Remove trailing newlines
debris_files=$(echo "$debris_files" | sed '/^$/d')
clean_untracked=$(echo "$clean_untracked" | sed '/^$/d')

if [ -z "$debris_files" ]; then
  # No debris — safe to stage everything
  git add -A
  all_staged=$(git diff --name-only --cached HEAD 2>/dev/null || true)
  staged_json=$(echo "$all_staged" | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -nc --argjson staged "$staged_json" \
    '{method: "all", staged: $staged, skipped: []}'
else
  # Debris detected — stage tracked changes + clean untracked only
  if [ -n "$tracked" ]; then
    echo "$tracked" | tr '\n' '\0' | xargs -0 git add -- 2>/dev/null || true
  fi
  if [ -n "$clean_untracked" ]; then
    echo "$clean_untracked" | tr '\n' '\0' | xargs -0 git add -- 2>/dev/null || true
  fi

  staged_json=$(git diff --name-only --cached HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))')
  skipped_json=$(echo "$debris_files" | jq -R -s 'split("\n") | map(select(length > 0))')
  jq -nc --argjson staged "$staged_json" --argjson skipped "$skipped_json" \
    '{method: "selective", staged: $staged, skipped: $skipped}'
fi

exit 0
