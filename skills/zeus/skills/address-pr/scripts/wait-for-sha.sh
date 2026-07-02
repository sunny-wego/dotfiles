#!/usr/bin/env bash
# Wait until GitHub's PR head SHA matches the expected local SHA.
# Polls up to 6 times (60s total) with 10s intervals.
#
# Usage: wait-for-sha.sh --pr <n> --sha <expected_sha>   (identifiers also positional)
#
# Exit codes:
#   0 = SHA matched
#   1 = Timeout (SHA still mismatched after all retries)
#
# Stdout: JSON { "matched": bool, "expected": "...", "actual": "..." }

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

resolve_pr "$@"
pr="$PR"; expected="$SHA"
need "$pr" "Usage: wait-for-sha.sh --pr <n> --sha <expected_sha>"
need "$expected" "Usage: wait-for-sha.sh --pr <n> --sha <expected_sha>"

MAX_RETRIES=6
INTERVAL=10

for i in $(seq 1 "$MAX_RETRIES"); do
  actual=$(gh pr view "$pr" --json headRefOid -q '.headRefOid' 2>/dev/null) || {
    echo "API error fetching SHA (attempt $i)" >&2
    sleep "$INTERVAL"
    continue
  }

  if [ "$actual" = "$expected" ]; then
    jq -nc --arg expected "$expected" --arg actual "$actual" \
      '{matched: true, expected: $expected, actual: $actual}'
    exit 0
  fi

  if [ "$i" -lt "$MAX_RETRIES" ]; then
    sleep "$INTERVAL"
  fi
done

jq -nc --arg expected "$expected" --arg actual "${actual:-unknown}" \
  '{matched: false, expected: $expected, actual: $actual}'
exit 1
