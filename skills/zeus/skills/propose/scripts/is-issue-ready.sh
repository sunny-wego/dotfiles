#!/usr/bin/env bash
# is-issue-ready.sh — heuristic check whether a source file is already
# structured for issue-shape lifting (verbatim) vs needs summarising.
#
# Considered "ready" when ≥ 3 of these markers are present:
#   ^Status:
#   ^Closes-when:
#   ^## Context
#   ^## What's Excluded
#   ^## Verification
#   ^### Q[0-9]
#
# Usage:  is-issue-ready.sh <path>
# Exit:   0 = ready (lift verbatim), 1 = not ready (summarise)
# Stdout: JSON {ready: bool, score: N, markers: [..]}

set -euo pipefail

src="${1:-}"
if [ -z "$src" ] || [ ! -f "$src" ]; then
  echo "usage: is-issue-ready.sh <path>" >&2
  exit 2
fi

markers=()
grep -qE '^Status:' "$src"                && markers+=("Status")
grep -qE '^Closes-when:' "$src"           && markers+=("Closes-when")
grep -qE '^## Context\b' "$src"           && markers+=("Context")
grep -qE "^## What'?s Excluded\b" "$src"  && markers+=("Whats-Excluded")
grep -qE '^## Verification\b' "$src"      && markers+=("Verification")
grep -qE '^### Q[0-9]' "$src"             && markers+=("Q-matrix")

score=${#markers[@]}
ready=false
[ "$score" -ge 3 ] && ready=true

# Emit JSON without requiring jq.
printf '{"ready":%s,"score":%d,"markers":[' "$ready" "$score"
for i in "${!markers[@]}"; do
  [ "$i" -gt 0 ] && printf ','
  printf '"%s"' "${markers[$i]}"
done
printf ']}\n'

if [ "$ready" = "true" ]; then
  exit 0
else
  exit 1
fi
