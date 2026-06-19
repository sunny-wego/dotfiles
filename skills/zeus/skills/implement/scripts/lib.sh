#!/usr/bin/env bash
# lib.sh — shared helpers for the implement skill (repo/branch resolution, the
# dry-run run() wrapper). Per-skill (NOT manifest-vendored): each family skill
# keeps its own lib.sh variant; only journey.sh/preflight.sh are byte-identical.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "implement lib: not inside a git repository" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
export REPO_ROOT CURRENT_BRANCH

# Default branch from the remote (main/master/…). Best-effort: falls back to a
# common-name guess so the precondition guard still works offline.
repo_default_branch() {
  gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null \
    || git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' \
    || echo "main"
}

# DRY_RUN=1 prints the command instead of running it — every mutating helper in
# the family honours this so a run can be previewed against a sandbox.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: %s\n' "$*" >&2
    return 0
  fi
  "$@"
}
