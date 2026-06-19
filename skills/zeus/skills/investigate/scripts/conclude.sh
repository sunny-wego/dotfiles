#!/usr/bin/env bash
# Conclude a hypothesis with a verdict (the epistemic close — distinct from
# shipping a fix, which is `remediate` → a bug whose close `verify-shipped` governs).
#
#   conclude.sh <Hk|#num> confirmed|refuted|inconclusive
#
# Closes the hypothesis sub-issue, labels the verdict (for the status rollup),
# and comments. On `confirmed` it prints the `remediate` hand-off. Honours DRY_RUN=1.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq

ref="${1:?usage: conclude.sh <Hk|#num> <confirmed|refuted|inconclusive>}"
verdict="${2:?need a verdict: confirmed|refuted|inconclusive}"
case "$verdict" in confirmed|refuted|inconclusive) ;; *) die "verdict must be confirmed|refuted|inconclusive";; esac

epic="$(active_epic)"; [ -n "$epic" ] || die "no active investigation (run /zeus:investigate new)"
num="$(hyp_number "$epic" "$ref")"
[ -n "$num" ] || die "could not resolve hypothesis '$ref' to a sub-issue of #$epic"
title="$(gh issue view "$num" --json title --jq .title 2>/dev/null || echo "#$num")"

# completed reason for a confirmed root cause; not_planned for ruled-out / parked.
reason="completed"; [ "$verdict" = "confirmed" ] || reason="not_planned"

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] gh issue close #$num --reason $reason  + label '$verdict'  ($title)" >&2
else
  gh label create "$verdict" 2>/dev/null || true
  gh issue edit "$num" --add-label "$verdict" >/dev/null 2>&1 || true
  ccomment="Concluded: **$verdict**."
  ccomment="$(printf '%s' "$ccomment" | bash "$HERE/watermark.sh" investigate - 2>/dev/null || printf '%s' "$ccomment")"
  gh issue close "$num" --reason "$reason" \
    --comment "$ccomment" >/dev/null
  log "concluded $title as $verdict (closed #$num)"
fi

if [ "$verdict" = "confirmed" ]; then
  hk="$(echo "$title" | grep -oE '^H[0-9]+' || echo "#$num")"
  echo "→ confirmed root cause. Spawn the fix:  /zeus:investigate remediate $hk \"<fix title>\""
fi
