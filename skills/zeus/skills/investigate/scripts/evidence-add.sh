#!/usr/bin/env bash
# Append a numbered evidence item to a report, enforcing the reproducibility
# contract. The agent composes the evidence draft (claim + bounded query/recorded
# block + result + reading); this script numbers it, lints it, and appends it.
#
# Usage: evidence-add.sh <report-path> <evidence-draft.md>
#
# Lint (rejects, exit 1):
#   - no fenced ```sql/```bash/```text query block AND no "recorded" label
#   - any /blob/main/ or /blob/master/ code reference (must be SHA-pinned)
# Honours DRY_RUN=1 (prints the assigned id + lint result, writes nothing).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
require jq

hyp="" stance=""; args=()
while [ $# -gt 0 ]; do case "$1" in
  --hypothesis) hyp="$2"; shift 2;;
  --stance) stance="$2"; shift 2;;
  *) args+=("$1"); shift;;
esac; done
set -- "${args[@]}"

pm="${1:?usage: evidence-add.sh [--hypothesis Hk --stance for|against] <report-path> <evidence-draft.md>}"
draft="${2:?need an evidence draft file}"
[ -f "$pm" ] || die "report not found: $pm"
[ -f "$draft" ] || die "draft not found: $draft"

# Hypothesis tag (structural link evidence→hypothesis) + anchor check.
tag=""
if [ -n "$hyp" ]; then
  st="bears on"; case "$stance" in for) st="supports";; against) st="refutes";; esac
  tag=" ($hyp, $st)"
  epic="$(active_epic)"
  if [ -n "$epic" ] && [ -z "$(hyp_number "$epic" "$hyp")" ]; then
    log "anchor warning: hypothesis '$hyp' is not a sub-issue of #$epic — tag kept, but check the ref"
  fi
fi

# --- lint the contract ---
if ! grep -qE '```(sql|bash|text)' "$draft" && ! grep -qiw 'recorded' "$draft"; then
  die "contract: evidence has no bounded query block (\`\`\`sql/\`\`\`bash) and is not labelled 'recorded'. Add one."
fi
if grep -qE '/blob/(main|master)/' "$draft"; then
  die "contract: code reference uses /blob/main/ — SHA-pin it (line numbers rot). See references/reproducibility-contract.md."
fi

# --- assign next E<n> ---
last="$(grep -oE '### E[0-9]+' "$pm" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
next=$(( ${last:-0} + 1 ))
log "assigned E$next"

if [ "$DRY_RUN" = "1" ]; then
  echo "[dry-run] would append E$next to $pm (lint OK)" >&2
  echo "E$next"; exit 0
fi

# --- append before the References section if present, else at EOF ---
block=$'\n### E'"$next$tag"$' — '"$(head -1 "$draft" | sed 's/^#* *//')"$'\n\n'"$(tail -n +2 "$draft")"$'\n'
if grep -qE '^## References' "$pm"; then
  # feed the multi-line block via a file + getline — `awk -v` truncates multi-line
  # values on BSD awk ("newline in string"), which silently drops the evidence item.
  insf="$(mktemp)"; printf '%s\n' "$block" > "$insf"
  awk -v bf="$insf" '/^## References/ && !done {while((getline ln<bf)>0) print ln; close(bf); done=1} {print}' "$pm" > "$pm.tmp" && mv "$pm.tmp" "$pm"
  rm -f "$insf"
else
  printf '%s\n' "$block" >> "$pm"
fi
# bump the [E1]..[En] range note if present
sed -i.bak -E "s/\[E1\]…\[E[0-9]+\]/[E1]…[E$next]/g" "$pm" 2>/dev/null && rm -f "$pm.bak" || true
log "appended E$next to $pm"
echo "E$next"
