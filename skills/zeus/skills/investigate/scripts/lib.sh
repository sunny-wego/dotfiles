#!/usr/bin/env bash
# Shared helpers for the investigate skill. Source this; don't execute it.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "investigate lib: not inside a git worktree" >&2
  exit 1
fi

DRY_RUN="${DRY_RUN:-0}"

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted). run() and
# the repo identity/default-branch helpers come from here (this skill's old run()
# was `set -u`-unsafe and its base_branch had no offline fallback).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/run.sh
source "$ZEUS_LIB_DIR/run.sh"
# shellcheck source=../../../lib/repo.sh
source "$ZEUS_LIB_DIR/repo.sh"
# atomic_write lives in lib/state.sh (one copy for the family).
# shellcheck source=../../../lib/state.sh
source "$ZEUS_LIB_DIR/state.sh"
# gh_issue_number / ensure_label — shared with propose.
# shellcheck source=../../../lib/gh-issue.sh
source "$ZEUS_LIB_DIR/gh-issue.sh"
# usage_exit / need / unknown_verb — exit 2 on usage (die stays exit 1 for runtime).
# shellcheck source=../../../lib/dispatch.sh
source "$ZEUS_LIB_DIR/dispatch.sh"

die() { echo "investigate: $*" >&2; exit 1; }
log() { echo "investigate: $*" >&2; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# Scripts dir — this lib and the vendored watermark.sh symlink both live here.
INVESTIGATE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# create_labeled_issue <title> <label> <body> [label-desc] — the shared issue-opening
# core for ensure-epic / hypothesis / remediate: idempotently ensure the label exists,
# sign the body with the zeus origin tag, create the issue, and echo its number. Each
# caller does its own sub-issue linking / cross-refs afterward.
create_labeled_issue() {
  local title="$1" label="$2" body="$3" desc="${4:-}" url
  ensure_label "$label" "$desc"
  body="$(printf '%s' "$body" | bash "$INVESTIGATE_SCRIPTS_DIR/watermark.sh" investigate - 2>/dev/null || printf '%s' "$body")"
  url="$(gh issue create --title "$title" --label "$label" --body "$body")"
  gh_issue_number "$url"
}

# add_to_board <issue-or-pr-url> — add the URL to the recorded project board, if any.
# No-op (with a log line) when project scope is missing, no project is recorded, or
# DRY_RUN=1. Shared by ensure-epic / link-to-epic.
add_to_board() {
  local url="$1" proj; proj="$(state_get '.project')"
  [ -n "$proj" ] || { log "no project recorded in state — skipping board"; return 0; }
  have_project_scope || { log "no project scope — skipping board (gh auth refresh -s project to enable)"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] gh project item-add $proj --owner $(repo_owner) --url $url" >&2; return 0; fi
  run gh project item-add "$proj" --owner "$(repo_owner)" --url "$url" --format json >/dev/null \
    && log "added to board #$proj"
}

# ── Per-worktree investigation state ────────────────────────────────────────
# Stored under <gitdir>/investigate/ as ONE FILE PER FIELD (epic, project, report,
# slug, linked_prs, …) — not a single state.json + lock. Each field is published by
# atomic rename, so the only fields with more than one writer (a manual `set` vs the
# auto-link hook's `linked_prs`) live in separate files and concurrent writes can't
# lose each other — NO lock needed. `state_get` with no path assembles the unified
# object as a projection over the files. Reads are tolerant (missing field → "").
# A pre-rename manage-incident dir AND a pre-split state.json are migrated on first
# touch, so an in-flight investigation never orphans.

# atomic_write comes from lib/state.sh (sourced above) — one copy for the family.

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
  # Migrate a pre-rename manage-incident dir BEFORE state_root creates the new one.
  [ ! -d "$gd/investigate" ] && [ -d "$gd/manage-incident" ] && mv "$gd/manage-incident" "$gd/investigate" 2>/dev/null || true
  local d; d="$(state_root investigate)"   # shared per-worktree dir (lib/state.sh) + mkdir
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
