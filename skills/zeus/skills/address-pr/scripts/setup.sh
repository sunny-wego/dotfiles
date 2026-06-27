#!/usr/bin/env bash
# setup.sh — deterministic full-run / standalone setup for address-pr.
#
# Runs the fixed startup sequence in one shot so its ordering can't drift and
# the best-effort Original-Intent capture can't be silently skipped:
#   1. identify the PR and check the branch out
#   2. init fresh run state (state.sh init) — the loop re-observes GitHub each pass
#   3. capture the PR's Original Intent into run state (best-effort)
#
# Only for the full run and standalone handler mode. The read-only `ready` and
# `monitor` probes must NOT call this — they own their own identify step and
# never write run state.
#
# Usage: setup.sh
# Output JSON: { "pr": N, "branch": "...", "base": "...", "owner": "...", "repo": "..." }
# Exit: 0 on success; non-zero if the PR can't be identified.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Backstop (advisory, stderr only — stdout is JSON the caller parses): if we're
# about to operate in the MAIN checkout instead of an isolated worktree, the
# SKILL.md "Isolate in a worktree" step (ensure-worktree.sh) was skipped. Warn
# but continue, so a deliberate in-place run still works while an accidental one
# is visible rather than silently clobbering the launch branch.
_top=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
case "$_top" in
  */.claude/worktrees/*) : ;;  # already isolated — nothing to say
  *)
    _main=""
    while IFS= read -r _l; do
      case "$_l" in "worktree "*) _main="${_l#worktree }"; break ;; esac
    done < <(git worktree list --porcelain 2>/dev/null)
    if [ "$_top" = "$_main" ]; then
      echo "setup.sh: running in the main checkout ($_top), not an isolated worktree. SKILL.md 'Setup -> Isolate in a worktree' (ensure-worktree.sh) should run first. Continuing in place." >&2
    fi
    ;;
esac

pr_json=$(bash "$SCRIPT_DIR/pr-for-branch.sh" --checkout)
pr=$(echo "$pr_json" | jq -r '.number')
branch=$(echo "$pr_json" | jq -r '.branch')
base=$(echo "$pr_json" | jq -r '.base')
owner=$(echo "$pr_json" | jq -r '.owner')
repo=$(echo "$pr_json" | jq -r '.repo')

# Fresh run state. State is a per-run telemetry log; the probe re-derives status
# from GitHub each pass, so there is nothing to resume.
bash "$SCRIPT_DIR/state.sh" init "$pr" "$branch" "$base" >/dev/null

# Rehydrate cross-skill context from the PR itself, so a fresh worktree (no local
# journey.json / review thread) can pick up where a prior session left off. Reads
# the PR body's hidden journey marker; fills gaps only, never overwrites local
# state. Best-effort — enrichment, not a dependency.
bash "$SCRIPT_DIR/rehydrate.sh" --pr "$pr" --repo "$owner/$repo" --sha "$(git rev-parse HEAD 2>/dev/null || echo "")" >/dev/null 2>&1 || true

# Best-effort scope context for triage and report wording.
bash "$SCRIPT_DIR/original-intent.sh" capture "$pr" >/dev/null 2>&1 || true

jq -nc --argjson pr "$pr" --arg branch "$branch" --arg base "$base" \
  --arg owner "$owner" --arg repo "$repo" \
  '{pr: $pr, branch: $branch, base: $base, owner: $owner, repo: $repo}'
