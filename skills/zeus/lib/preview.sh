#!/usr/bin/env bash
# preview.sh — emit title + first N lines of a draft body for the
# AskUserQuestion confirmation step.
#
# VENDORED IDENTICALLY across create-pr and propose (same doctrine as
# journey.sh) so the confirm UX is consistent across the journey and a fix in
# one copy is a byte-copy to the other. Both historical call shapes work:
#
#   preview.sh <title> <body-file> [<lines=60>]   # create-pr: explicit title
#   preview.sh <draft-path> [<lines=60>]          # propose: title is the
#                                                 # draft's first non-empty line
#
# Disambiguation: if the first argument is an existing file, it's the draft and
# the title is derived from (and skipped in) its content; otherwise it's the
# explicit title and the second argument is the body file.
#
# Output:
#   TITLE: <title>
#   ---
#   <first N lines of the body>

set -euo pipefail

if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
  # Shape 2: <draft-path> [<lines>] — derive the title from the draft.
  draft="$1"
  lines="${2:-60}"
  title=$(awk 'NF{print; exit}' "$draft")
  echo "TITLE: $title"
  echo "---"
  # Skip the title line, dump the next N body lines.
  tail -n +2 "$draft" | head -n "$lines"
else
  # Shape 1: <title> <body-file> [<lines>].
  title="${1:-}"
  body_file="${2:-}"
  lines="${3:-60}"
  if [ -z "$title" ] || [ -z "$body_file" ] || [ ! -f "$body_file" ]; then
    echo "usage: preview.sh <title> <body-file> [<lines>]  |  preview.sh <draft-path> [<lines>]" >&2
    exit 1
  fi
  echo "TITLE: $title"
  echo "---"
  head -n "$lines" "$body_file"
fi
