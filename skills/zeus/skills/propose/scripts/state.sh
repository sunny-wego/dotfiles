#!/usr/bin/env bash
# state.sh — persist/load the /zeus:propose state JSON, keyed to a proposal REF.
#
# WHY: for RFC-grade / iterated proposals, the state JSON is the source of truth
# and the published artifact (GitHub issue body / Confluence page) is a render of
# it. Amends edit STATE and re-render, so unrelated sections stay coherent by
# construction (never hand-patch the live artifact). This helper gives the state a
# durable, per-worktree home keyed to the proposal, so a later number-less
# `/zeus:propose "fold in X"` can reload it.
#
# A REF identifies the proposal and its destination (parity across GitHub +
# Confluence — see confluence-target.sh):
#   <number>            GitHub issue (e.g. 840)         → store file issue-<n>.state.json
#   confluence:<pageId> Confluence page (e.g. confluence:3975118867)
#                                                       → store file page-<id>.state.json
#   draft               first compose, no id yet        → store file issue-draft.state.json
# A bare number stays the GitHub form verbatim, so every pre-existing
# issue-<n>.state.json file and `current` pin keeps resolving unchanged.
#
# Stored under <gitdir>/propose/ — beside journey.json but NOT in it:
# journey.json is the cross-skill handoff (durable facts other skills read);
# run-internals like this state live in the skill's own dir. (The skill was
# renamed create-issue → propose; a pre-rename `create-issue/` store is migrated
# into place on first touch, below, so existing proposals don't orphan.)
#
# Usage:
#   state.sh path <ref>
#   state.sh save <ref> <state-file>   # prints the stored path
#   state.sh load <ref>                # prints state JSON, or "" if none
#   state.sh list                      # JSON array of {provider, ref, number, title,
#                                       # review, updated_at} for every proposal this
#                                       # skill touched in THIS worktree, newest first.
#                                       # Feeds resolve-target.sh.
#   state.sh pin <ref>                 # record <ref> as this worktree's ACTIVE proposal
#                                       # (the /zeus:propose dispatch resume target)
#   state.sh current                   # print the pinned active proposal ref, or ""

set -euo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "state.sh: not inside a git worktree" >&2; exit 1; }

gitdir="$(git rev-parse --absolute-git-dir)"
dir="$gitdir/propose"
# One-time migration: the skill was renamed create-issue → propose. If a pre-rename
# store exists and the new one doesn't, move it so persisted proposals keep resolving.
if [ ! -d "$dir" ] && [ -d "$gitdir/create-issue" ]; then
  mv "$gitdir/create-issue" "$dir" 2>/dev/null || true
fi
cmd="${1:?Usage: state.sh <path|save|load|list|pin|current> [<ref>] [state-file]}"

# ref_to_file — map a proposal ref to its store filename. A bare number (or `draft`)
# keeps the historical issue-<key> name; a confluence:<id> ref maps to page-<id> so
# the GitHub store layout is byte-for-byte unchanged and the colon never hits a path.
ref_to_file() {
  case "$1" in
    confluence:*) echo "$dir/page-${1#confluence:}.state.json" ;;
    *)            echo "$dir/issue-$1.state.json" ;;
  esac
}

# `current` — read the worktree's pinned active proposal ref (no key needed).
if [ "$cmd" = "current" ]; then
  [ -f "$dir/current" ] && cat "$dir/current" || echo ""
  exit 0
fi

if [ "$cmd" = "list" ]; then
  # Newest-touched first, across BOTH destinations. `draft` keys excluded (no
  # posted artifact to amend). GitHub rows carry a numeric `number` (back-compat
  # for resolve-target); Confluence rows carry number:null and ref:"confluence:<id>".
  rows=()
  # shellcheck disable=SC2012
  for f in $(ls -t "$dir"/issue-*.state.json "$dir"/page-*.state.json 2>/dev/null); do
    bn="$(basename "$f" .state.json)"
    case "$bn" in
      issue-*)
        key="${bn#issue-}"
        case "$key" in (*[!0-9]*) continue ;; esac   # skip `draft` etc.
        provider="github"; ref="$key"; numarg="$key" ;;
      page-*)
        key="${bn#page-}"
        provider="confluence"; ref="confluence:$key"; numarg="null" ;;
      *) continue ;;
    esac
    title=$(jq -r '.title // ""' "$f" 2>/dev/null || echo "")
    review=$(jq -r '.review // "auto"' "$f" 2>/dev/null || echo "auto")
    ts=$(date -r "$f" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
    rows+=("$(jq -nc --arg p "$provider" --arg ref "$ref" --argjson num "$numarg" \
      --arg t "$title" --arg r "$review" --arg u "$ts" \
      '{provider:$p, ref:$ref, number:$num, title:$t, review:$r, updated_at:$u}')")
  done
  if [ "${#rows[@]}" -eq 0 ]; then echo "[]"; else printf '%s\n' "${rows[@]}" | jq -s '.'; fi
  exit 0
fi

key="${2:?<ref> required}"
file="$(ref_to_file "$key")"

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
    # record <ref> as this worktree's active proposal (the dispatch resume target)
    mkdir -p "$dir"
    # Atomic write-then-rename (see `save`): two concurrent pins resolve to one
    # complete value (last writer wins), never a torn pointer — no lock needed.
    tmp="$dir/current.tmp.$$"
    printf '%s\n' "$key" > "$tmp" && mv "$tmp" "$dir/current"
    echo "$dir/current"
    ;;
  *) echo "state.sh: unknown command: $cmd" >&2; exit 1 ;;
esac
