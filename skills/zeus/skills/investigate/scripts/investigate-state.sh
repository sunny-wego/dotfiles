#!/usr/bin/env bash
# Read/write the active-investigation state (one file per field, lock-free).
#
# State lives under <gitdir>/investigate/ as one file per field (see lib.sh). Writes
# publish a single field by atomic rename, so a manual `set` and the auto-link hook's
# `linked_prs` write never touch the same file and can't lose each other — no lock.
#
# Usage:
#   investigate-state.sh get [<.field>]         # whole state, or one field; empty if none
#   investigate-state.sh set <key> <value>      # set one field (epic|report|project|view|slug|title|linked_prs)
#   investigate-state.sh set-json <json>        # replace the whole state object
#   investigate-state.sh clear                  # end the investigation (makes the auto-link hook dormant)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require jq; require gh

cmd="${1:-get}"; shift || true
d="$(state_dir)"

case "$cmd" in
  get)
    state_get "${1:-.}"
    ;;
  set)
    [ $# -ge 2 ] || die "set needs <key> <value>"
    # Single-field atomic write — no lock: distinct fields are distinct files.
    atomic_write "$d/$1" "$2"
    log "state.$1 = $2"
    ;;
  set-json)
    [ $# -ge 1 ] || die "set-json needs <json>"
    echo "$1" | jq -e . >/dev/null 2>&1 || die "invalid json"
    # Full replace: drop existing fields, then write each key as its own file.
    rm -rf "$d"; mkdir -p "$d"
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      v="$(echo "$1" | jq -r --arg k "$k" '.[$k] | if type=="string" then . else tojson end')"
      atomic_write "$d/$k" "$v"
    done < <(echo "$1" | jq -r 'keys[]')
    log "state replaced"
    ;;
  clear)
    rm -rf "$d" && log "investigation state cleared (auto-link hook now dormant)"
    ;;
  *)
    die "unknown command: $cmd (get|set|set-json|clear)"
    ;;
esac
