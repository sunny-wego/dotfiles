#!/usr/bin/env bash
# render.sh — state JSON → post-ready draft body, in one deterministic call.
#
# Wraps the two render steps that always run in sequence (scaffold-draft → pin-refs)
# so callers never run them out of order or forget to pin code references. Used by
# both create (compose) and amend (re-render from state).
#
# Usage: render.sh <state-file> [--sha <sha>] [--repo <owner/repo>] [--out <path>]
#   --sha / --repo : forwarded to pin-refs. Derived from issue-context.sh when omitted
#                    (pass them in the create flow — you already have them — to avoid a
#                    second `gh` round-trip).
#   --out          : draft path. Defaults to ${CLAUDE_JOB_DIR}/tmp (or /tmp)/issue-draft-<pid>.md
#
# Prints ONLY the draft path on stdout (scaffold output goes to the file; pin-refs
# chatter goes to stderr), so callers can `DRAFT=$(render.sh ...)`.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
state="${1:?Usage: render.sh <state-file> [--sha S] [--repo R] [--out path]}"; shift || true
sha=""; repo=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha)  sha="$2";  shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --out)  out="$2";  shift 2 ;;
    *) echo "render.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -f "$state" ] || { echo "render.sh: state file not found: $state" >&2; exit 1; }

# Derive sha/repo once if not supplied — pin-refs needs both, else it's skipped.
if [ -z "$sha" ] || [ -z "$repo" ]; then
  ctx="$(bash "$script_dir/issue-context.sh" 2>/dev/null || echo '{}')"
  [ -z "$sha" ]  && sha="$(printf '%s'  "$ctx" | jq -r '.head_sha // empty' 2>/dev/null || true)"
  [ -z "$repo" ] && repo="$(printf '%s' "$ctx" | jq -r '.repo // empty'     2>/dev/null || true)"
fi

if [ -z "$out" ]; then
  base="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; base="${base:-/tmp}"
  mkdir -p "$base" 2>/dev/null || true
  out="$base/issue-draft-$$.md"
fi

bash "$script_dir/scaffold-draft.sh" "$state" > "$out"
# Pin only with both sha+repo; otherwise leave refs verbatim (best-effort, matches
# prior behaviour when context is unavailable). pin-refs chatter → stderr.
if [ -n "$sha" ] && [ -n "$repo" ]; then
  bash "$script_dir/pin-refs.sh" "$out" "$sha" "$repo" >&2 || true
fi
echo "$out"
