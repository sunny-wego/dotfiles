#!/usr/bin/env bash
# auto-ping.sh — per-repo reviewer-ping policy: read it, or edit it in place.
#
# Config has two layers so user policy survives skill updates (config and code
# must not share a lifecycle):
#   defaults — <skill-dir>/auto-ping.json          (ships with the skill; template)
#   override — $CONFIG_DIR/auto-ping.json          (user-owned; where edits land)
# with CONFIG_DIR = ${ZEUS_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/zeus}/request-review
# (the unified Zeus config home; never committed; `migrate-config.sh` relocates the old path).
# Reads merge override repos over defaults (override wins per repo); all writes
# go to the override file only — the in-skill file is never mutated.
#
# Repos absent from both layers default to disabled, so auto-pinging Slack when
# a PR settles is strictly opt-in per repo; everywhere else, pinging stays
# manual (only when the user asks).
#
# Usage:
#   auto-ping.sh <owner/repo>          # print the repo's policy (see Output)
#   auto-ping.sh enable <owner/repo> --channel <C…> [--mode send|draft|ask] [--re-review]   # upsert into override
#   auto-ping.sh disable <owner/repo>  # set enabled=false in the override
#   auto-ping.sh list                  # merged policy for every configured repo
#   auto-ping.sh path                  # print the override file path
#
# Recipients: enabling a repo pings its CODEOWNERS — resolved per changed path at
# ping time (see resolve-reviewers.sh). There is no single primary reviewer; the
# only two states are "ping the code owners" (enabled) and "ping no-one"
# (disabled). To stop pinging a repo, `disable` it.
#
# Output (policy lookup):
#   { "enabled": bool, "mode": "send"|"draft"|"ask", "channel": string|null,
#     "re_review": bool }
#   channel null ⇒ the caller must supply $SLACK_REVIEW_CHANNEL (no baked-in
#   default channel — a published skill must not silently route to one).
#   re_review true ⇒ on a new head SHA, re-ping the PR's code owners in-thread
#   (see re-review-message.sh).
# Exit: lookups always 0 (the enabled field drives behavior); edits 0 on success.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULTS="$SCRIPT_DIR/../auto-ping.json"
# One config home for the family — lib/config.sh sets ZEUS_CONFIG_DIR (env override >
# default ~/.config/zeus). Sourcing only sets vars, so it's safe outside a repo.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/config.sh"
CONFIG_DIR="$ZEUS_CONFIG_DIR/request-review"
OVERRIDE="$CONFIG_DIR/auto-ping.json"

merged_repos() {
  local d='{}' o='{}'
  [ -f "$DEFAULTS" ] && d=$(jq -c '.repos // {}' "$DEFAULTS" 2>/dev/null || echo '{}')
  [ -f "$OVERRIDE" ] && o=$(jq -c '.repos // {}' "$OVERRIDE" 2>/dev/null || echo '{}')
  jq -nc --argjson d "$d" --argjson o "$o" '$d + $o'
}

write_repo() {  # write_repo <owner/repo> <entry-json>
  mkdir -p "$CONFIG_DIR"
  local cur='{"repos":{}}'
  [ -f "$OVERRIDE" ] && cur=$(jq -c . "$OVERRIDE" 2>/dev/null || echo '{"repos":{}}')
  local tmp="$OVERRIDE.tmp"
  echo "$cur" | jq --arg r "$1" --argjson e "$2" '.repos = ((.repos // {}) + {($r): (((.repos // {})[$r] // {}) + $e)})' > "$tmp"
  mv "$tmp" "$OVERRIDE"
}

cmd="${1:?Usage: auto-ping.sh <owner/repo | enable | disable | list | path>}"

case "$cmd" in
  path)
    echo "$OVERRIDE"
    ;;

  list)
    merged_repos | jq .
    ;;

  enable)
    repo="${2:?Usage: auto-ping.sh enable <owner/repo> --channel <C…> [--mode send|draft|ask] [--re-review]}"
    shift 2
    channel=""; mode="send"; re_review=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --channel)   channel="${2:?}"; shift 2 ;;
        --mode)      mode="${2:?}"; shift 2 ;;
        --re-review) re_review=true; shift ;;
        *) echo "auto-ping.sh enable: unknown arg $1" >&2; exit 1 ;;
      esac
    done
    case "$mode" in send|draft|ask) ;; *) echo "auto-ping.sh: mode must be send|draft|ask" >&2; exit 1 ;; esac
    if [ -z "$channel" ]; then
      echo "auto-ping.sh enable: --channel <C…> is required" >&2; exit 1
    fi
    if [[ ! "$channel" =~ ^[CG][A-Z0-9]{6,}$ ]]; then
      echo "auto-ping.sh enable: channel must be a Slack channel ID (C…), not a #name — the send MCP wants an ID" >&2; exit 1
    fi
    # Enabling = ping the repo's CODEOWNERS. REPLACE the repo's entry (not merge)
    # so any legacy reviewer/with_reviewers fields are dropped on re-enable.
    entry=$(jq -nc --arg c "$channel" --arg m "$mode" --argjson rr "$re_review" \
      '{enabled:true, mode:$m, channel:$c, re_review:$rr}')
    mkdir -p "$CONFIG_DIR"
    cur='{"repos":{}}'
    [ -f "$OVERRIDE" ] && cur=$(jq -c . "$OVERRIDE" 2>/dev/null || echo '{"repos":{}}')
    echo "$cur" | jq --arg r "$repo" --argjson e "$entry" '.repos[$r] = $e' > "$OVERRIDE.tmp" && mv "$OVERRIDE.tmp" "$OVERRIDE"
    echo "enabled $repo → $OVERRIDE" >&2
    merged_repos | jq --arg r "$repo" '.[$r]'
    ;;

  disable)
    repo="${2:?Usage: auto-ping.sh disable <owner/repo>}"
    write_repo "$repo" '{"enabled":false}'
    echo "disabled $repo → $OVERRIDE" >&2
    ;;

  *)
    # Policy lookup: the positional <owner/repo> form every caller uses.
    repo="$cmd"
    merged_repos | jq -c --arg r "$repo" '
      (.[$r] // {}) as $c
      | { enabled:   ($c.enabled // false),
          mode:      ($c.mode // "ask"),
          channel:   ($c.channel // null),
          re_review: ($c.re_review // false) }
    '
    ;;
esac
