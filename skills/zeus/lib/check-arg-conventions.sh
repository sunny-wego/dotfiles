#!/usr/bin/env bash
# check-arg-conventions.sh — lint the zeus PR-workflow skills (address-pr,
# request-review) against the shared CLI identifier convention so it can't
# silently drift back (positional tolerance means a stale call still WORKS,
# so consistency needs an explicit checker, not luck):
#
#   1. repo is ALWAYS one `owner/repo` slug — NEVER a split `<owner> <repo>`,
#      neither in a script's CLI call nor in a doc example.
#   2. the shared parser (resolve_pr / resolve_target) lives in ONE place
#      (lib/pr-ident.sh), is sourced by the PR-workflow libs, and is NEVER
#      re-pasted into a skill lib.sh (the copies had drifted before they were
#      centralized — the regression guard below keeps them from coming back).
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

# 2. The shared parser is defined ONCE in lib/pr-ident.sh, SOURCED by the
#    PR-workflow libs, and never re-pasted into a skill lib.sh.
echo "[3] resolve_pr/resolve_target defined once in lib/pr-ident.sh and sourced"
PRIDENT="$ROOT/lib/pr-ident.sh"
if ! grep -q 'resolve_pr()' "$PRIDENT" 2>/dev/null || ! grep -q 'resolve_target()' "$PRIDENT" 2>/dev/null; then
  note "lib/pr-ident.sh missing resolve_pr/resolve_target"
fi
for d in "${SKILLS[@]}"; do
  lib="$d/scripts/lib.sh"
  grep -q 'pr-ident.sh' "$lib" 2>/dev/null || note "$lib does not source lib/pr-ident.sh"
done

# 3. Regression guard: a skill lib.sh must SOURCE the shared helpers, never define
#    its own copy (this is what let resolve_pr/with_lock/run drift across skills).
echo "[4] no shared helper re-defined in a skill lib.sh (source it from lib/)"
while IFS= read -r hit; do
  note "re-defines a shared helper — source it from lib/ instead: $hit"
done < <(grep -rEn '^(resolve_pr|resolve_target|with_lock|run|repo_default_branch)\(\)' \
           "$ROOT"/skills/*/scripts/lib.sh 2>/dev/null || true)

if [ "$violations" -eq 0 ]; then
  echo "OK — no arg-convention violations"
  exit 0
fi
echo "FAIL — $violations violation(s)"
exit 1
