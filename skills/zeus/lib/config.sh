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

ZEUS_CONFIG_DIR="${ZEUS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zeus}"
ZEUS_DEFAULTS_FILE="${ZEUS_DEFAULTS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.defaults.json}"

_zeus_repo_config() {
  local gd; gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s\n' "$gd/zeus/config.json"
}
_zeus_user_config() { printf '%s\n' "$ZEUS_CONFIG_DIR/config.json"; }

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
