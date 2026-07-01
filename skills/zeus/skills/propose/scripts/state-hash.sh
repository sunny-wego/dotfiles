#!/usr/bin/env bash
# state-hash.sh — canonical content hash of an issue state file.
#
# WHY: the reader test (4b) must be re-run after EVERY state edit — fix rounds are
# where regressions are born (a fix that renumbers invariants orphans a cross-
# reference; a confident clarification overclaims). A boolean stamp permits
# "test → fix → post untested"; a hash stamp makes that path unrepresentable:
# post-issue compares hash(current state) to the stamped .reader_test_hash and
# refuses on mismatch, so any state edit structurally forces a re-test.
#
# The hash is over the STATE (canonical jq -S), not the rendered body — renders
# vary cosmetically (pin-refs rewrites path:line → blob/<sha> URLs whenever HEAD
# moves), and re-pinning is exactly the cosmetic delta that must NOT invalidate a
# reader test. Same state → same hash, regardless of when it's rendered.
#
# Excluded from the hash: the stamp fields themselves (so stamping doesn't change
# the hash being stamped) — both the align stamp (`reader_test`/`reader_test_hash`)
# and the build stamp (`build_ready`/`build_ready_hash`/`build_ready_gaps`/
# `build_ready_consent`) — and `review` (a gating knob, not rendered content —
# toggling it must not invalidate a test of an unchanged document).
#
# Usage: state-hash.sh <state-file>
# Output: 64-hex sha256 on stdout.

set -euo pipefail

state="${1:?Usage: state-hash.sh <state-file>}"
[ -f "$state" ] || { echo "state-hash.sh: state file not found: $state" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then hasher=(sha256sum)
else hasher=(shasum -a 256); fi

jq -S 'del(.reader_test, .reader_test_hash, .review, .build_ready, .build_ready_hash, .build_ready_gaps, .build_ready_consent)' "$state" | "${hasher[@]}" | awk '{print $1}'
