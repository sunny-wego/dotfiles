#!/usr/bin/env bash
# Shared helpers for the investigate skill. Source this; don't execute it.
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted). run() and
# the repo identity/default-branch helpers come from here (this skill's old run()
# was `set -u`-unsafe and its base_branch had no offline fallback).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/run.sh
source "$ZEUS_LIB_DIR/run.sh"
# shellcheck source=../../../lib/repo.sh
source "$ZEUS_LIB_DIR/repo.sh"

die() { echo "investigate: $*" >&2; exit 1; }
log() { echo "investigate: $*" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# base_branch — investigate's name for the repo default branch (now the resilient,
# stack-agnostic resolver from repo.sh; callers unchanged).
base_branch() { repo_default_branch; }

# ── Per-worktree investigation state ────────────────────────────────────────
# Stored under <gitdir>/investigate/ as ONE FILE PER FIELD (epic, project, report,
# slug, linked_prs, …) — not a single state.json + lock. Each field is published by
# atomic rename, so the only fields with more than one writer (a manual `set` vs the
# auto-link hook's `linked_prs`) live in separate files and concurrent writes can't
# lose each other — NO lock needed. `state_get` with no path assembles the unified
# object as a projection over the files. Reads are tolerant (missing field → "").
# A pre-rename manage-incident dir AND a pre-split state.json are migrated on first
# touch, so an in-flight investigation never orphans.

# atomic_write <path> <content> — publish a value by write-to-tmp + rename (sibling
# tmp on the same fs; PID-keyed so concurrent writers don't share a tmp).
atomic_write() {
  local path="$1" content="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$path.tmp.$$"
  printf '%s' "$content" > "$tmp" && mv "$tmp" "$path"
}

# _migrate_state <dir> — split a legacy single-file state.json into per-field files,
# then remove it. Tolerant; invoke as `_migrate_state "$d" || true`.
_migrate_state() {
  local d="$1" j k v
  [ -f "$d/state.json" ] || return 0
  j="$(cat "$d/state.json" 2>/dev/null)" || return 0
  printf '%s' "$j" | jq -e . >/dev/null 2>&1 || return 0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    v="$(printf '%s' "$j" | jq -r --arg k "$k" '.[$k] | if type=="string" then . else tojson end')"
    atomic_write "$d/$k" "$v"
  done < <(printf '%s' "$j" | jq -r 'keys[]')
  rm -f "$d/state.json"
}

state_dir()  {
  local gd; gd="$(git rev-parse --absolute-git-dir)"
  local d="$gd/investigate"
  [ ! -d "$d" ] && [ -d "$gd/manage-incident" ] && mv "$gd/manage-incident" "$d" 2>/dev/null || true
  _migrate_state "$d" || true
  echo "$d"
}

# _assemble_state <dir> — the unified state object, a projection over the field files.
_assemble_state() {
  local d="$1" out='{}' f k
  [ -d "$d" ] || { echo '{}'; return 0; }
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    k="$(basename "$f")"
    case "$k" in *.tmp.*|*.lock|state.json) continue;; esac
    out="$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$(cat "$f")" '.[$k] = $v')"
  done
  printf '%s\n' "$out"
}

# Print state: `state_get` (whole object) or `state_get '.<field>'` (one field).
# Empty string if the field/state is absent. Field values are textual (as before).
state_get() {
  local d k; d="$(state_dir)"
  case "${1:-.}" in
    .)   _assemble_state "$d" ;;
    .*)  k="${1#.}"; if [ -f "$d/$k" ]; then printf '%s\n' "$(cat "$d/$k")"; else echo ""; fi ;;
    *)   echo "" ;;
  esac
}

active_epic() { state_get '.epic'; }

# Resolve a hypothesis reference (H<k>, #<num>, or <num>) to its sub-issue number.
# Hypotheses are sub-issues of $1 (the investigation) titled "H<k>: …" — derived
# from GitHub, never a local map (no drift).
hyp_number() {
  local epic="$1" ref="$2" slug; slug="$(repo_slug)"
  case "$ref" in
    [Hh][0-9]*)
      local k="${ref#[Hh]}"
      gh api "repos/$slug/issues/$epic/sub_issues" \
        --jq ".[] | select(.title|test(\"^H${k}:\")) | .number" 2>/dev/null | head -1 ;;
    \#[0-9]*) echo "${ref#\#}" ;;
    [0-9]*)   echo "$ref" ;;
    *)        echo "" ;;
  esac
}

# True if the gh token can manage Projects.
have_project_scope() { gh auth status 2>&1 | grep -qE "'project'|read:project"; }

# Numeric REST id of an issue/PR (needed by the sub_issues API).
issue_rest_id() { gh api "repos/$(repo_slug)/issues/$1" --jq '.id'; }

# NOTE: the per-worktree state above is now one-file-per-field + atomic rename, so the
# hand-rolled advisory lock this file used to carry (for the hook-vs-manual-set race on
# a single state.json) is gone — concurrent writers touch different files and can't lose
# each other. The sibling skills (address-pr, request-review) still vendor their own
# `with_lock`; converting those is a separate cleanup.
