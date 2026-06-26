#!/usr/bin/env bash
# resolve-target.sh — infer WHICH issue a number-less amend refers to.
#
# WHY: "amend the RFC" / "fold this into the schema issue" carries no #N. Updating
# the wrong issue overwrites a teammate-visible body, so inference must rank from
# strong signals and NEVER act alone — the agent confirms the target with the user
# before any update (the drift gate can't catch a wrong-target amend: it compares
# an issue's state to that same issue's body, which is consistent even when the
# issue is the wrong one).
#
# Ranking (strongest first):
#   1. The skill's own per-repo state store (state.sh list), newest-touched first —
#      "the RFC" almost always means the one this skill last worked on here.
#      A phrase filters stored titles (case-insensitive, all words must match).
#   2. gh issue list --search fallback for issues authored outside the skill
#      (these carry has_state:false → the amend would be a LOSSY re-ingest;
#      surface that in the confirmation).
#
# Confidence:
#   high      — exactly one state-store candidate after filtering
#   ambiguous — multiple candidates (agent MUST AskUserQuestion with the list)
#   none      — nothing matched (agent asks for the number)
#
# NOTE: conversation context outranks this script entirely — an issue created or
# amended in the current session IS the target; don't run this when you have it.
#
# Usage: resolve-target.sh ["<user phrase>"] [--repo <owner/name>] [--limit N]
# Output: {"candidates":[{provider,ref,number,title,source,has_state,updated_at}],"confidence":"..."}
#   provider/ref identify the destination (parity): "github"/"<n>" or
#   "confluence"/"confluence:<id>". The agent amends via the matching path.
#   The state store surfaces BOTH destinations; the gh-search fallback is GitHub-only
#   (a Confluence CQL fallback for pages authored outside the skill is a follow-up).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
phrase=""; repo=""; limit=5
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    *) phrase="$1"; shift ;;
  esac
done

# Words ≥3 chars from the phrase; an issue title must contain ALL of them (case-
# insensitive) to match. Short/stop words ("the", "an") carry no signal.
words=$(printf '%s' "$phrase" | tr -cs '[:alnum:]' '\n' | awk 'length($0) >= 3 {print tolower($0)}')

title_matches() { # $1 = title; returns 0 when every word appears
  local lt; lt=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  local w
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    case "$lt" in (*"$w"*) ;; (*) return 1 ;; esac
  done <<< "$words"
  return 0
}

# ── 1. State store (this repo, newest first) ─────────────────────────
candidates="[]"
store=$(bash "$script_dir/state.sh" list 2>/dev/null || echo "[]")
count=$(printf '%s' "$store" | jq 'length')
i=0
while [ "$i" -lt "$count" ]; do
  row=$(printf '%s' "$store" | jq -c ".[$i]")
  title=$(printf '%s' "$row" | jq -r '.title')
  if [ -z "$words" ] || title_matches "$title"; then
    candidates=$(printf '%s' "$candidates" | jq --argjson r "$row" \
      '. + [$r + {source: "state", has_state: true}]')
  fi
  i=$((i + 1))
done

# ── 2. gh search fallback (only when the store gave nothing) ─────────
if [ "$(printf '%s' "$candidates" | jq 'length')" -eq 0 ] && [ -n "$phrase" ]; then
  search=(issue list --search "$phrase" --state open --json number,title,updatedAt --limit "$limit")
  [ -n "$repo" ] && search+=(--repo "$repo")
  gh_rows=$(gh "${search[@]}" 2>/dev/null || echo "[]")
  candidates=$(printf '%s' "$gh_rows" | jq '[.[] | {provider: "github", ref: (.number|tostring),
    number, title, source: "gh", has_state: false, updated_at: .updatedAt}]')
fi

n=$(printf '%s' "$candidates" | jq 'length')
if [ "$n" -eq 1 ]; then conf="high"
elif [ "$n" -eq 0 ]; then conf="none"
else conf="ambiguous"; candidates=$(printf '%s' "$candidates" | jq ".[0:$limit]")
fi

jq -nc --argjson c "$candidates" --arg conf "$conf" '{candidates: $c, confidence: $conf}'
