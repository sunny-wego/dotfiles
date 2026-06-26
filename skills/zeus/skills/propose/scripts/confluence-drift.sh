#!/usr/bin/env bash
# confluence-drift.sh — detect out-of-band edits to a Confluence page before an
# amend re-renders and overwrites it. The Confluence analogue of drift-check.sh.
#
# WHY NOT a text diff (like drift-check.sh does for GitHub): GitHub stores the issue
# body verbatim, so render(state) can be diffed against the live body. Confluence
# does NOT — it round-trips markdown → storage format → markdown, so a freshly
# fetched body never byte-matches what we posted even with zero edits (tables get
# reformatted, <details> becomes an expand macro, em-dashes get escaped, …). A text
# diff would false-positive every time. The reliable signal is the page VERSION
# NUMBER: Confluence bumps it on every edit. We record the version we wrote (state's
# confluence_version); on amend the agent fetches the live version and passes both
# here. Live > stored ⇒ someone edited out-of-band since our last write ⇒ STOP and
# reconcile before the re-render clobbers them.
#
# NOTE on draft vs current: published (status:current) pages increment version on
# every edit, so the gate is reliable there. DRAFT pages may not bump version on
# update — but a draft is private to its single author (no one else can edit it), so
# out-of-band drift is moot until it's published. The gate targets current pages
# (the default destination status); it's a no-op safety margin on drafts.
#
# Usage:  confluence-drift.sh --stored <N> --current <M>
# Exit:   0 in sync (live version == our last-written version)
#         1 DRIFT (live version ahead of ours — out-of-band edit) [reason on stderr]
#         2 indeterminate (no stored version yet — can't gate; caller must verify)

set -euo pipefail

stored=""; current=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stored)  stored="$2";  shift 2 ;;
    --current) current="$2"; shift 2 ;;
    *) echo "confluence-drift.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# A live version is always knowable (the agent just fetched the page); a missing
# stored version means we never recorded one (e.g. a page created before this gate
# existed, or state lost the field) — we can't compare, so say so loudly.
case "$current" in ''|*[!0-9]*) echo "confluence-drift.sh: --current <M> must be a number" >&2; exit 2 ;; esac
case "$stored"  in ''|*[!0-9]*)
  echo "confluence-drift: no recorded version for this page — cannot gate drift." >&2
  echo "  Fetch the page and eyeball it for out-of-band edits before amending." >&2
  exit 2 ;;
esac

if [ "$current" -gt "$stored" ]; then
  echo "confluence-drift: DRIFT — live page is at version $current but we last wrote $stored." >&2
  echo "  Someone edited the page out-of-band since our last write." >&2
  echo "  STOP: re-ingest their edits into state before amending, or the re-render clobbers them." >&2
  exit 1
fi
if [ "$current" -lt "$stored" ]; then
  echo "confluence-drift: WARNING — recorded version $stored is AHEAD of live $current (unexpected)." >&2
  echo "  Treating as drift; reconcile manually." >&2
  exit 1
fi
echo "confluence-drift: in sync (live version $current == last written $stored)"
exit 0
