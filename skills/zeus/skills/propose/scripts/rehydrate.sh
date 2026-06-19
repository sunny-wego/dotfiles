#!/usr/bin/env bash
# rehydrate.sh — get the state JSON for an existing issue so an amend edits STATE
# (the source of truth), not the live prose.
#
# Prefers the persisted state (state.sh); falls back to re-ingesting the live issue
# body via extract-sections.sh. The fallback is best-effort and LOSSY — the live
# body is rendered output, not the original state, so some structure (options,
# code_grounding) may not round-trip; the agent should sanity-check after.
#
# Usage: rehydrate.sh <issue-number> [--repo <owner/repo>]
# Prints the path to a state file on stdout (status notes go to stderr).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
num="${1:?Usage: rehydrate.sh <issue-number> [--repo owner/repo]}"; shift || true
repo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "rehydrate.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done

base="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; base="${base:-/tmp}"; mkdir -p "$base" 2>/dev/null || true
out="$base/issue-$num.state.json"

saved="$(bash "$script_dir/state.sh" load "$num" 2>/dev/null || echo "")"
if [ -n "$saved" ]; then
  printf '%s' "$saved" > "$out"
  echo "rehydrate: loaded persisted state for #$num" >&2
else
  # Fallback: pull the live body and extract what we can.
  body="$base/issue-$num.body.md"
  view=(issue view "$num" --json body -q .body); [ -n "$repo" ] && view+=(--repo "$repo")
  if gh "${view[@]}" > "$body" 2>/dev/null && [ -s "$body" ]; then
    bash "$script_dir/extract-sections.sh" "$body" > "$out" 2>/dev/null || echo '{}' > "$out"
    echo "rehydrate: no saved state for #$num — re-ingested live body (LOSSY; verify)" >&2
  else
    echo '{}' > "$out"
    echo "rehydrate: no saved state and could not read #$num — empty state" >&2
  fi
fi

# Clear the reader-test stamp (boolean AND hash): an amend invalidates a prior
# reader test, so the next post must re-run step 4b (post-issue enforces this
# whenever requires-review.sh says so — and the hash gate re-fires on every
# subsequent state edit too). Also drop the retired `depth` key from older
# stored states; review gating is derived from content now.
jq 'del(.depth) | .reader_test = false | .reader_test_hash = ""' "$out" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || true

# Drift reminder: when persisted state was loaded, the live body may carry
# out-of-band edits the state never saw. The amend flow MUST run drift-check.sh
# before applying any delta (SKILL.md → Updating an existing issue, step 2).
if [ -n "$saved" ]; then
  echo "rehydrate: run drift-check.sh $num $out before editing — out-of-band body edits would be clobbered by a re-render" >&2
fi
echo "$out"
