#!/usr/bin/env bash
# confluence-target.sh — per-repo Confluence destination for /zeus:propose.
#
# A repo may opt in to publishing its proposals to Confluence (as child pages
# under a parent). This is PERSONAL tooling config: it lives in the user's config
# dir, keyed by `owner/repo`, the same store style as request-review's
# auto-ping.sh — NOT committed in the repo. There is no shipped-defaults layer and
# no merge: every `cloudId`/`spaceKey`/`parentId`/`mode` is identical for everyone
# on a repo, so a single user-owned file with a flat per-repo lookup is enough.
#
#   store: ${ZEUS_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/zeus}/propose/confluence.json
#   shape: { "repos": { "owner/repo": { cloudId, spaceKey, spaceId?, parentId?,
#                                       mode, defaultStatus } } }
#
# A repo ABSENT from the file resolves to {"configured":false} — propose then
# behaves exactly as today (GitHub-only). Confluence publishing is strictly
# opt-in per repo, mirroring auto-ping's "absent ⇒ disabled".
#
# `mode` picks how propose treats the two destinations:
#   mirror (default) — GitHub issue stays canonical (keeps #N, the journey chain,
#                      /zeus:implement); the Confluence page is an additional
#                      published surface, backlinked to the issue.
#   native           — Confluence page only; no GitHub issue. The page id becomes
#                      the proposal's identity.
#
# `spaceId` is optional in config because createConfluencePage needs the numeric
# space id, but humans know the space KEY. Store the key; the post step resolves
# key → id once via getConfluenceSpaces (MCP) and may persist it back with
# `enable … --space-id <id>`.
#
# Usage:
#   confluence-target.sh <owner/repo>            # print the repo's policy (see Output)
#   confluence-target.sh enable <owner/repo> --cloud <id|url> --space <KEY> \
#                        [--space-id <id>] [--parent <pageId>] \
#                        [--mode mirror|native] [--status current|draft]
#   confluence-target.sh disable <owner/repo>    # remove the repo's entry
#   confluence-target.sh list                    # every configured repo
#   confluence-target.sh path                    # print the config file path
#
# Output (policy lookup):
#   configured repo → { "configured": true, "cloudId": str, "spaceKey": str,
#                       "spaceId": str|null, "parentId": str|null,
#                       "mode": "mirror"|"native", "defaultStatus": "current"|"draft" }
#   unconfigured    → { "configured": false }
# Exit: lookups always 0 (the `configured` field drives behaviour); edits 0 on success.

set -euo pipefail

CONFIG_DIR="${ZEUS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zeus}/propose"
STORE="$CONFIG_DIR/confluence.json"

repos() {
  [ -f "$STORE" ] && jq -c '.repos // {}' "$STORE" 2>/dev/null || echo '{}'
}

cmd="${1:?Usage: confluence-target.sh <owner/repo | enable | disable | list | path>}"

case "$cmd" in
  path)
    echo "$STORE"
    ;;

  list)
    repos | jq .
    ;;

  enable)
    repo="${2:?Usage: confluence-target.sh enable <owner/repo> --cloud <id|url> --space <KEY> [--space-id <id>] [--parent <pageId>] [--mode mirror|native] [--status current|draft]}"
    shift 2
    cloud=""; space=""; space_id=""; parent=""; mode="mirror"; status="current"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cloud)    cloud="${2:?}"; shift 2 ;;
        --space)    space="${2:?}"; shift 2 ;;
        --space-id) space_id="${2:?}"; shift 2 ;;
        --parent)   parent="${2:?}"; shift 2 ;;
        --mode)     mode="${2:?}"; shift 2 ;;
        --status)   status="${2:?}"; shift 2 ;;
        *) echo "confluence-target.sh enable: unknown arg $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$cloud" ] || { echo "confluence-target.sh enable: --cloud <id|url> is required" >&2; exit 1; }
    [ -n "$space" ] || { echo "confluence-target.sh enable: --space <KEY> is required" >&2; exit 1; }
    case "$mode"   in mirror|native) ;; *) echo "confluence-target.sh: --mode must be mirror|native" >&2; exit 1 ;; esac
    case "$status" in current|draft) ;; *) echo "confluence-target.sh: --status must be current|draft" >&2; exit 1 ;; esac
    # REPLACE the repo's entry (not merge) so a re-enable drops any stale field
    # (e.g. a spaceId that no longer matches the spaceKey).
    entry=$(jq -nc \
      --arg c "$cloud" --arg s "$space" --arg sid "$space_id" \
      --arg p "$parent" --arg m "$mode" --arg st "$status" '
      { cloudId: $c, spaceKey: $s, mode: $m, defaultStatus: $st }
      + (if $sid != "" then {spaceId: $sid} else {} end)
      + (if $p   != "" then {parentId: $p}  else {} end)')
    mkdir -p "$CONFIG_DIR"
    cur='{"repos":{}}'
    [ -f "$STORE" ] && cur=$(jq -c . "$STORE" 2>/dev/null || echo '{"repos":{}}')
    echo "$cur" | jq --arg r "$repo" --argjson e "$entry" '.repos[$r] = $e' > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
    echo "enabled $repo → $STORE" >&2
    repos | jq --arg r "$repo" '.[$r]'
    ;;

  disable)
    repo="${2:?Usage: confluence-target.sh disable <owner/repo>}"
    [ -f "$STORE" ] || { echo "disabled $repo (no config file)" >&2; exit 0; }
    cur=$(jq -c . "$STORE" 2>/dev/null || echo '{"repos":{}}')
    echo "$cur" | jq --arg r "$repo" 'del(.repos[$r])' > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
    echo "disabled $repo → $STORE" >&2
    ;;

  *)
    # Policy lookup: the positional <owner/repo> form every caller uses.
    repo="$cmd"
    repos | jq -c --arg r "$repo" '
      (.[$r] // null) as $c
      | if $c == null then { configured: false }
        else { configured:     true,
               cloudId:        ($c.cloudId // null),
               spaceKey:       ($c.spaceKey // null),
               spaceId:        ($c.spaceId // null),
               parentId:       ($c.parentId // null),
               mode:           ($c.mode // "mirror"),
               defaultStatus:  ($c.defaultStatus // "current") }
        end
    '
    ;;
esac
