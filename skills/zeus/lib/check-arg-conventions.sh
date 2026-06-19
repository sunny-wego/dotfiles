#!/usr/bin/env bash
# check-arg-conventions.sh — lint the zeus PR-workflow skills (address-pr,
# request-review) against the shared CLI identifier convention so it can't
# silently drift back (positional tolerance means a stale call still WORKS,
# so consistency needs an explicit checker, not luck):
#
#   1. repo is ALWAYS one `owner/repo` slug — NEVER a split `<owner> <repo>`,
#      neither in a script's CLI call nor in a doc example.
#   2. the shared parser (resolve_pr / resolve_target) lives in both lib.sh.
#
# Every identifier-taking script routes through resolve_pr/resolve_target — there
# are no exemptions. (fetch-review-comments.sh used to carry a bespoke any-order
# parser; it now uses resolve_target like everything else.)
#
# Exit 0 = clean, 1 = violations (each printed). Run from anywhere.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # zeus/
SKILLS=("$ROOT/skills/address-pr" "$ROOT/skills/request-review")
violations=0
note() { printf '  ✘ %s\n' "$1"; violations=$((violations + 1)); }

echo "zeus arg-convention check"

# 1a. Split-form in a script's CLI call: `<x>.sh "$owner" "$repo"` (any case).
echo "[1] no split <owner> <repo> in script CLI calls"
for d in "${SKILLS[@]}"; do
  [ -d "$d/scripts" ] || continue
  while IFS= read -r hit; do
    note "$hit"
  done < <(grep -rEn '\.sh"? +"\$(owner|OWNER)" +"\$(repo|REPO)"' "$d/scripts" 2>/dev/null || true)
done

# 1b. Split-form placeholder in docs: `<owner> <repo>`.
echo "[2] no split <owner> <repo> in docs"
for d in "${SKILLS[@]}"; do
  while IFS= read -r hit; do
    note "$hit"
  done < <(grep -rEn '<owner> <repo>' "$d" --include='*.md' 2>/dev/null || true)
done

# 2. The shared parser must exist in both lib.sh (the backbone every script uses).
echo "[3] resolve_pr/resolve_target present in both lib.sh"
for d in "${SKILLS[@]}"; do
  lib="$d/scripts/lib.sh"
  if ! grep -q 'resolve_target()' "$lib" 2>/dev/null || ! grep -q 'resolve_pr()' "$lib" 2>/dev/null; then
    note "missing resolve_pr/resolve_target in $lib"
  fi
done

if [ "$violations" -eq 0 ]; then
  echo "OK — no arg-convention violations"
  exit 0
fi
echo "FAIL — $violations violation(s)"
exit 1
