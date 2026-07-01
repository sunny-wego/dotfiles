#!/usr/bin/env bash
# select-mode.sh — decide single-context vs parallel fan-out, deterministically.
# The skill never makes this call by judgment; this script does, from the diff.
#
# Rule: parallel when reviewable_loc >= LOC_THRESHOLD OR reviewable_files >=
# FILE_THRESHOLD; else single. `reviewable` excludes lockfiles, generated/vendored
# output, and docs — so a 2000-line-lockfile PR with 50 lines of code counts as 50.
# Also emits the candidate handler set (path/keyword heuristics) so fan-out only
# spawns lenses the diff actually triggers, and single-context skips the rest.
#
# Overrides: --deep forces parallel, --single forces single (size ignored).
#
# Reads $DIFF_FILE (written by extract-diff.sh). Output JSON:
#   { mode, override, reviewable_loc, reviewable_files, excluded_files,
#     applicable_handlers, loc_threshold, file_threshold }

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Thresholds come from the unified config (lib/config.sh, sourced via lib.sh):
# repo .git/zeus/config.json > user ~/.config/zeus/config.json > shipped default.
# Env ZEUS_REVIEW_LOC_THRESHOLD / ZEUS_REVIEW_FILE_THRESHOLD override for one-offs.
LOC_THRESHOLD="$(config_get review.loc_threshold 400)"
FILE_THRESHOLD="$(config_get review.file_threshold 8)"
override="none"
for a in "$@"; do
  case "$a" in
    --deep) override="deep" ;;
    --single) override="single" ;;
  esac
done
[ -f "$DIFF_FILE" ] || { echo '{"error":"select-mode: missing diff (run extract-diff.sh first)"}' >&2; exit 2; }

python3 "$SCRIPT_DIR/select-mode.py" "$DIFF_FILE" "$LOC_THRESHOLD" "$FILE_THRESHOLD" "$override"
