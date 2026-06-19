#!/usr/bin/env bash
# Evaluate the next action in the watch-and-fix loop.
#
# Decision tree (evaluated in order):
#   1. all_passed && mergeable == MERGEABLE && !behind_base && push_exit != 1 →
#        approved_at_head ? fix (real blockers only, no nit sweep) : sweep
#   2. iteration >= max_iterations → report
#   3. push_exit == 1 && pending == 0 → report (stuck)
#   4. push_exit == 1 && pending > 0 → wait (re-enter 4A)
#   5. Default → fix (calls classify-checks.sh for handler list)
#
# Use push_exit = -1 for the pre-fix evaluation (step 4A entry).
# Branches 3-4 only apply after a commit-and-push (push_exit 0 or 1).
#
# Why rule 1 excludes push_exit == 1: a sweep that pushed nothing (push_exit 1)
# has no more review work to do. Without this guard a green+mergeable PR returns
# `sweep` on every pass — rule 3 (the "nothing left, report" terminator) and the
# rule-2 cap both sit *below* rule 1 and never fire — so the loop sweeps forever.
# Excluding push_exit 1 lets a no-op sweep fall through to rule 3 → report, while
# the pre-fix probe (-1) and a progress push (0) still sweep as intended.
#
# Usage: evaluate-iteration.sh <pr_status_file> <push_exit> <iteration> <max_iterations>
#
# Arguments:
#   pr_status_file  - Path to JSON file from pr-status.sh (e.g. /tmp/.address-pr-status.json)
#   push_exit       - Exit code from commit-and-push.sh (0=pushed, 1=nothing, -1=pre-fix)
#   iteration       - Current iteration number (1-based)
#   max_iterations  - Maximum allowed iterations (typically 5)
#
# Outputs JSON:
#   { "action": "fix",    "handlers": [...] }
#   { "action": "sweep",  "reason": "all checks passing and mergeable" }
#   { "action": "report", "reason": "..." }
#   { "action": "wait",   "reason": "..." }
#
# Comment-based handlers (coderabbit, team-reviews) always run after
# check-based handlers — SKILL.md handles that; no need to include them here.
#
# Exit code: always 0 (the action field drives behavior)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pr_status=$(cat "${1:?Usage: evaluate-iteration.sh <pr_status_file> <push_exit> <iteration> <max_iterations>}")
push_exit="${2:?Usage: evaluate-iteration.sh <pr_status_file> <push_exit> <iteration> <max_iterations>}"
iteration="${3:?Usage: evaluate-iteration.sh <pr_status_file> <push_exit> <iteration> <max_iterations>}"
max_iter="${4:?Usage: evaluate-iteration.sh <pr_status_file> <push_exit> <iteration> <max_iterations>}"

all_passed=$(echo "$pr_status" | jq -r '.all_passed')
mergeable=$(echo "$pr_status" | jq -r '.mergeable')
pending=$(echo "$pr_status" | jq -r '.pending')
behind_base=$(echo "$pr_status" | jq -r '.behind_base // false')
approved_at_head=$(echo "$pr_status" | jq -r '.approved_at_head // false')

# 1. All passing + mergeable + up-to-date → sweep (but never on a no-op push:
#    push_exit 1 means the sweep had nothing to push, so fall through to rule 3).
if [ "$all_passed" = "true" ] && [ "$mergeable" = "MERGEABLE" ] && [ "$behind_base" != "true" ] && [ "$push_exit" != "1" ]; then
  # Do-not-churn gate: when the current head already carries a live approval
  # (some non-author reviewer's latest review is APPROVED at this SHA), run
  # reviews in FIX mode instead of SWEEP mode. Sweep mode FIXes nitpicks, and
  # every nit commit dismisses the standing approval and forces a re-review —
  # the loop would undo the very approval it drove toward. Fix mode still
  # addresses genuine blockers (failed checks, CHANGES_REQUESTED, unresolved
  # correctness threads, direct questions) — those legitimately supersede an
  # approval — but DECLINEs nits with a reply rather than committing them.
  # The signal is re-derived from GitHub each pass, so once the head moves past
  # the approved SHA the gate lifts and normal sweeping resumes automatically.
  if [ "$approved_at_head" = "true" ]; then
    classification=$(echo "$pr_status" | bash "$SCRIPT_DIR/classify-checks.sh")
    handlers=$(echo "$classification" | jq -c '.handlers')
    jq -nc --argjson handlers "$handlers" \
      '{action: "fix", handlers: $handlers, reason: "approved on current head; addressing real blockers only (no nit sweep, to preserve the approval)"}'
    exit 0
  fi
  jq -nc '{action: "sweep", reason: "all checks passing and mergeable"}'
  exit 0
fi

# 2. Max iterations → report
if [ "$iteration" -ge "$max_iter" ]; then
  jq -nc --arg reason "max iterations reached ($iteration/$max_iter)" \
    '{action: "report", reason: $reason}'
  exit 0
fi

# 3-4 only apply after a commit-and-push (push_exit != -1)
if [ "$push_exit" != "-1" ]; then
  # 3. Nothing pushed + no pending → stuck
  if [ "$push_exit" = "1" ] && [ "$pending" = "0" ]; then
    jq -nc '{action: "report", reason: "no changes to push and no pending checks"}'
    exit 0
  fi

  # 4. Nothing pushed + pending > 0 → wait for checks
  if [ "$push_exit" = "1" ] && [ "$pending" -gt 0 ]; then
    jq -nc --argjson pending "$pending" \
      '{action: "wait", reason: ("no changes but \($pending) checks still pending")}'
    exit 0
  fi
fi

# 5. Default: classify checks and return handler list
classification=$(echo "$pr_status" | bash "$SCRIPT_DIR/classify-checks.sh")
handlers=$(echo "$classification" | jq -c '.handlers')

jq -nc --argjson handlers "$handlers" '{action: "fix", handlers: $handlers}'
