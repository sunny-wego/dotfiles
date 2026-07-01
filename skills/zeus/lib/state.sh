#!/usr/bin/env bash
# state.sh — shared per-worktree state primitives. SOURCE this (don't execute);
# defines functions only, sets no shell options, runs no top-level code.
#
# Four primitives the skills kept re-implementing by hand:
#
#   state_root <skill>            → the per-worktree state dir (<gitdir>/<skill>),
#                                   created if missing. Replaces the
#                                   `STATE_DIR="$(git rev-parse --absolute-git-dir)/<skill>"`
#                                   + `mkdir -p` pair copy-pasted across skill libs.
#   atomic_write <path> <content> → publish a value by write-to-sibling-tmp + rename
#                                   (atomic on one filesystem; PID-keyed tmp so
#                                   concurrent writers don't share a temp file). The
#                                   one-file-per-field store primitive.
#   json_mutate <file> <filter> [jq-args…]
#                                 → read-modify-write a JSON file IN PLACE via the
#                                   tmp+rename dance. Extra args pass through to jq
#                                   (e.g. --arg k v --argjson n 1). Replaces the
#                                   `tmp=$f.tmp; jq … "$f" > "$tmp"; mv "$tmp" "$f"`
#                                   triad repeated ~20× in address-pr's state files.
#   json_field <file> <jq-path> [default]
#                                 → bare value of a field, or <default> (else "") when
#                                   the file is missing or the field is null/absent.
#
# NOTE — journey.sh keeps its OWN copies of atomic_write / _field by design: it is a
# vendored script SYMLINKED into every skill's scripts/, so the cross-skill bus must
# not gain a runtime dependency on lib/ layout that a broken symlink could take down.
# It stays self-contained; these are for the SOURCED consumers (skill lib.sh files).

# state_root <skill> — per-worktree state dir under the gitdir, created if needed.
state_root() {
  local skill="${1:?state_root: skill name required}" gd
  gd="$(git rev-parse --absolute-git-dir)" || return 1
  local d="$gd/$skill"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

# atomic_write <path> <content> — write-to-sibling-tmp + rename (atomic on one fs;
# PID-keyed tmp so concurrent writers don't trample each other's temp file).
atomic_write() {
  local path="${1:?atomic_write: path required}" content="${2-}" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$path.tmp.$$"
  printf '%s' "$content" > "$tmp" && mv "$tmp" "$path"
}

# json_mutate <file> <jq-filter> [jq-args…] — apply a jq filter to <file> in place
# via tmp+rename. Trailing args forward to jq verbatim (--arg / --argjson / …).
json_mutate() {
  local file="${1:?json_mutate: file required}" filter="${2:?json_mutate: filter required}"; shift 2
  local tmp="$file.tmp.$$"
  jq "$@" "$filter" "$file" > "$tmp" && mv "$tmp" "$file"
}

# json_field <file> <jq-path> [default] — bare value of a field, or <default> (else
# "") when the file is missing or the field is null/absent.
json_field() {
  local file="$1" path="$2" def="${3-}" v
  if [ -f "$file" ]; then
    v="$(jq -r "$path // empty" "$file" 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s\n' "$v"; return 0; }
  fi
  printf '%s\n' "$def"
}
