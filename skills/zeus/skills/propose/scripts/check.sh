#!/usr/bin/env bash
# check.sh — run the deterministic pre-post gates in one call:
#   1. validate-draft.sh — required sections present
#   2. audit-draft.sh    — consistency invariants (Q cross-refs, single-mention)
#
# These always run together before a preview/post (create and amend), so this
# bundles them and returns a single status. The NON-deterministic gates —
# reader-test (4b) and quality-audit (4c) — are deliberately NOT here: they need a
# fresh subagent / human judgment, not a script.
#
# Usage: check.sh <draft-path> [--mention-once "t1,t2"] [--kind <k>]
# Exit:  0 if both pass; non-zero if either fails (missing section, or a real
#        consistency inconsistency). Both tools' reports are printed to stderr.
# --kind forwards to validate-draft (implementation|decision|research|tracking);
#        default implementation = strict, so omitting it is the legacy behaviour.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
draft="${1:?Usage: check.sh <draft-path> [--mention-once \"t1,t2\"] [--kind <k>]}"; shift || true
mention=()
kind=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mention-once) mention=(--mention-once "$2"); shift 2 ;;
    --kind) kind=(--kind "$2"); shift 2 ;;
    *) echo "check.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -f "$draft" ] || { echo "check.sh: draft not found: $draft" >&2; exit 2; }

rc=0
echo "── validate (required sections) ──" >&2
bash "$script_dir/validate-draft.sh" "$draft" "${kind[@]}" >&2 || rc=1
echo "── audit (consistency) ──" >&2
bash "$script_dir/audit-draft.sh" "$draft" "${mention[@]}" >&2 || rc=1

[ "$rc" -eq 0 ] && echo "check: ok"
exit "$rc"
