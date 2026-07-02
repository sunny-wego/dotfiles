#!/usr/bin/env bash
# check-arg-conventions.sh — lint the zeus skills against the shared CLI conventions
# so they can't silently drift back (positional tolerance means a stale call still
# WORKS, so consistency needs an explicit checker, not luck). Rules [1]/[2]/[8] span
# ALL skills; [3] targets the PR-workflow pair (address-pr, request-review) where the
# parser is sourced:
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
# Usage: check-arg-conventions.sh   (no args; run from anywhere)
# Exit 0 = clean, 1 = violations (each printed).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # zeus/
SKILLS=("$ROOT/skills/address-pr" "$ROOT/skills/request-review")   # the PR-workflow pair (rule [3])
ALL_SKILLS=()                                                      # every skill (rules [1]/[2]/[8])
for _d in "$ROOT"/skills/*/; do [ -d "$_d" ] && ALL_SKILLS+=("${_d%/}"); done
violations=0
note() { printf '  ✘ %s\n' "$1"; violations=$((violations + 1)); }

echo "zeus arg-convention check"

# 1a. Split-form in a script's CLI call: `<x>.sh "$owner" "$repo"` (any case).
# Checked across ALL skills — the split form must not exist anywhere, not just the pair.
echo "[1] no split <owner> <repo> in script CLI calls"
for d in "${ALL_SKILLS[@]}"; do
  [ -d "$d/scripts" ] || continue
  while IFS= read -r hit; do
    note "$hit"
  done < <(grep -rEn '\.sh"? +"\$(owner|OWNER)" +"\$(repo|REPO)"' "$d/scripts" 2>/dev/null || true)
done

# 1b. Split-form placeholder in docs: `<owner> <repo>` — checked across ALL skills.
echo "[2] no split <owner> <repo> in docs"
for d in "${ALL_SKILLS[@]}"; do
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

# 4. Every PR-identifier script ROUTES THROUGH the parser — no hand-rolled `--pr)`
#    cases (they'd accept the same flag but duplicate the parse and drift). Scoped to
#    `--pr` (the PR identifier): issue-centric skills (e.g. propose) legitimately
#    take `--repo` without `--pr` and use their own issue resolution, and the PR
#    *resolvers* themselves (identify-pr.sh, detect-target.sh, pr-ident.sh) are the
#    parser, so they're exempt by construction (they don't parse a bare `--pr)`).
echo "[5] no hand-rolled --pr parsing (route through resolve_pr/resolve_target)"
while IFS= read -r f; do
  grep -qE '^[[:space:]]*--pr[)=]' "$f" || continue
  grep -q 'resolve_pr\|resolve_target' "$f" || note "$f parses --pr but bypasses resolve_pr/resolve_target"
done < <(find "$ROOT"/skills -name '*.sh' -type f 2>/dev/null)

# 6. Publish backends (propose) conform to references/publish-contract.md: each
#    exposes the three verbs (create implied by --title/--body-file; --update;
#    --comment) and wires the two IN-BACKEND gates (review-gate.sh, ownership.sh),
#    so a new/edited backend can't silently skip enforcement. The drift gate's
#    location is mechanism-dependent (in-backend for version-based, orchestrator for
#    text-diff), so it's out of the machine-checkable subset by construction.
echo "[6] publish backends conform to publish-contract.md (verbs + in-backend gates)"
PUBLISH_BACKENDS=("$ROOT/skills/propose/scripts/post-issue.sh" "$ROOT/skills/propose/scripts/confluence.sh")
for b in "${PUBLISH_BACKENDS[@]}"; do
  if [ ! -f "$b" ]; then note "publish backend missing: $b"; continue; fi
  name="$(basename "$b")"
  grep -q -- '--body-file)' "$b" || note "$name: no --body-file (create verb)"
  grep -q -- '--update)'    "$b" || note "$name: no --update verb"
  grep -q -- '--comment)'   "$b" || note "$name: no --comment verb"
  grep -q 'review-gate.sh'  "$b" || note "$name: does not call the shared review-gate.sh"
  grep -q 'ownership.sh'    "$b" || note "$name: does not call ownership.sh (ownership gate)"
done

# 7. Sub-agents are defined ONCE in agents/ and referenced BY NAME. Every
#    `zeus:<name>` token in the skills must resolve to an agent (agents/<name>.md)
#    or a skill (skills/<name>/ — a legit by-name hand-off), so a typo'd or dangling
#    agent reference can't ship. Plus the two invariants the archetypes exist to
#    ENFORCE structurally: cold-reader has no tools (text-only), diagnostician is
#    read-only (no Bash/Edit/Write) — if either drifts, the "never mutate" / "no repo
#    access" guarantees the SKILLs lean on become prose again.
echo "[7] sub-agent references resolve + read-only invariants hold"
AGENTS_DIR="$ROOT/agents"
agent_names=""
if [ -d "$AGENTS_DIR" ]; then
  for f in "$AGENTS_DIR"/*.md; do
    [ -f "$f" ] || continue
    n="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
    [ -n "$n" ] || n="$(basename "$f" .md)"
    agent_names="$agent_names $n"
  done
fi
skill_names=""
for d in "$ROOT"/skills/*/; do
  [ -d "$d" ] && skill_names="$skill_names $(basename "$d")"
