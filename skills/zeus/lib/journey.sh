#!/usr/bin/env bash
# journey.sh — per-worktree shared state for propose / create-pr / address-pr / investigate.
# Vendored IDENTICALLY by each skill (symlinked to lib/journey.sh here), so no skill
# depends on another being installed.
#
# Stored under .git/journey/ as ONE FILE PER FACT (not a single shared journey.json):
#   .git/journey/branch                 last branch that wrote (advisory)
#   .git/journey/issue.json             {number,url,title}   — written by propose
#   .git/journey/pr.json                {number,url}         — written by create-pr
#   .git/journey/investigation/epic     epic number          — written by investigate
#   .git/journey/investigation/report   report path          — written by investigate (optional)
#
# WHY one-file-per-fact instead of a single journey.json + advisory lock:
#   - Each fact has exactly ONE writer class (propose writes issue, create-pr writes pr,
#     investigate writes investigation). Giving each its own file means no two writers ever
#     touch the same file, and every write is published by ATOMIC RENAME (tmp -> mv): a
#     reader sees the whole old or whole new value, and concurrent writers can't lose each
#     other's data. That removes BOTH the hand-rolled mkdir-lock AND the merge-into-namespace
#     jq the single-file layout needed — fewer moving parts, race-free by construction.
#   - The `investigation` namespace is split per FIELD because its writer sets `epic` always
#     but `report` only sometimes; separate files mean an epic-only write can't clobber an
#     existing report (the one spot the old code needed a read-modify-merge).
#   - `lookup` assembles the unified {branch,issue,pr,investigation} object on read, so the
#     single-object view consumers expect survives as a PROJECTION over the files.
#
# Reads are tolerant: a missing file/dir yields "" / "{}" — never an error — so a skill
# behaves the same whether or not the others ever ran. A pre-split .git/journey.json is
# migrated into the new layout on first touch, so an in-flight worktree doesn't orphan.
#
# Usage:
#   journey.sh write-issue <number> <url> <title>
#   journey.sh write-pr    <number> <url>
#   journey.sh write-investigation <epic> [report]   # investigate publishes the active Epic
#   journey.sh lookup                  # full JSON ({} if nothing written)
#   journey.sh issue-number            # bare number or empty
#   journey.sh issue-url               # bare URL or empty
#   journey.sh pr-number               # bare number or empty
#   journey.sh pr-url                  # bare URL or empty
#   journey.sh investigation-epic      # bare Epic number or empty
#   journey.sh clear                   # remove the store

set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "journey.sh: not inside a git worktree" >&2
  exit 1
fi

GITDIR="$(git rev-parse --absolute-git-dir)"
DIR="$GITDIR/journey"            # per-fact store (new layout)
LEGACY="$GITDIR/journey.json"    # pre-split single-file store (migrated away below)
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"

# atomic_write <path> <content> — publish a value by write-to-tmp + rename. The tmp is
# a sibling (same dir => rename is atomic on one filesystem) and PID-keyed so two
# concurrent writers don't trample each other's tmp.
atomic_write() {
  local path="$1" content="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$path.tmp.$$"
  printf '%s' "$content" > "$tmp" && mv "$tmp" "$path"
}

# One-time migration: split a pre-existing journey.json into per-fact files, then remove
# it. Tolerant — a missing or non-JSON legacy file is left untouched. Idempotent and
# lock-free: two racing migrations both write the same values via rename, last wins.
migrate_legacy() {
  [ -f "$LEGACY" ] || return 0
  [ -d "$DIR" ] && return 0
  local j b issue pr epic rep
  j="$(cat "$LEGACY" 2>/dev/null)" || return 0
  printf '%s' "$j" | jq -e . >/dev/null 2>&1 || return 0   # not JSON → don't touch it
  b=$(printf '%s' "$j" | jq -r '.branch // empty')
  [ -n "$b" ] && atomic_write "$DIR/branch" "$b"
  issue=$(printf '%s' "$j" | jq -c 'if (.issue // {} | length) > 0 then .issue else empty end')
  [ -n "$issue" ] && atomic_write "$DIR/issue.json" "$issue"
  pr=$(printf '%s' "$j" | jq -c 'if (.pr // {} | length) > 0 then .pr else empty end')
  [ -n "$pr" ] && atomic_write "$DIR/pr.json" "$pr"
  epic=$(printf '%s' "$j" | jq -r '.investigation.epic // empty')
  if [ -n "$epic" ]; then
    atomic_write "$DIR/investigation/epic" "$epic"
    rep=$(printf '%s' "$j" | jq -r '.investigation.report // empty')
    [ -n "$rep" ] && atomic_write "$DIR/investigation/report" "$rep"
  fi
  rm -f "$LEGACY"
}

