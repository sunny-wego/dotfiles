#!/usr/bin/env bash
# drift-check.sh — detect state↔body drift before an amend edits anything.
#
# WHY: the amend pipeline regenerates the WHOLE body from state. If someone edited
# the live body out-of-band (a teammate on github.com, or a past session that
# patched prose without writing state back), the next amend silently clobbers
# their content. A body-only reader test is structurally blind to this — the stale
# render reads fine. This gate is the deterministic half of "confirm you're
# regenerating from current truth": render the rehydrated state, normalize both
# sides, and diff. Divergence ⇒ STOP and reconcile (re-ingest the out-of-band
# edits into state) before applying any delta.
#
# Normalization (cosmetic deltas that must NOT count as drift):
#   - pinned code refs: blob/<sha>/path#Lx-Ly URLs → stable repo-relative token
#     (re-pinning at a new HEAD is expected, not drift)
#   - the `_via `zeus:<skill>`_` origin watermark (post-time signature; the live
#     body carries it, a fresh render(state) need not — so it's always footer noise)
#   - telemetry/usage footers and audit guard comments
#   - trailing whitespace / blank-line runs
#
# Usage: drift-check.sh <issue-number> <state-file> [--repo <owner/repo>]
# Exit:  0 in sync; 1 drift detected (normalized unified diff on stderr);
#        2 usage / fetch error.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
num="${1:?Usage: drift-check.sh <issue-number> <state-file> [--repo owner/repo]}"
state="${2:?state-file required}"; shift 2
repo=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "drift-check.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -f "$state" ] || { echo "drift-check.sh: state file not found: $state" >&2; exit 2; }

base="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; base="${base:-/tmp}"; mkdir -p "$base" 2>/dev/null || true

live="$base/drift-$num-live.md"
view=(issue view "$num" --json body -q .body); [ -n "$repo" ] && view+=(--repo "$repo")
gh "${view[@]}" > "$live" 2>/dev/null || { echo "drift-check.sh: could not read issue #$num" >&2; exit 2; }

rendered=$(bash "$script_dir/render.sh" "$state" --out "$base/drift-$num-render.md" ${repo:+--repo "$repo"})

normalize() {
  # `|` delimiter: the pattern contains both `/` and `#` (the #L anchor).
  sed -E \
    -e 's|https://github\.com/[^/]+/[^/]+/blob/[0-9a-f]{7,40}/([^#) ]+)(#L[0-9L-]+)?|REF:\1|g' \
    -e '/^_via `zeus:[^`]*`_$/d' \
    -e 's/[[:space:]]+$//' \
    "$1" \
  | sed -E '/Claude Code session usage/,$d' \
  | grep -vE '^<!-- (claude-(usage|telemetry)|audit:mention-once)' \
  | awk 'BEGIN{blank=0} /^$/{blank++; if(blank>1) next} !/^$/{blank=0} {print}' \
  | awk '{lines[NR]=$0} END{n=NR; while(n>0 && (lines[n]=="" || lines[n]=="---")) n--; for(i=1;i<=n;i++) print lines[i]}'
}

normalize "$live" > "$base/drift-$num-live.norm"
normalize "$rendered" > "$base/drift-$num-render.norm"

if diff -u "$base/drift-$num-live.norm" "$base/drift-$num-render.norm" > "$base/drift-$num.diff" 2>/dev/null; then
  echo "drift-check: in sync (state regenerates the live body)"
  exit 0
fi

lines=$(wc -l < "$base/drift-$num.diff" | tr -d ' ')
echo "drift-check: DRIFT between persisted state and live body of #$num ($lines diff lines)." >&2
echo "  Someone edited prose out-of-band, or state was never written back." >&2
echo "  STOP: reconcile (re-ingest the live edits into state) before amending," >&2
echo "  or the re-render will clobber them. Diff (live → render):" >&2
cat "$base/drift-$num.diff" >&2
exit 1
