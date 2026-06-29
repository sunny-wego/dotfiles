#!/usr/bin/env bash
# config.sh — the family's unified configuration. SOURCE this (don't execute).
# One config home for every skill, NOTHING of the user's committed to the repo.
#
# A value is resolved by MERGE, highest precedence first:
#   1. env  ZEUS_<UPPER_DOTTED_KEY>      (e.g. ZEUS_REVIEW_LOC_THRESHOLD) — one-offs
#   2. repo  .git/zeus/config.json        (per-repo, per-worktree; NOT committed)
#   3. user  $ZEUS_CONFIG_DIR/config.json (default ~/.config/zeus/config.json)
#   4. shipped defaults  lib/config.defaults.json (the ONLY config in the repo)
#
# Keys are dotted (review.loc_threshold, address.max_iterations, …). Values are
# scalars or JSON. Larger per-concern blobs (Slack handles, ping policy, Confluence
# settings) live as their own files under $ZEUS_CONFIG_DIR/<concern>/ — same home,
# not committed — and are read by their owning scripts, not through config_get.
#
# API:  config_get <dotted.key> [default]
#       config_set [--scope user|repo] <dotted.key> <value>
#       config_path [user|repo|defaults]
#       config_dir                      # the ZEUS_CONFIG_DIR root

ZEUS_CONFIG_DIR="${ZEUS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zeus}"
ZEUS_DEFAULTS_FILE="${ZEUS_DEFAULTS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.defaults.json}"

config_dir() { printf '%s\n' "$ZEUS_CONFIG_DIR"; }

_zeus_repo_config() {
  local gd; gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s\n' "$gd/zeus/config.json"
}
_zeus_user_config() { printf '%s\n' "$ZEUS_CONFIG_DIR/config.json"; }

config_path() {
  case "${1:-user}" in
    repo)     _zeus_repo_config ;;
    defaults) printf '%s\n' "$ZEUS_DEFAULTS_FILE" ;;
    *)        _zeus_user_config ;;
  esac
}

# config_get <dotted.key> [default]
config_get() {
  local key="$1" def="${2:-}" envk val f
  envk="ZEUS_$(printf '%s' "$key" | tr '[:lower:].' '[:upper:]_')"
  if [ -n "${!envk:-}" ]; then printf '%s\n' "${!envk}"; return 0; fi
  for f in "$(_zeus_repo_config 2>/dev/null)" "$(_zeus_user_config)" "$ZEUS_DEFAULTS_FILE"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    # Treat ONLY a missing/null path as absent — NOT `// empty`, which jq also fires
    # on a literal `false`, making an explicitly-disabled boolean read back as the
    # default. `0` and `false` are valid values and must survive.
    val="$(jq -r --arg k "$key" 'getpath($k|split(".")) as $v | if $v==null then empty else $v end' "$f" 2>/dev/null || true)"
    [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  done
  printf '%s\n' "$def"
}

# config_set [--scope user|repo] <dotted.key> <value>  (default scope: user)
config_set() {
  local scope="user"
  if [ "${1:-}" = "--scope" ]; then scope="$2"; shift 2; fi
  local key="$1" value="$2" f tmp
  case "$scope" in
    repo) f="$(_zeus_repo_config)" || { echo "config_set: not in a git worktree (repo scope)" >&2; return 1; } ;;
    *)    f="$(_zeus_user_config)" ;;
  esac
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}\n' > "$f"
  tmp="$f.tmp.$$"
  # store raw JSON when the value parses as JSON, else as a string
  jq --arg k "$key" --arg v "$value" \
     'setpath($k|split("."); ($v|fromjson? // $v))' "$f" > "$tmp" && mv "$tmp" "$f"
}