done
while IFS= read -r ref; do
  name="${ref#zeus:}"
  case " $agent_names $skill_names " in
    *" $name "*) : ;;
    *) note "dangling zeus:$name reference (no agents/$name.md or skills/$name/)" ;;
  esac
done < <(grep -rhoE 'zeus:[a-z][a-z-]+' "$ROOT"/skills "$AGENTS_DIR" 2>/dev/null | sort -u)
CR="$AGENTS_DIR/cold-reader.md"
if [ -f "$CR" ]; then
  grep -qE '^tools:[[:space:]]*""[[:space:]]*$' "$CR" \
    || note "cold-reader.md must ship tools: \"\" (text-only, no repo/tool access)"
fi
DG="$AGENTS_DIR/diagnostician.md"
if [ -f "$DG" ]; then
  case "$(sed -n 's/^tools:[[:space:]]*//p' "$DG" | head -1)" in
    *Bash*|*Edit*|*Write*) note "diagnostician.md must stay read-only (no Bash/Edit/Write in tools:)" ;;
  esac
fi

# 8. Skills call skills BY NAME, never another skill's script by path/basename. A
#    legit intra-skill call always carries a path (${CLAUDE_SKILL_DIR}/scripts/…,
#    $SCRIPT_DIR/…), so a BARE-basename invocation ($(x.sh …), | x.sh, bash x.sh) of a
#    script that lives in ANOTHER skill's scripts/ (and not this skill's own, nor lib/)
#    is the house-rule violation that let request-review call address-pr's
#    ready-for-review.sh slip through. Own-skill shorthand ($(render.sh …) in propose's
#    docs) and shared lib/ scripts are fine.
echo "[8] no cross-skill script call by bare basename (invoke the owner skill by name)"
for d in "${ALL_SKILLS[@]}"; do
  sk="$(basename "$d")"; own="$d/scripts"
  while IFS=: read -r file lineno text; do
    [ -n "$file" ] || continue
    for bn in $(printf '%s' "$text" \
                  | grep -oE '(\$\(|\|[[:space:]]*|bash[[:space:]]+)[A-Za-z0-9_.-]+\.sh' \
                  | grep -oE '[A-Za-z0-9_.-]+\.sh' | sort -u); do
      [ -e "$own/$bn" ] && continue          # this skill's own script → fine
      [ -e "$ROOT/lib/$bn" ] && continue      # shared vendored/lib script → fine
      if ls "$ROOT"/skills/*/scripts/"$bn" >/dev/null 2>&1; then
        note "$file:$lineno calls $bn by bare name — it's owned by another skill; invoke that skill by name, not its script"
      fi
    done
  done < <(grep -rEn '(\$\(|\|[[:space:]]*|bash[[:space:]]+)[A-Za-z0-9_.-]+\.sh' \
             "$d" --include='*.sh' --include='*.md' 2>/dev/null || true)
done

if [ "$violations" -eq 0 ]; then
  echo "OK — no arg-convention violations"
  exit 0
fi
echo "FAIL — $violations violation(s)"
exit 1
