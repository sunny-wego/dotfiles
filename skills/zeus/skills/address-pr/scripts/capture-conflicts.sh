#!/usr/bin/env bash
# capture-conflicts.sh — write the current unmerged-path list to the canonical
# $STATE_DIR locations and print the JSON array for downstream consumption.
#
# Outputs (side effects):
#   $STATE_DIR/conflicts.txt          one path per line
#   $STATE_DIR/conflict-files.json    JSON array of paths
#
# stdout: the JSON array (also written to the file).
#
# Usage:  capture-conflicts.sh
# Exit:   0 always (empty conflict list is a valid result — merge succeeded
#         with no conflicts, or merge has not yet been attempted).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

git diff --name-only --diff-filter=U > "$CONFLICTS_FILE"
jq -R -s 'split("\n") | map(select(length > 0))' "$CONFLICTS_FILE" > "$CONFLICT_FILES_FILE"
cat "$CONFLICT_FILES_FILE"
