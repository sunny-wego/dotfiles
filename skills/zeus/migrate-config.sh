#!/usr/bin/env bash
# migrate-config.sh — ONE-TIME migrations. Safe to run more than once (idempotent,
# never clobbers) and safe to DELETE once you've run it — nothing in the skills
# depends on it. Two migrations:
#   1. Per-skill homes (~/.config/request-review, ~/.config/propose) → ONE unified
#      home (~/.config/zeus/<concern>/).
#   2. Confluence destination `mode` values renamed to be destination-explicit:
#      "native" → "confluence", "mirror" → "both". (The code accepts ONLY the new
#      names, so this rewrites any old value in place — no legacy aliasing.)
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

# Migration 2: rename Confluence `mode` values (native→confluence, mirror→both) in
# the unified-home confluence.json. Idempotent — a file already using the new names
# is left byte-identical, so $moved isn't bumped.
CONF="$ZEUS_CONFIG_DIR/propose/confluence.json"
if [ -f "$CONF" ]; then
  if jq -e '(.repos // {}) | to_entries | any(.value.mode == "native" or .value.mode == "mirror")' "$CONF" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "would rename modes in $CONF: native→confluence, mirror→both"; moved=$((moved + 1))
    else
      tmp="$CONF.tmp.$$"
      jq '(.repos // {}) |= with_entries(
            if   .value.mode == "native" then .value.mode = "confluence"
            elif .value.mode == "mirror" then .value.mode = "both"
            else . end)' "$CONF" > "$tmp" && mv "$tmp" "$CONF" \
        && { echo "renamed modes in $CONF (native→confluence, mirror→both)"; moved=$((moved + 1)); }
    fi
  fi
fi

echo "done — $moved item(s) $([ "$DRY_RUN" = "1" ] && echo "would be " )migrated into $ZEUS_CONFIG_DIR"
[ "$moved" -eq 0 ] && echo "(nothing to migrate — you can delete this script)"
exit 0
