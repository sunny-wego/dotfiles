#!/usr/bin/env bash
# audit-draft.sh — consistency lint for a composed issue body.
#
# Complements validate-draft.sh: that gates required SECTIONS; this checks
# internal CONSISTENCY invariants that drift during iterative amends. Generic
# by design — it knows invariant *classes*, never a specific issue's terms:
#
#   - every `Q<n>` cross-reference resolves to a `### Q<n>` heading
#   - `### Q<n>` headings run 1..N with no gaps
#   - declared single-mention terms appear at most once
#   - numbered-anchor refs resolve: prose citing `Invariant <n>` / `writer #<n>` /
#     `shim #<n>` must not exceed the count of items in the matching numbered
#     list/table (renumbering a list orphans prose refs — a real regression class:
#     a fix round renamed Invariant 8 and left a comment citing "Invariant 6")
#   - declared letter-ranges vs actual sections (e.g. "phases (A–G)" vs the
#     `### A`/`### B…` headings that exist) — WARN only (heuristic)
#
# Single-mention terms come from a directive line in the body (an HTML comment,
# invisible on GitHub, and the only place a specific term is named):
#   <!-- audit:mention-once: primaryBookingRef, FooBar -->
# or from --mention-once "a,b".
#
# Q analysis is fence-aware (ignores ``` code blocks) so illustrative `Q1`s in
# snippets don't trip it.
#
# Exit: 0 clean (cosmetic findings warn); 1 on a hard inconsistency
#       (unresolved Q-ref, non-sequential Q headings, single-mention term used >1).
# Usage: audit-draft.sh <draft-path> [--mention-once "t1,t2"]

set -euo pipefail

draft="${1:-}"
[ -n "$draft" ] && shift || true
mention_csv=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mention-once) mention_csv="$2"; shift 2 ;;
    *) echo "audit-draft: unknown flag: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$draft" ] || [ ! -f "$draft" ]; then
  echo "usage: audit-draft.sh <draft-path> [--mention-once \"t1,t2\"]" >&2
  exit 2
fi

fail=0

