#!/usr/bin/env bash
# lib.sh — shared helpers for the implement skill (repo/branch resolution, the
# dry-run run() wrapper). The cross-cutting helpers (repo_default_branch, run) come
# from the family's single copies in zeus/lib/, sourced below — not duplicated here.
set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "implement lib: not inside a git repository" >&2
  exit 1
fi

# Shared family helpers (one copy in zeus/lib/, sourced — never pasted).
ZEUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
# shellcheck source=../../../lib/repo.sh
source "$ZEUS_LIB_DIR/repo.sh"
# shellcheck source=../../../lib/run.sh
source "$ZEUS_LIB_DIR/run.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
export REPO_ROOT CURRENT_BRANCH
