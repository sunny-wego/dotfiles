#!/usr/bin/env bash
# ledger.sh — the cross-session learnings ledger (JSONL, one object per line),
# in the zeus SOURCE so it accumulates across repos/sessions and is git-tracked.
#
# This is what makes "iterate based on EVERY session" work: each run appends, and
# dedup-by-`pattern` turns a one-off into a tracked pattern with a recurrence
# count. A learning is RIPE (worth landing now) when it recurs (count >= 2) OR is
# high-severity even once.
#
# Verbs (bulk payloads via stdin/--from per house convention, never inline JSON):
#   append [--from <file|->]   merge an entry (dedup by .pattern); stdin default
#   digest                     grouped-by-tier summary, ripe entries flagged
#   list                       raw ledger (one JSON per line)
#   mark <pattern> <status> [note]   set status: open|ripe|validated|shipped|deferred|rejected
#
# Entry shape (append input): {pattern, tier, destination, target, severity,
#   grade, fix, validation, note, evidence:{session,repo,pr,signal,metric}}.
# Stored shape adds: id, first_seen, last_seen, count, status.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

now() { date -u +%FT%TZ; }
touch "$LEDGER"

cmd="${1:-digest}"; shift || true

case "$cmd" in
  append)
    src="-"
    case "${1:-}" in --from) src="${2:?--from needs a file or -}";; --from=*) src="${1#*=}";; esac
    raw="$(if [ "$src" = "-" ]; then cat; else cat "$src"; fi)"
    pat="$(printf '%s' "$raw" | jq -r '.pattern // empty')"
    [ -n "$pat" ] || { echo "ledger append: entry needs a .pattern" >&2; exit 1; }
    with_lock "$LEDGER_DIR/.lock"
    ts="$(now)"; tmp="$LEDGER.tmp.$$"
    exists="$(jq -s --arg p "$pat" 'any(.[]; .pattern == $p)' "$LEDGER" 2>/dev/null || echo false)"
    if [ "$exists" = "true" ]; then
      # Recurrence: bump count + last_seen, refresh fields, append this evidence.
      jq -c --arg p "$pat" --argjson new "$raw" --arg ts "$ts" '
        if .pattern == $p then
          .count = ((.count // 1) + 1) | .last_seen = $ts
          | .severity = ($new.severity // .severity)
          | .grade = ($new.grade // .grade)
          | .tier = ($new.tier // .tier)
          | .destination = ($new.destination // .destination)
          | .target = ($new.target // .target)
          | .fix = ($new.fix // .fix)
          | .evidence = ((.evidence // []) + (if $new.evidence then [$new.evidence] else [] end))
        else . end
      ' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
    else
      # First sighting: create the row with count=1.
      cp "$LEDGER" "$tmp" 2>/dev/null || : > "$tmp"
      jq -nc --argjson new "$raw" --arg ts "$ts" '
        $new + { id: ($new.id // $new.pattern), first_seen: $ts, last_seen: $ts,
                 count: 1, status: ($new.status // "open"),
                 evidence: (if $new.evidence then [$new.evidence] else [] end) }
      ' >> "$tmp"
      mv "$tmp" "$LEDGER"
    fi
    jq -c --arg p "$pat" 'select(.pattern == $p)' "$LEDGER" | tail -1
    ;;

  digest)
    if [ ! -s "$LEDGER" ]; then echo "ledger empty: $LEDGER"; exit 0; fi
    echo "LEDGER DIGEST  ($LEDGER)"
    for tier in skill repo; do
      echo ""; echo "== ${tier}-level =="
      jq -rc --arg t "$tier" 'select(.tier == $t)
        | ((.count // 1) >= 2 or (.severity == "high")) as $ripe
        | "  [\(.status // "open")]\(if $ripe and (.status//"open"|test("shipped|deferred|rejected")|not) then " RIPE" else "" end) \(.pattern)  (x\(.count // 1), \(.severity // "?"), \(.grade // "?"))  -> \(.destination // .target // "?")"' \
        "$LEDGER" 2>/dev/null || true
    done
    # Anything with an unknown/missing tier — surface so it can't hide.
    jq -rc 'select((.tier // "") | (. == "skill" or . == "repo") | not)
      | "  [UNCLASSIFIED] \(.pattern)"' "$LEDGER" 2>/dev/null || true
    ;;

  list) cat "$LEDGER" ;;

  mark)
    pat="${1:?mark needs a <pattern>}"; status="${2:?mark needs a <status>}"; note="${3:-}"
    with_lock "$LEDGER_DIR/.lock"
    tmp="$LEDGER.tmp.$$"
    jq -c --arg p "$pat" --arg s "$status" --arg n "$note" --arg ts "$(now)" '
      if .pattern == $p then .status = $s | .last_seen = $ts
        | (if $n != "" then .note = $n else . end) else . end
    ' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
    jq -c --arg p "$pat" 'select(.pattern == $p)' "$LEDGER"
    ;;

  *) echo "ledger.sh: unknown verb '$cmd' (append|digest|list|mark)" >&2; exit 2 ;;
esac
