#!/usr/bin/env bash
# handles.sh — manage the GitHub-login → Slack-ID map. Two layers, so the
# shipped company-wide mappings and the user's own additions have separate
# lifecycles (a skill update must never clobber user edits):
#
#   defaults — <skill-dir>/slack-handles.default.json   (ships with the skill)
#   override — $CONFIG_DIR/slack-handles.json           (user-owned; edits land here)
#
# with CONFIG_DIR = ${REQUEST_REVIEW_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/request-review}.
# Reads (get/list/missing-from-codeowners) see the MERGED map, override wins;
# set/remove/init mutate only the override file.
#
# Commands:
#   handles.sh path              — print the override file path (where edits go)
#   handles.sh init              — create an empty override {} if missing
#   handles.sh get <gh-login>    — print Slack ID or empty (merged view)
#   handles.sh set <gh-login> <slack-id>
#                                — upsert into the override; validates the ID shape
#   handles.sh remove <gh-login> — drop from the override (a default entry can be
#                                  masked by setting it to a new value, not removed)
#   handles.sh list              — print the merged JSON
#   handles.sh missing-from-codeowners [<codeowners-path>]
#                                — GH logins in CODEOWNERS not yet mapped
#   handles.sh bootstrap-template [<codeowners-path>]
#                                — JSON template pre-keyed by every
#                                  CODEOWNERS login (empty values)
#
# Independence: resolve-reviewers.sh tolerates a missing or empty map
# and degrades to GitHub-link mentions, so the map is enrichment-only.

set -euo pipefail

default_path() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && echo "$(pwd)/slack-handles.default.json"
}

CONFIG_DIR="${REQUEST_REVIEW_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/request-review}"
override_path() { echo "$CONFIG_DIR/slack-handles.json"; }

# Merged view: defaults overlaid by the user override (override wins).
merged_map() {
  local d='{}' o='{}' dp op
  dp=$(default_path); op=$(override_path)
  [ -f "$dp" ] && d=$(jq -c . "$dp" 2>/dev/null || echo '{}')
  [ -f "$op" ] && o=$(jq -c . "$op" 2>/dev/null || echo '{}')
  jq -nc --argjson d "$d" --argjson o "$o" '$d + $o'
}

ensure_override() {
  local f
  f=$(override_path)
  mkdir -p "$CONFIG_DIR"
  [ -f "$f" ] || echo "{}" > "$f"
  echo "$f"
}

validate_id() {
  local id="$1"
  if [[ ! "$id" =~ ^[UWST][A-Z0-9]{7,19}$ ]]; then
    echo "handles.sh: invalid Slack ID '$id' (expected U…/W…/S…/T… + 7-19 alphanumerics)" >&2
    return 1
  fi
}

codeowners_path() {
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -z "$root" ] && { echo ""; return; }
  for p in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    [ -f "$root/$p" ] && { echo "$root/$p"; return; }
  done
  echo ""
}

extract_codeowners_logins() {
  local f="$1"
  awk '
    {
      sub(/[[:space:]]*#.*$/, "")
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^\[/) next
      for (i = 2; i <= NF; i++) {
        if (substr($i, 1, 1) == "@") {
          gh = substr($i, 2)
          if (gh != "") print gh
        }
      }
    }
  ' "$f" | sort -u
}

cmd="${1:?Usage: handles.sh <path|init|get|set|remove|list|missing-from-codeowners|bootstrap-template> ...}"
shift || true

case "$cmd" in
  path)
    override_path
    ;;

  init)
    ensure_override
    ;;

  get)
    login="${1:?Usage: handles.sh get <gh-login>}"
    merged_map | jq -r --arg k "$login" '.[$k] // empty'
    ;;

  set)
    login="${1:?Usage: handles.sh set <gh-login> <slack-id>}"
    sid="${2:?slack id required}"
    validate_id "$sid" || exit 1
    f=$(ensure_override)
    tmp="$f.tmp"
    jq --arg k "$login" --arg v "$sid" '. + {($k): $v}' "$f" > "$tmp"
    mv "$tmp" "$f"
    echo "$login → $sid ($f)"
    ;;

  remove)
    login="${1:?Usage: handles.sh remove <gh-login>}"
    f=$(override_path)
    [ -f "$f" ] || exit 0
    tmp="$f.tmp"
    jq --arg k "$login" 'del(.[$k])' "$f" > "$tmp"
    mv "$tmp" "$f"
    ;;

  list)
    merged_map | jq .
    ;;

  missing-from-codeowners)
    co=$(codeowners_path "${1:-}")
    if [ -z "$co" ]; then
      echo "handles.sh: no CODEOWNERS file found (looked in .github/, root, docs/)" >&2
      exit 2
    fi
    mapped=$(merged_map)
    extract_codeowners_logins "$co" \
      | jq -R -s --argjson m "$mapped" '
          split("\n") | map(select(length > 0))
          | map(select(($m[.] // "") == ""))
          | .[]
        ' -r
    ;;

  bootstrap-template)
    co=$(codeowners_path "${1:-}")
    if [ -z "$co" ]; then
      echo "handles.sh: no CODEOWNERS file found" >&2
      exit 2
    fi
    extract_codeowners_logins "$co" \
      | jq -R -s 'split("\n") | map(select(length > 0)) | map({key: ., value: ""}) | from_entries'
    ;;

  *)
    echo "handles.sh: unknown command: $cmd" >&2
    exit 1
    ;;
esac
