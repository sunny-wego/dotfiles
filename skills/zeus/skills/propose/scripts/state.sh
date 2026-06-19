#!/usr/bin/env bash
# state.sh — persist/load the /zeus:propose state JSON keyed to an issue number.
#
# WHY: for RFC-grade / iterated issues, the state JSON is the source of truth and
# the issue body is a render of it. Amends edit STATE and re-render, so unrelated
# sections stay coherent by construction (never hand-patch the live body). This
# helper gives the state a durable, per-worktree home keyed to the issue number,
# so a later `/zeus:propose <#N> "fold in X"` can reload it.
#
# Stored under <gitdir>/propose/ — beside journey.json but NOT in it:
# journey.json is the cross-skill handoff (durable facts other skills read);
# run-internals like this state live in the skill's own dir. (The skill was
# renamed create-issue → propose; a pre-rename `create-issue/` store is migrated
# into place on first touch, below, so existing issues don't orphan.)
#
# Use key `draft` before the issue number exists (first compose), then re-save
# under the real number once post-issue.sh returns it.
#
# Usage:
#   state.sh path <number|draft>
#   state.sh save <number|draft> <state-file>   # prints the stored path
#   state.sh load <number|draft>                # prints state JSON, or "" if none
#   state.sh list                               # JSON array of {number, title, review, updated_at}
#                                               # for every issue this skill has touched in THIS
#                                               # worktree (store is per absolute-git-dir),
#                                               # newest-touched first. Feeds resolve-target.sh.
#   state.sh pin <number>                       # record <number> as this worktree's ACTIVE
#                                               # proposal (the /zeus:propose dispatch resume target)
#   state.sh current                            # print the pinned active proposal number, or ""

set -euo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "state.sh: not inside a git worktree" >&2; exit 1; }

gitdir="$(git rev-parse --absolute-git-dir)"
dir="$gitdir/propose"
# One-time migration: the skill was renamed create-issue → propose. If a pre-rename
# store exists and the new one doesn't, move it so persisted issues keep resolving.
if [ ! -d "$dir" ] && [ -d "$gitdir/create-issue" ]; then
  mv "$gitdir/create-issue" "$dir" 2>/dev/null || true
fi
cmd="${1:?Usage: state.sh <path|save|load|list|pin|current> [<number|draft>] [state-file]}"

# `current` — read the worktree's pinned active proposal (no key needed).
if [ "$cmd" = "current" ]; then
  [ -f "$dir/current" ] && cat "$dir/current" || echo ""
  exit 0
fi

if [ "$cmd" = "list" ]; then
  # Newest-touched first; `draft` keys excluded (no posted issue to amend).
  out="["
  first=1
  # shellcheck disable=SC2012
  for f in $(ls -t "$dir"/issue-*.state.json 2>/dev/null); do
    key="$(basename "$f" .state.json)"; key="${key#issue-}"
    case "$key" in (*[!0-9]*) continue ;; esac
    title=$(jq -r '.title // ""' "$f" 2>/dev/null || echo "")
    review=$(jq -r '.review // "auto"' "$f" 2>/dev/null || echo "auto")
    ts=$(date -r "$f" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
    [ "$first" -eq 0 ] && out="$out,"
    out="$out$(jq -nc --arg n "$key" --arg t "$title" --arg r "$review" --arg u "$ts" \
      '{number: ($n|tonumber), title: $t, review: $r, updated_at: $u}')"
    first=0
  done
  echo "$out]"
  exit 0
fi

key="${2:?<number|draft> required}"
file="$dir/issue-${key}.state.json"

case "$cmd" in
  path) echo "$file" ;;
  save)
    src="${3:?state-file required}"
    [ -f "$src" ] || { echo "state.sh: state file not found: $src" >&2; exit 1; }
    mkdir -p "$dir"
    # Atomic publish: write a sibling tmp, then rename over the target. A reader
    # (or a concurrent writer) sees the whole old or whole new file, never a
    # partial copy — so this single-writer-per-key store needs no lock. The tmp
    # is keyed by PID so two concurrent saves don't trample each other's tmp.
    tmp="$file.tmp.$$"
    cp "$src" "$tmp" && mv "$tmp" "$file"
    echo "$file"
    ;;
  load) [ -f "$file" ] && cat "$file" || echo "" ;;
  pin)
    # record <number> as this worktree's active proposal (the dispatch resume target)
    mkdir -p "$dir"
    # Atomic write-then-rename (see `save`): two concurrent pins resolve to one
    # complete value (last writer wins), never a torn pointer — no lock needed.
    tmp="$dir/current.tmp.$$"
    printf '%s\n' "$key" > "$tmp" && mv "$tmp" "$dir/current"
    echo "$dir/current"
    ;;
  *) echo "state.sh: unknown command: $cmd" >&2; exit 1 ;;
esac