cmd="${1:?Usage: journey.sh <write-issue|write-pr|write-investigation|lookup|issue-number|issue-url|pr-number|pr-url|investigation-epic|clear> ...}"

migrate_legacy

case "$cmd" in
  write-issue)
    number="${2:?issue number required}"
    url="${3:?issue url required}"
    title="${4:-}"
    atomic_write "$DIR/branch" "$BRANCH"
    atomic_write "$DIR/issue.json" \
      "$(jq -nc --argjson n "$number" --arg u "$url" --arg t "$title" '{number:$n, url:$u, title:$t}')"
    ;;

  write-pr)
    number="${2:?pr number required}"
    url="${3:?pr url required}"
    atomic_write "$DIR/branch" "$BRANCH"
    atomic_write "$DIR/pr.json" \
      "$(jq -nc --argjson n "$number" --arg u "$url" '{number:$n, url:$u}')"
    ;;

  write-investigation)
    epic="${2:?epic number required}"
    pm="${3:-}"
    atomic_write "$DIR/branch" "$BRANCH"
    atomic_write "$DIR/investigation/epic" "$epic"
    # report is written ONLY when supplied — an epic-only call must not erase a prior report.
    [ -n "$pm" ] && atomic_write "$DIR/investigation/report" "$pm"
    ;;

  investigation-epic)
    if [ -f "$DIR/investigation/epic" ]; then cat "$DIR/investigation/epic"; echo; else echo ""; fi
    ;;

  lookup)
    [ -d "$DIR" ] || { echo '{}'; exit 0; }
    branch=""; [ -f "$DIR/branch" ] && branch="$(cat "$DIR/branch")"
    issue='{}'; [ -f "$DIR/issue.json" ] && issue="$(cat "$DIR/issue.json")"
    pr='{}'; [ -f "$DIR/pr.json" ] && pr="$(cat "$DIR/pr.json")"
    if [ -f "$DIR/investigation/epic" ]; then
      epic="$(cat "$DIR/investigation/epic")"
      rep=""; [ -f "$DIR/investigation/report" ] && rep="$(cat "$DIR/investigation/report")"
      inv="$(jq -nc --argjson e "$epic" --arg r "$rep" '{epic:$e} + (if $r != "" then {report:$r} else {} end)')"
      jq -nc --arg b "$branch" --argjson i "$issue" --argjson p "$pr" --argjson v "$inv" \
        '{branch:$b, issue:$i, pr:$p, investigation:$v}'
    else
      jq -nc --arg b "$branch" --argjson i "$issue" --argjson p "$pr" \
        '{branch:$b, issue:$i, pr:$p}'
    fi
    ;;

  issue-number)
    if [ -f "$DIR/issue.json" ]; then jq -r '.number // empty' "$DIR/issue.json"; else echo ""; fi
    ;;

  issue-url)
    if [ -f "$DIR/issue.json" ]; then jq -r '.url // empty' "$DIR/issue.json"; else echo ""; fi
    ;;

  pr-number)
    if [ -f "$DIR/pr.json" ]; then jq -r '.number // empty' "$DIR/pr.json"; else echo ""; fi
    ;;

  pr-url)
    if [ -f "$DIR/pr.json" ]; then jq -r '.url // empty' "$DIR/pr.json"; else echo ""; fi
    ;;

  clear)
    rm -rf "$DIR"
    rm -f "$LEGACY"
    ;;

  *)
    echo "journey.sh: unknown command: $cmd" >&2
    exit 1
    ;;
esac
