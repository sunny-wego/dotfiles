#!/usr/bin/env bash
# telemetry.sh — append (or refresh) a Claude Code token-usage + cost footer on
# a PR or issue body. Best-effort: any failure exits 0 so it never blocks the
# create/post path.
#
# VENDORED IDENTICALLY across create-pr and propose (same doctrine as
# journey.sh) so both ends of the journey share one footer format, one marker
# pair, and one implementation — a fix in one copy is a byte-copy to the other.
# The target kind is a flag, not a fork.
#
# Tokens + cost come from the current Claude Code session. Cost is sourced from
# `ccusage` (authoritative, handles per-model + cache pricing); if ccusage is
# unavailable we fall back to summing token counts straight from the session
# transcript JSONL (token-only, no dollar figure).
#
# The footer lives between its own HTML-comment markers so re-runs replace it
# in place rather than stacking duplicates.
#
# Usage:
#   telemetry.sh --pr <number|url>    [--repo <owner/name>] [--session <id>]
#   telemetry.sh --issue <number|url> [--repo <owner/name>] [--session <id>]
#   telemetry.sh --dry-run [--session <id>]    # print footer, edit nothing
#
# Opt out: CLAUDE_PR_TELEMETRY=0 (or =false) disables both kinds (the shared
# switch); CLAUDE_ISSUE_TELEMETRY=0 additionally disables just --issue.

set -uo pipefail   # NOTE: no -e; this script must never abort its caller.

T_START='<!-- claude-telemetry:start -->'
T_END='<!-- claude-telemetry:end -->'

kind=""
target=""
repo=""
session="${CLAUDE_CODE_SESSION_ID:-}"
dry_run=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) kind="pr"; target="$2"; shift 2 ;;
    --issue) kind="issue"; target="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "telemetry: ignoring unknown flag: $1" >&2; shift ;;
  esac
done

# Respect the opt-out switches (the shared one, then the issue-specific one).
case "${CLAUDE_PR_TELEMETRY:-}" in
  0|false|FALSE|no|NO) exit 0 ;;
esac
if [ "$kind" = "issue" ]; then
  case "${CLAUDE_ISSUE_TELEMETRY:-}" in
    0|false|FALSE|no|NO) exit 0 ;;
  esac
fi

# Without a session id we can't attribute usage — silently skip (e.g. plain
# `gh` usage outside Claude Code).
[ -n "$session" ] || exit 0

humanize() {
  awk -v n="${1:-0}" 'BEGIN{
    if (n+0 >= 1000000) printf "%.2fM", n/1000000;
    else if (n+0 >= 1000) printf "%.1fK", n/1000;
    else printf "%d", n;
  }'
}

total_tokens=""
input=""; output=""; cache_w=""; cache_r=""
cost=""
models=""

# --- Preferred source: ccusage (gives cost) ----------------------------------
# Pinned version (no @latest) to avoid silent supply-chain drift. Prefer bunx
# for speed when present; otherwise npx -y (bundled with Node, far more common).
CCUSAGE_PKG="ccusage@20.0.6"
run_ccusage() {
  if command -v bunx >/dev/null 2>&1; then
    bunx "$CCUSAGE_PKG" session --json 2>/dev/null
  elif command -v npx >/dev/null 2>&1; then
    npx -y "$CCUSAGE_PKG" session --json 2>/dev/null
  fi
}
ccusage_json="$(run_ccusage || true)"
if [ -n "$ccusage_json" ]; then
  entry="$(printf '%s' "$ccusage_json" \
    | jq -c --arg sid "$session" '.session[] | select(.period==$sid)' 2>/dev/null || true)"
  if [ -n "$entry" ] && [ "$entry" != "null" ]; then
    total_tokens="$(printf '%s' "$entry" | jq -r '.totalTokens // empty')"
    input="$(printf '%s' "$entry" | jq -r '.inputTokens // 0')"
    output="$(printf '%s' "$entry" | jq -r '.outputTokens // 0')"
    cache_w="$(printf '%s' "$entry" | jq -r '.cacheCreationTokens // 0')"
    cache_r="$(printf '%s' "$entry" | jq -r '.cacheReadTokens // 0')"
    cost="$(printf '%s' "$entry" | jq -r '.totalCost // empty')"
    models="$(printf '%s' "$entry" | jq -r '(.modelsUsed // []) | join(", ")')"
  fi
fi

# --- Fallback: sum tokens from the transcript (no cost) -----------------------
if [ -z "$total_tokens" ]; then
  config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  transcript=""
  while IFS= read -r f; do
    case "$(basename "$f")" in "$session".jsonl) transcript="$f"; break ;; esac
  done < <(find "$config_dir/projects" -name "$session.jsonl" 2>/dev/null)
  [ -n "$transcript" ] || exit 0
  read -r input output cache_w cache_r < <(
    jq -rs '[.[] | select(.type=="assistant") | .message.usage] as $u
      | "\($u|map(.input_tokens // 0)|add) \($u|map(.output_tokens // 0)|add) \($u|map(.cache_creation_input_tokens // 0)|add) \($u|map(.cache_read_input_tokens // 0)|add)"' \
      "$transcript" 2>/dev/null || echo "0 0 0 0"
  )
  total_tokens=$(( input + output + cache_w + cache_r ))
fi

[ -n "$total_tokens" ] && [ "$total_tokens" != "0" ] || exit 0

# --- Compose the footer -------------------------------------------------------
cost_str=""
if [ -n "$cost" ]; then
  cost_str=" · est. **\$$(printf '%.2f' "$cost")**"
fi
models_str=""
[ -n "$models" ] && models_str=" · models: $models"

line="🤖 **Claude Code session usage** — $(humanize "$total_tokens") tokens ($(humanize "$input") in · $(humanize "$output") out · $(humanize "$cache_w") cache-write · $(humanize "$cache_r") cache-read)${cost_str}${models_str} · <code>session ${session%%-*}</code>"

footer="$(printf '%s\n---\n<sub>%s</sub>\n%s\n' "$T_START" "$line" "$T_END")"

if [ "$dry_run" = "true" ]; then
  printf '%s\n' "$footer"
  exit 0
fi

[ -n "$kind" ] && [ -n "$target" ] || exit 0

# --- Edit the target body: strip any prior block, append the fresh one --------
gh_args=("$kind" view "$target" --json body --jq .body)
[ -n "$repo" ] && gh_args+=(--repo "$repo")
body="$(gh "${gh_args[@]}" 2>/dev/null || true)"
[ -n "$body" ] || exit 0

# Remove an existing telemetry block (markers inclusive) for idempotency.
cleaned="$(printf '%s' "$body" | awk -v s="$T_START" -v e="$T_END" '
  $0==s {skip=1}
  skip==0 {print}
  $0==e {skip=0}
')"

tmp="$(mktemp "${TMPDIR:-/tmp}/telemetry.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
  printf '%s\n\n' "${cleaned%$'\n'}"
  printf '%s\n' "$footer"
} > "$tmp"

edit_args=("$kind" edit "$target" --body-file "$tmp")
[ -n "$repo" ] && edit_args+=(--repo "$repo")
gh "${edit_args[@]}" >/dev/null 2>&1 || true
