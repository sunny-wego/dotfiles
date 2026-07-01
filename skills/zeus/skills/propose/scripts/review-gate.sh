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
build_req=$(printf '%s' "$rr" | jq -r '.build_ready_required // false')
mode=$(printf '%s' "$rr" | jq -r '.mode')

# review:"never" is an explicit, surfaced author skip of BOTH axes.
if [ "$mode" = "never" ]; then
  echo "review-gate: review explicitly skipped (review: \"never\") — this must have been a visible choice in the confirmation dialog." >&2
  exit 0
fi

# Nothing to gate on either axis.
[ "$required" = "true" ] || [ "$build_req" = "true" ] || exit 0

current=$(bash "$script_dir/state-hash.sh" "$state" 2>/dev/null || echo "")

# ── align axis: a review-warranting proposal needs a fresh reader test (Stage 1)
if [ "$required" = "true" ]; then
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
  if [ -z "$stamped" ] || [ "$stamped" != "$current" ]; then
    echo "review-gate: state was edited AFTER the last reader test (hash mismatch) — the fixes are untested." >&2
    echo "  stamped: ${stamped:-<none>}" >&2
    echo "  current: $current" >&2
    echo "  Re-run the reviewer simulation on the current render, then re-stamp (see above)." >&2
    exit 1
  fi
fi

# ── build axis: a merge-closing work-order needs an executable contract ───────
# BUILD-INCOMPLETE may STILL post — but only with the author's RECORDED consent
# (.build_ready_consent). Silent skipping is the exact failure mode this closes
# (#988). The verdict is hash-pinned exactly like the align stamp, so any content
# edit forces a re-test.
if [ "$build_req" = "true" ]; then
  bv=$(jq -r '.build_ready // ""' "$state" 2>/dev/null || echo "")
  if [ -z "$bv" ]; then
    echo "review-gate: this is a merge-closing work-order — run the Stage 1 implementer persona (BUILD-READY test) before posting." >&2
    echo "  It reads render(state) as the cold implementing agent and ranks the contract gaps by blast-radius (rfc-mode.md → Stage 1)." >&2
    exit 1
  fi
  bh=$(jq -r '.build_ready_hash // ""' "$state" 2>/dev/null || echo "")
  if [ -z "$bh" ] || [ "$bh" != "$current" ]; then
    echo "review-gate: state was edited AFTER the build-ready test (hash mismatch) — re-run the implementer persona and re-stamp." >&2
    exit 1
  fi
  if [ "$bv" = "incomplete" ] && [ "$(jq -r '.build_ready_consent // false' "$state" 2>/dev/null || echo false)" != "true" ]; then
    echo "review-gate: BUILD-INCOMPLETE — the implementer persona found load-bearing contract gaps:" >&2
    gaps=$(jq -r '.build_ready_gaps // [] | to_entries[] | "    \(.key + 1). \(.value)"' "$state" 2>/dev/null || true)
    [ -n "$gaps" ] && printf '%s\n' "$gaps" >&2
    echo "  Pin them (MUST/MUST-NOT invariants + a concrete shape example), or record the skip on purpose:" >&2
    echo "    jq '.build_ready_consent = true' \"$state\" > tmp && mv tmp \"$state\"   (MUST be a visible choice in the confirmation dialog)" >&2
    exit 1
  fi
fi
exit 0
