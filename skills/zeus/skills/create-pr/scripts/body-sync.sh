#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  body-sync.sh has-managed-block <body-file|->
  body-sync.sh extract-original-intent <body-file|->
  body-sync.sh extract-managed <body-file|->
  body-sync.sh replace-managed <body-file> <managed-file>
USAGE
  exit 1
}

read_body() {
  local source="$1"

  if [ "$source" = "-" ]; then
    cat
  else
    cat "$source"
  fi
}

extract_original_intent() {
  local source="$1"

  read_body "$source" | awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+Original Intent[[:space:]]*$/ {
      in_section = 1
      print
      next
    }
    /^##[[:space:]]+/ {
      if (in_section) {
        exit
      }
    }
    /^<!--[[:space:]]*create-pr:managed:start[[:space:]]*-->$/ {
      if (in_section) {
        exit
      }
    }
    in_section { print }
  '
}

has_managed_block() {
  local source="$1"
  local body

  body=$(read_body "$source")
  if printf '%s' "$body" | grep -Fq "$MANAGED_START" && printf '%s' "$body" | grep -Fq "$MANAGED_END"; then
    return 0
  fi

  return 1
}

extract_managed() {
  local source="$1"

  has_managed_block "$source" || exit 2

  read_body "$source" | awk -v start="$MANAGED_START" -v end="$MANAGED_END" '
    $0 == start { in_section = 1; next }
    $0 == end { exit }
    in_section { print }
  '
}

replace_managed() {
  local body_file="$1"
  local managed_file="$2"

  has_managed_block "$body_file" || exit 2

  awk -v start="$MANAGED_START" -v end="$MANAGED_END" -v managed_file="$managed_file" '
    $0 == start {
      print
      while ((getline line < managed_file) > 0) {
        print line
      }
      close(managed_file)
      in_section = 1
      next
    }
    $0 == end {
      in_section = 0
      print
      next
    }
    !in_section { print }
  ' "$body_file"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  has-managed-block)
    [ "$#" -eq 1 ] || usage
    has_managed_block "$1"
    ;;
  extract-original-intent)
    [ "$#" -eq 1 ] || usage
    extract_original_intent "$1"
    ;;
  extract-managed)
    [ "$#" -eq 1 ] || usage
    extract_managed "$1"
    ;;
  replace-managed)
    [ "$#" -eq 2 ] || usage
    replace_managed "$1" "$2"
    ;;
  *)
    usage
    ;;
esac
