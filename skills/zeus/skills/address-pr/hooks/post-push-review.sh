#!/usr/bin/env bash
# PostToolUse(Bash) hook: after a git push, nudge the agent to run /zeus:address-pr so
# review comments + checks get handled (not just CI). Lives with the skill it
# invokes; wire it up via hooks/INSTALL.md. Best-effort: exits 0 on every path,
# emits a nudge only when it should.
set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only process git push commands (direct or via the address-pr wrapper script).
# Require `bash ` prefix so grep/cat/Read of the script path don't false-match.
echo "$COMMAND" | grep -qE '\bgit\s+push(\s|$)|\bbash\s+\S*commit-and-(push|evaluate)\.sh\b' || exit 0

# Skip dry-run pushes
echo "$COMMAND" | grep -qE '\-\-dry-run' && exit 0

# Skip pushes directly to main/master (review skills are for PRs)
echo "$COMMAND" | grep -qE 'git\s+push\s+\S+\s+(main|master)\b' && exit 0

# Opt-out: SKIP_REVIEW=1
[[ "${SKIP_REVIEW:-}" == "1" ]] && exit 0

# Instruct Claude to run the review skills via structured JSON
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "IMPORTANT: A git push was just completed. You MUST invoke the /zeus:address-pr skill after this push. The ONLY exception: /zeus:address-pr is already actively running in this conversation turn (to prevent loops). Running `gh pr checks --watch` alone is NOT a substitute — it only checks CI status, not review comments."
  }
}
EOF
exit 0
