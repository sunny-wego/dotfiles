#!/usr/bin/env bash
# migrate-config.sh — ONE-TIME migration. Zeus config moved from per-skill homes
# (~/.config/request-review, ~/.config/propose) into ONE unified home
# (~/.config/zeus/<concern>/). This relocates any existing user config into the new
# layout. It's safe to run more than once (idempotent, never clobbers) and safe to
# DELETE once you've run it — nothing in the skills depends on it.
#
# Usage:  bash skills/zeus/migrate-config.sh          # do it
#         DRY_RUN=1 bash skills/zeus/migrate-config.sh # show what it would do
#
# Honors $ZEUS_CONFIG_DIR (new home), and $REQUEST_REVIEW_CONFIG_DIR /
# $PROPOSE_CONFIG_DIR if you had set those (old homes).
set -euo pipefail

CFG_BASE="${XDG_CONFIG_HOME:-$HOME/.config}"
ZEUS_CONFIG_DIR="${ZEUS_CONFIG_DIR:-$CFG_BASE/zeus}"
RR_OLD="${REQUEST_REVIEW_CONFIG_DIR:-$CFG_BASE/request-review}"
PROP_OLD="${PROPOSE_CONFIG_DIR:-$CFG_BASE/propose}"
DRY_RUN="${DRY_RUN:-0}"

moved=0
move_file() { # move_file <src> <dst>
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  [ "$src" = "$dst" ] && return 0
  if [ -e "$dst" ]; then echo "skip (destination exists): $dst"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then echo "would move: $src -> $dst"; moved=$((moved + 1)); return 0; fi
  mkdir -p "$(dirname "$dst")"
  mv "$src" "$dst" && { echo "moved: $src -> $dst"; moved=$((moved + 1)); }
}

move_file "$RR_OLD/slack-handles.json" "$ZEUS_CONFIG_DIR/request-review/slack-handles.json"
move_file "$RR_OLD/auto-ping.json"     "$ZEUS_CONFIG_DIR/request-review/auto-ping.json"
move_file "$PROP_OLD/confluence.json"  "$ZEUS_CONFIG_DIR/propose/confluence.json"

# Tidy up old homes if they're now empty (best-effort; never fails the run).
if [ "$DRY_RUN" != "1" ]; then
  for d in "$RR_OLD" "$PROP_OLD"; do
    [ -d "$d" ] && rmdir "$d" 2>/dev/null && echo "removed empty: $d" || true
  done
fi

echo "done — $moved file(s) $([ "$DRY_RUN" = "1" ] && echo "would be " )migrated into $ZEUS_CONFIG_DIR"
[ "$moved" -eq 0 ] && echo "(nothing to migrate — you can delete this script)"
exit 0
