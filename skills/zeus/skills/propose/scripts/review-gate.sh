#!/usr/bin/env bash
# review-gate.sh — the reader-test enforcement gate, shared by every publish backend
# (post-issue.sh, confluence.sh). Destination-neutral: it reads ONLY the proposal
# STATE, never touches GitHub/Confluence. Extracted from post-issue.sh so the two
# backends can't drift apart (publish-contract.md, clause 3).
#
# A proposal whose content warrants review — requires-review.sh derives this from
# the state (questions / grounded claims / a substantial proposal / invariants;
# `review:"always"|"never"` overrides) — must not be posted without a fresh reader
# test (Stage 1), stamped TWO ways on the state:
#   .reader_test      = true            — the test ran
#   .reader_test_hash = <state hash>    — it ran against THIS state (state-hash.sh)
# The hash closes the "test → edit → post untested" path: any state edit after the
# test changes the hash, and this gate refuses until the test re-runs. rehydrate.sh
# clears both stamps, so every amend re-requires the test too.
#
# Usage:  review-gate.sh <state-file>
# Exit:   0 = pass (also when there's nothing to gate: no state file, or review not
#               required); 1 = refuse (reason + remediation on stderr); 2 = usage.
set -euo pipefail

state="${1:-}"
[ -n "$state" ] || { echo "usage: review-gate.sh <state-file>" >&2; exit 2; }
# No state file ⇒ nothing to gate (matches prior inline behavior in post-issue.sh).
[ -f "$state" ] || exit 0

script_dir="$(cd "$(dirname "$0")" && pwd)"

rr=$(bash "$script_dir/requires-review.sh" "$state" 2>/dev/null || echo '{"required":false,"mode":"auto","reasons":[]}')
required=$(printf '%s' "$rr" | jq -r '.required')
mode=$(printf '%s' "$rr" | jq -r '.mode')
if [ "$mode" = "never" ]; then
  echo "review-gate: review explicitly skipped (review: \"never\") — this must have been a visible choice in the confirmation dialog." >&2
fi
[ "$required" = "true" ] || exit 0

why=$(printf '%s' "$rr" | jq -r '.reasons | join("; ")')
rt=$(jq -r '.reader_test // false' "$state" 2>/dev/null || echo false)
if [ "$rt" != "true" ]; then
  echo "review-gate: this proposal requires a reader test (Stage 1) before posting — $why." >&2
  echo "  Run the reviewer simulation on render(state), then stamp it:" >&2
  echo "    HASH=\$(bash \"$script_dir/state-hash.sh\" \"$state\")" >&2
  echo "    jq --arg h \"\$HASH\" '.reader_test=true | .reader_test_hash=\$h' \"$state\" > tmp && mv tmp \"$state\"" >&2
  exit 1
fi
stamped=$(jq -r '.reader_test_hash // ""' "$state" 2>/dev/null || echo "")
current=$(bash "$script_dir/state-hash.sh" "$state" 2>/dev/null || echo "")
if [ -z "$stamped" ] || [ "$stamped" != "$current" ]; then
  echo "review-gate: state was edited AFTER the last reader test (hash mismatch) — the fixes are untested." >&2
  echo "  stamped: ${stamped:-<none>}" >&2
  echo "  current: $current" >&2
  echo "  Re-run the reviewer simulation on the current render, then re-stamp (see above)." >&2
  exit 1
fi
exit 0
