#!/usr/bin/env bash
# md2storage.sh — markdown on stdin → Confluence storage XHTML on stdout, via
# `mark --compile-only`. This is the default CONFLUENCE_CONVERTER for confluence.sh
# (confluence.sh auto-uses it when `mark` is on PATH and CONFLUENCE_CONVERTER is unset).
#
# mark (kovetskiy/mark, `brew install mark`) is a markdown→Confluence publisher; its
# --compile-only mode prints the converted storage and touches no network/auth. Two
# quirks this adapter papers over:
#
#   1. mark STRIPS the document's first heading (it treats it as the page title,
#      which Confluence renders separately). Our bodies carry the title out-of-band
#      (confluence.sh --title), so the body's first heading is a REAL section. We
#      prepend a sacrificial heading for mark to eat — guaranteeing no real heading
#      is lost whether or not the body opens with one (verified both ways).
#   2. mark requires a space key even in compile-only (it never contacts it). We pass
#      a throwaway --space; nothing is published.
#
# Logs go to stderr; stdout is pure storage XHTML, so callers can capture it cleanly.
# Usage:  <markdown on stdin>  |  md2storage.sh   →  <storage XHTML on stdout>
set -euo pipefail

command -v mark >/dev/null 2>&1 || {
  echo "md2storage: mark not found on PATH. Install it (brew install mark) or point" >&2
  echo "  CONFLUENCE_CONVERTER at another markdown→storage command." >&2
  exit 1
}

tmp="$(mktemp -t md2storage-XXXXXX)" || { echo "md2storage: mktemp failed" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT
# Sacrificial leading heading (mark strips the first one) + the real body.
{ printf '# zeus-title-placeholder\n\n'; cat; } > "$tmp"

mark --compile-only -f "$tmp" --space COMPILEONLY --title-from-filename --log-level ERROR
