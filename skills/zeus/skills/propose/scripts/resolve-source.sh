#!/usr/bin/env bash
# resolve-source.sh — pick the source file for propose.
#
# Priority: explicit arg > $CLAUDE_PLAN_FILE > latest .md under
# ~/.claude/plans/ > sentinel "conversation".
#
# Usage:  resolve-source.sh [<path-or-text>]
# Output: one of:
#   path:<absolute-path>   — file resolved
#   inline:<tmp-path>      — arg looked like raw text; written to a tmp file
#   conversation          — no file found; caller summarises the running session

set -euo pipefail

arg="${1:-}"

if [ -n "$arg" ]; then
  if [ -f "$arg" ]; then
    echo "path:$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")"
    exit 0
  fi
  # Anything with whitespace or > 1 line — treat as inline text.
  if printf '%s' "$arg" | grep -qE '[[:space:]]' || [ "$(printf '%s\n' "$arg" | wc -l)" -gt 1 ]; then
    tmp="${CLAUDE_JOB_DIR:-/tmp}/issue-source-$$.md"
    mkdir -p "$(dirname "$tmp")"
    printf '%s\n' "$arg" > "$tmp"
    echo "inline:$tmp"
    exit 0
  fi
  echo "error: arg is neither a file nor inline text: $arg" >&2
  exit 1
fi

if [ -n "${CLAUDE_PLAN_FILE:-}" ] && [ -f "${CLAUDE_PLAN_FILE}" ]; then
  echo "path:${CLAUDE_PLAN_FILE}"
  exit 0
fi

plans_dir="${HOME}/.claude/plans"
if [ -d "$plans_dir" ]; then
  latest=$(find "$plans_dir" -maxdepth 1 -type f -name '*.md' -print0 \
    | xargs -0 ls -t 2>/dev/null | head -n 1)
  if [ -n "$latest" ]; then
    echo "path:$latest"
    exit 0
  fi
fi

echo "conversation"
