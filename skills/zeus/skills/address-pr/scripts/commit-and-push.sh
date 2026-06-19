#!/usr/bin/env bash
# Stage, commit, and push in one deterministic step.
# Handles both conflict resolution (needs explicit commit) and clean merges
# (auto-commit by git — just needs a push).
#
# After a successful push, flushes the per-iteration reply/resolve queue
# via flush-pending-replies.sh so review replies and thread resolves cite
# the just-pushed SHA (and never land on GitHub before the code actually
# changes). If the push fails, the queue stays untouched and is reported
# in the JSON output's `flush.skipped` field so the caller can surface it
# as `outcome.unresolved`.
#
# Usage: commit-and-push.sh "<commit message>"
#
# Exit codes:
#   0 = Committed and/or pushed successfully
#   1 = Nothing to commit or push
#
# Stdout: JSON { staged, committed, pushed, safe_stage,
#                [commit_error], [push_error],
#                flush: { ... } | { "skipped": true, "reason": "..." } }
# JSON is ALWAYS produced, even on git commit/push failure.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# lib.sh sets `-euo pipefail`; relax `-e` so per-step failures (flush,
# commit, push) are captured into the JSON output rather than aborting.
set +e

msg="${1:?Usage: commit-and-push.sh '<commit message>'}"

# 1. Stage via safe-stage.sh
staged=false
safe_output='{"method":"none","staged":[],"skipped":[]}'
if safe_output=$(bash "$SCRIPT_DIR/safe-stage.sh"); then
  staged=true
fi

# 2. Commit if there are staged changes
# Inner `if` prevents set -e from killing the script on commit failure.
committed=false
commit_error=""
if [ "$staged" = true ]; then
  if commit_err=$(git commit -m "$msg" 2>&1); then
    committed=true
  else
    commit_error="$commit_err"
  fi
fi

# 3. Push if there are unpushed commits (handles merge auto-commits too)
# Inner `if` prevents set -e from killing the script on push failure.
pushed=false
push_error=""
ahead=$(git rev-list "@{u}..HEAD" --count 2>/dev/null || echo "0")
if [ "$ahead" -gt 0 ]; then
  if push_err=$(git push 2>&1); then
    pushed=true
  else
    push_error="$push_err"
  fi
fi

# 4. Flush pending review replies / resolves — only if the push actually
# landed. Cause-and-effect: replies cite the just-pushed SHA, never a
# pre-push promise. If the push failed, the queue is preserved and
# surfaced as `flush.skipped` so the caller can record orphan items in
# the handler outcome.
flush_json='{"skipped": true, "reason": "push did not succeed"}'
if [ "$pushed" = true ]; then
  pr=$(jq -r '.pr // empty' "$STATE_FILE" 2>/dev/null || echo "")
  remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
  # Parse owner/repo from origin url (supports git@host:owner/repo.git and https://host/owner/repo[.git]).
  owner_repo=$(echo "$remote_url" \
    | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
  owner="${owner_repo%/*}"
  repo="${owner_repo##*/}"
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  if [ -n "$pr" ] && [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$sha" ]; then
    if flush_out=$(bash "$SCRIPT_DIR/flush-pending-replies.sh" \
        --pr "$pr" --repo "$owner/$repo" --sha "$sha" 2>&1); then
      flush_json="$flush_out"
    else
      # Capture failure but keep going — caller decides via the JSON.
      if echo "$flush_out" | jq . >/dev/null 2>&1; then
        flush_json="$flush_out"
      else
        flush_json=$(jq -nc --arg detail "$flush_out" \
          '{skipped: false, error: "flush-pending-replies non-zero", detail: $detail}')
      fi
    fi
  else
    flush_json=$(jq -nc \
      --arg pr "$pr" --arg owner "$owner" --arg repo "$repo" --arg sha "$sha" \
      '{skipped: true, reason: "missing pr/owner/repo/sha for flush",
        pr: $pr, owner: $owner, repo: $repo, sha: $sha}')
  fi
fi

# 5. Report — always reached, even after git commit/push failures
jq -nc \
  --argjson staged "$staged" \
  --argjson committed "$committed" \
  --argjson pushed "$pushed" \
  --argjson safe_stage "$safe_output" \
  --arg commit_error "$commit_error" \
  --arg push_error "$push_error" \
  --argjson flush "$flush_json" \
  '{staged: $staged, committed: $committed, pushed: $pushed, safe_stage: $safe_stage, flush: $flush}
   + if $commit_error != "" then {commit_error: $commit_error} else {} end
   + if $push_error != "" then {push_error: $push_error} else {} end'

# Exit 1 if nothing happened
if [ "$committed" = false ] && [ "$pushed" = false ]; then
  exit 1
fi
