#!/usr/bin/env bash
# pin-refs.sh — rewrite `path/to/file.ext:NNN[-MMM]` citations in a draft to
# GitHub blob URLs pinned to a SHA. Citations inside fenced code blocks
# (``` ... ```) are left alone.
#
# Usage: pin-refs.sh <draft-path> <sha> <owner/repo>

set -euo pipefail

draft="${1:-}"
sha="${2:-}"
repo="${3:-}"

if [ -z "$draft" ] || [ -z "$sha" ] || [ -z "$repo" ]; then
  echo "usage: pin-refs.sh <draft-path> <sha> <owner/repo>" >&2
  exit 1
fi
if [ ! -f "$draft" ]; then
  echo "error: draft not found: $draft" >&2
  exit 1
fi

python3 - "$draft" "$sha" "$repo" <<'PY'
import re
import sys

draft_path, sha, repo = sys.argv[1], sys.argv[2], sys.argv[3]

with open(draft_path, "r", encoding="utf-8") as f:
    text = f.read()

# Match path:line or path:line-line citations. Path must contain a `/` (avoids
# matching pure filenames in prose like "package.json:1"), end with .ext, and
# the line spec is digits, optional `-digits`.
CITE_RE = re.compile(
    r"(?P<path>(?:[\w./\-]+/)+[\w.\-]+\.[A-Za-z0-9]+):(?P<start>\d+)(?:[-–](?P<end>\d+))?"
)

def is_in_fence(text: str, idx: int) -> bool:
    """True when text[idx] sits inside a ``` fenced block."""
    return text.count("```", 0, idx) % 2 == 1

def rewrite(match: re.Match) -> str:
    if is_in_fence(text, match.start()):
        return match.group(0)
    path = match.group("path")
    start = match.group("start")
    end = match.group("end")
    anchor = f"L{start}" if end is None else f"L{start}-L{end}"
    return f"https://github.com/{repo}/blob/{sha}/{path}#{anchor}"

out = CITE_RE.sub(rewrite, text)

with open(draft_path, "w", encoding="utf-8") as f:
    f.write(out)
PY

echo "pinned $(grep -c 'github.com/'"$repo"'/blob/' "$draft" || true) references to $sha"
