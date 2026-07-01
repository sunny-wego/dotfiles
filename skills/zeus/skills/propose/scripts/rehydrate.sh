#!/usr/bin/env bash
# rehydrate.sh — get the state JSON for an existing proposal so an amend edits STATE
# (the source of truth), not the live prose. Works for both destinations (parity).
#
# Prefers the persisted state (state.sh load <ref>); falls back to re-ingesting the
# live artifact body via extract-sections.sh. The fallback is best-effort and LOSSY
# — the live body is rendered output, not the original state, so some structure
# (options, code_grounding) may not round-trip; the agent should sanity-check after.
#
# REF (see state.sh): a bare <number> is a GitHub issue; confluence:<pageId> is a
# Confluence page. The fallback body source differs by destination:
#   GitHub     — fetched here via `gh issue view` (scriptable).
#   Confluence — the agent fetches it (getConfluencePage, markdown) and passes
#                --body-file <path>; bash can't call the Atlassian MCP.
#
# Usage: rehydrate.sh <ref> [--repo <owner/repo>] [--body-file <path>]
# Prints the path to a state file on stdout (status notes go to stderr).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
ref="${1:?Usage: rehydrate.sh <ref> [--repo owner/repo] [--body-file path]}"; shift || true
repo=""; body_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      repo="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    *) echo "rehydrate.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Destination + a filesystem-safe slug for tmp file names (confluence:<id> → the id).
case "$ref" in
  confluence:*) provider="confluence"; slug="${ref#confluence:}" ;;
  *)            provider="github";     slug="$ref" ;;
esac

base="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; base="${base:-/tmp}"; mkdir -p "$base" 2>/dev/null || true
out="$base/proposal-$slug.state.json"

saved="$(bash "$script_dir/state.sh" load "$ref" 2>/dev/null || echo "")"
if [ -n "$saved" ]; then
  printf '%s' "$saved" > "$out"
  echo "rehydrate: loaded persisted state for $ref" >&2
else
  # Fallback: re-ingest the live body. Source depends on destination.
  body="$base/proposal-$slug.body.md"
  got=""
  if [ -n "$body_file" ] && [ -f "$body_file" ]; then
    cp "$body_file" "$body"; got=1                       # Confluence (or any pre-fetched body)
  elif [ "$provider" = "github" ]; then
    view=(issue view "$ref" --json body -q .body); [ -n "$repo" ] && view+=(--repo "$repo")
    gh "${view[@]}" > "$body" 2>/dev/null && [ -s "$body" ] && got=1
  fi
  if [ -n "$got" ]; then
    bash "$script_dir/extract-sections.sh" "$body" > "$out" 2>/dev/null || echo '{}' > "$out"
    echo "rehydrate: no saved state for $ref — re-ingested live body (LOSSY; verify)" >&2
    [ "$provider" = "confluence" ] && echo "rehydrate: set .confluence_page_id and .confluence_version from the fetched page before amending" >&2
  else
    echo '{}' > "$out"
    if [ "$provider" = "confluence" ]; then
      echo "rehydrate: no saved state for $ref and no --body-file — pass the fetched page body, or start fresh" >&2
    else
      echo "rehydrate: no saved state and could not read $ref — empty state" >&2
    fi
  fi
fi

# Clear both gate stamps (boolean AND hash): an amend invalidates a prior reader
# test AND a prior build-ready test, so the next post must re-run step 4b (post
# enforces this whenever requires-review.sh says so — and the hash gates re-fire on
# every subsequent state edit too). build_ready_consent resets too: consent to post
# an incomplete contract can't carry across an amend. Also drop the retired `depth`
# key from older stored states; review gating is derived from content now.
# confluence_page_id / confluence_version are preserved — they identify the page to
# UPDATE and gate its drift.
jq 'del(.depth) | .reader_test = false | .reader_test_hash = "" | .build_ready = "" | .build_ready_hash = "" | .build_ready_gaps = [] | .build_ready_consent = false' "$out" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out" || true

# Drift reminder: when persisted state was loaded, the live artifact may carry
# out-of-band edits the state never saw. The amend flow MUST run the destination's
# drift gate before applying any delta (SKILL.md → Updating an existing proposal).
if [ -n "$saved" ]; then
  if [ "$provider" = "confluence" ]; then
    echo "rehydrate: run confluence-drift.sh (stored .confluence_version vs live page version) before editing — out-of-band page edits would be clobbered by a re-render" >&2
  else
    echo "rehydrate: run drift-check.sh $ref $out before editing — out-of-band body edits would be clobbered by a re-render" >&2
  fi
fi
echo "$out"