# --- Q cross-reference resolution + sequencing (fence-aware) ---
qreport=$(awk '
  /^```/        { infence = !infence; next }
  infence       { next }
  /^### Q[0-9]+/ { n=$0; sub(/^### Q/,"",n); sub(/[^0-9].*/,"",n); H[n+0]=1; if(n+0>maxh)maxh=n+0; next }
  {
    s=$0
    while (match(s, /Q[0-9]+/)) {
      r=substr(s, RSTART+1, RLENGTH-1)+0; R[r]=1
      s=substr(s, RSTART+RLENGTH)
    }
  }
  END {
    u=""; for (r in R) if (!(r in H)) u=u" Q"r
    g=""; for (i=1;i<=maxh;i++) if (!(i in H)) g=g" Q"i
    print "unresolved=" u
    print "gaps=" g
  }
' "$draft")
unresolved=$(printf '%s\n' "$qreport" | sed -n 's/^unresolved=//p')
gaps=$(printf '%s\n' "$qreport" | sed -n 's/^gaps=//p')
if [ -n "${unresolved// /}" ]; then
  echo "FAIL: unresolved Q cross-reference(s):$unresolved — no matching '### Q<n>' heading" >&2
  fail=1
fi
if [ -n "${gaps// /}" ]; then
  echo "FAIL: Q headings are not sequential — missing:$gaps" >&2
  fail=1
fi

# --- numbered-anchor resolution (fence-aware) ---
# For each anchor family (Invariant N, writer #N, shim #N): the highest N cited in
# prose must not exceed the highest N that exists as a list item. Existence is
# approximated generically: a line beginning `N.` (ordered list) or `| N |` (table
# row) — the two shapes these families render as. Families with zero citations or
# zero list items are skipped (no signal, no noise).
anchor_report=$(awk '
  /^```/  { infence = !infence; next }
  infence { next }
  # collect max ordered-list item and max table-row index on this draft
  /^[0-9]+\. /          { n=$1+0; if (n>maxlist) maxlist=n }
  /^\| *[0-9]+ *\|/     { s=$0; sub(/^\| */,"",s); n=s+0; if (n>maxrow) maxrow=n }
  {
    s=$0
    while (match(s, /[Ii]nvariant[ -]#?[0-9]+/)) {
      m=substr(s,RSTART,RLENGTH); gsub(/[^0-9]/,"",m); if (m+0>maxinv) maxinv=m+0
      s=substr(s,RSTART+RLENGTH)
    }
    s=$0
    while (match(s, /(writer|shim) #[0-9]+/)) {
      m=substr(s,RSTART,RLENGTH); gsub(/[^0-9]/,"",m); if (m+0>maxhash) maxhash=m+0
      s=substr(s,RSTART+RLENGTH)
    }
  }
  END {
    print "maxinv=" maxinv+0
    print "maxhash=" maxhash+0
    print "maxitem=" (maxlist>maxrow?maxlist:maxrow)+0
  }
' "$draft")
maxinv=$(printf '%s\n' "$anchor_report" | sed -n 's/^maxinv=//p')
maxhash=$(printf '%s\n' "$anchor_report" | sed -n 's/^maxhash=//p')
maxitem=$(printf '%s\n' "$anchor_report" | sed -n 's/^maxitem=//p')
if [ "${maxinv:-0}" -gt 0 ] && [ "${maxitem:-0}" -gt 0 ] && [ "$maxinv" -gt "$maxitem" ]; then
  echo "FAIL: prose cites 'Invariant $maxinv' but the largest numbered item is $maxitem — a renumber likely orphaned the reference" >&2
  fail=1
fi
if [ "${maxhash:-0}" -gt 0 ] && [ "${maxitem:-0}" -gt 0 ] && [ "$maxhash" -gt "$maxitem" ]; then
  echo "FAIL: prose cites 'writer/shim #$maxhash' but the largest numbered item is $maxitem — a renumber likely orphaned the reference" >&2
  fail=1
fi

# --- declared letter-range vs lettered headings (warn-only heuristic) ---
ranges=$(grep -voE '^```.*' "$draft" 2>/dev/null | grep -oE '\(([A-Z])[–-]([A-Z])\)' | tr -d '()' || true)
if [ -n "$ranges" ]; then
  letters=$(grep -oE '^#{2,4} ([A-Z])[0-9]*[. :]' "$draft" | grep -oE ' [A-Z]' | tr -d ' ' | sort -u || true)
  hi_heading=$(printf '%s' "$letters" | tail -c 2 | tr -d '\n')
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    hi_declared="${r: -1}"
    if [ -n "$hi_heading" ] && [ "$hi_declared" != "$hi_heading" ]; then
      echo "warn: declared range ($r) but lettered headings reach '$hi_heading' — verify the range matches the sections that exist" >&2
    fi
  done <<< "$ranges"
fi

# --- single-mention invariants ---
directive=$(grep -oE '<!--[[:space:]]*audit:mention-once:[^>]*-->' "$draft" 2>/dev/null \
  | sed -E 's/.*mention-once:[[:space:]]*//; s/[[:space:]]*-->.*//' | head -1 || true)
terms="$directive,$mention_csv"
old_ifs="$IFS"; IFS=','
for t in $terms; do
  t="$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$t" ] && continue
  cnt=$(grep -vF 'audit:mention-once' "$draft" | grep -oF "$t" | wc -l | tr -d ' ')
  if [ "$cnt" -gt 1 ]; then
    echo "FAIL: single-mention term '$t' appears $cnt times (expected ≤1 — mention rejected alternatives once; see references/house-style.md)" >&2
    fail=1
  fi
done
IFS="$old_ifs"

[ "$fail" -eq 0 ] && echo "audit: ok"
exit "$fail"
