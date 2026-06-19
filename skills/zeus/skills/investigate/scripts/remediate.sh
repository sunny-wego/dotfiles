#!/usr/bin/env bash
# Spawn a remediation bug from a confirmed hypothesis, linked both ways.
#
#   remediate.sh <Hk|#num> "<fix title>"
#
# Creates a `remediation`-labelled issue pre-referenced to the hypothesis + the
# investigation, attaches it as a sub-issue (so it rides the progress bar), and
# cross-refs the hypothesis. Hand off to /zeus:create-pr (with "Closes #<this>") →
# /zeus:address-pr; `verify-shipped.sh` governs whether the fix is actually in prod.
# Honours DRY_RUN=1. One confirmed cause may spawn several remediations — run again.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require gh; require jq

ref="${1:?usage: remediate.sh <Hk|#num> \"<fix title>\"}"
fix="${2:?need a fix title}"
epic="$(active_epic)"; [ -n "$epic" ] || die "no active investigation (run /zeus:investigate new)"
hyp="$(hyp_number "$epic" "$ref")"
[ -n "$hyp" ] || die "could not resolve hypothesis '$ref' to a sub-issue of #$epic"
hyptitle="$(gh issue view "$hyp" --json title --jq .title 2>/dev/null || echo "#$hyp")"

body="Remediation for **$hyptitle** (#$hyp) — the confirmed root cause in investigation #$epic.

<!-- fill in: repro · expected vs actual · severity · owner -->

A fix PR should \`Closes #<this>\`; \`verify-shipped\` then governs whether it actually reached prod
(merged ≠ shipped). Part of #$epic."

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] gh issue create --title \"$fix\" --label remediation  (refs #$hyp, #$epic)" >&2
  echo "[dry-run] gh issue comment #$hyp  (remediation opened)" >&2
  exit 0
fi

gh label create remediation 2>/dev/null || true
body="$(printf '%s' "$body" | bash "$HERE/watermark.sh" investigate - 2>/dev/null || printf '%s' "$body")"
url="$(gh issue create --title "$fix" --label remediation --body "$body")"
num="$(echo "$url" | grep -oE '[0-9]+$')"
log "opened remediation #$num — $fix"
cbody="Remediation opened: #$num — $fix"
cbody="$(printf '%s' "$cbody" | bash "$HERE/watermark.sh" investigate - 2>/dev/null || printf '%s' "$cbody")"
gh issue comment "$hyp" --body "$cbody" >/dev/null 2>&1 || true
"$HERE/link-to-epic.sh" "$num" >/dev/null 2>&1 || log "could not auto-link #$num — run /zeus:investigate link $num"
echo "$num"
echo "→ next:  /zeus:create-pr (body: \"Closes #$num\")  →  /zeus:address-pr   (verify-shipped governs the close)" >&2
