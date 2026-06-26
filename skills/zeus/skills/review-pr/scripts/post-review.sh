#!/usr/bin/env bash
# post-review.sh — turn $FINDINGS_FILE into ONE GitHub review and (optionally)
# post it. Implements the rendering contract in references/comment-format.md and
# the validation in references/findings-schema.md.
#
# Default is --dry-run: render the whole review to stdout, post nothing.
#
# Usage:
#   post-review.sh [--dry-run|--submit] [--request-changes] [--findings <file>]
#     --dry-run         (default) print preview + payload, post nothing
#     --submit          actually POST the review (event COMMENT)
#     --request-changes with --submit, use event REQUEST_CHANGES (explicit only)
#
# Requires $PR_FILE, $ANCHORS_FILE, $FINDINGS_FILE to exist (setup steps run first).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

mode="dry-run" event="COMMENT" findings="$FINDINGS_FILE"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) mode="dry-run"; shift ;;
    --submit) mode="submit"; shift ;;
    --request-changes) event="REQUEST_CHANGES"; shift ;;
    --findings) findings="${2:?}"; shift 2 ;; --findings=*) findings="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
[ -f "$PR_FILE" ]      || { echo "post-review: missing $PR_FILE (run identify/setup first)" >&2; exit 2; }
[ -f "$findings" ]     || { echo "post-review: missing findings file $findings" >&2; exit 2; }
[ -f "$ANCHORS_FILE" ] || echo '{}' > "$ANCHORS_FILE"

python3 - "$PR_FILE" "$ANCHORS_FILE" "$findings" "$mode" "$event" "$REVIEW_FILE" <<'PY'
import sys, json

pr      = json.load(open(sys.argv[1]))
anchors = json.load(open(sys.argv[2]))
items   = json.load(open(sys.argv[3]))
mode, event, review_file = sys.argv[4], sys.argv[5], sys.argv[6]

LABEL = {
    "confirmed":  "\U0001F534 **Confirmed — reproduced.**",
    "hypothesis": "⚪ **Hypothesis — please verify.**",
    "nit":        "\U0001F7E1 **Nit.**",
}
TAG = {"confirmed": "\U0001F534", "hypothesis": "⚪", "nit": "\U0001F7E1"}

# ---- validate (schema hard rules 1 & 2; refuse to post a labeling bug) ----
errs = []
for f in items:
    fid = f.get("id", "<no-id>")
    for k in ("id","handler","status","severity","title","concern","reasoning","question"):
        if not f.get(k):
            errs.append(f"{fid}: missing required field '{k}'")
    if f.get("status") == "confirmed" and not (f.get("evidence") or "").strip():
        errs.append(f"{fid}: status=confirmed but evidence is empty (rule 1)")
    if f.get("status") == "hypothesis" and not (f.get("verify") or "").strip():
        errs.append(f"{fid}: status=hypothesis but verify is empty (rule 2)")
    if f.get("status") not in ("confirmed","hypothesis","nit"):
        errs.append(f"{fid}: invalid status {f.get('status')!r}")
if errs:
    sys.stderr.write("post-review: refusing to post — findings violate schema:\n  " + "\n  ".join(errs) + "\n")
    sys.exit(3)

def severity(f): return f.get("severity","")

def render_body(f):
    lead = f"{LABEL[f['status']]} ({severity(f)})"
    parts = [lead, "", f["concern"], "", f"**Why:** {f['reasoning']}"]
    if f["status"] == "confirmed":
        parts += ["", "**Evidence — steps + output (rerun it yourself):**",
                  "```", (f.get("evidence") or "").rstrip(), "```"]
    elif f["status"] == "hypothesis":
        parts += ["", f"**Not reproduced.** To confirm or refute: {f['verify']}"]
    parts += ["", f"**Question:** {f['question']}"]
    if f.get("fix_aside"):
        parts += ["", f"_(Fix aside: {f['fix_aside']})_"]
    parts += ["", "<sub>via `zeus:review-pr`</sub>", f"<!-- zeus:review-pr id={f['id']} -->"]
    return "\n".join(parts)

# ---- partition: valid inline anchor vs summary ----
inline, summary = [], []
for f in items:
    a = f.get("anchor")
    ok = bool(a) and isinstance(a, dict) and a.get("line") in anchors.get(a.get("path",""), [])
    (inline if ok else summary).append(f)

# ---- triage header (always) ----
c = sum(1 for f in items if f["status"]=="confirmed")
h = sum(1 for f in items if f["status"]=="hypothesis")
n = sum(1 for f in items if f["status"]=="nit")
header = [
    f"**Review: {len(items)} findings — {c} confirmed, {h} to verify, {n} nits.**",
    "",
    'Confirmed findings include reproduction steps. "To verify" findings are '
    "concerns I couldn't reproduce locally — each says how to confirm or refute it.",
    "",
]
def loc(f):
    a = f.get("anchor") or {}
    return f"`{a.get('path')}:{a.get('line')}`" if a.get("path") else ""
for f in items:
    header.append(f"- {TAG[f['status']]} {f['title']}  {('· ' + loc(f)) if loc(f) else ''}".rstrip())
if summary:
    header += ["", "---", "", "### Findings without an inline anchor", ""]
    for f in summary:
        header += [render_body(f), "", "---", ""]
header += ["", "<sub>via `zeus:review-pr`</sub>"]
body = "\n".join(header).rstrip() + "\n"

comments = []
for f in inline:
    a = f["anchor"]
    cm = {"path": a["path"], "line": a["line"], "side": a.get("side","RIGHT"), "body": render_body(f)}
    if a.get("start_line"):
        cm["start_line"] = a["start_line"]
        cm["start_side"] = a.get("side","RIGHT")
    comments.append(cm)

review = {"commit_id": pr.get("head_sha"), "event": event, "body": body, "comments": comments}

# Always persist the machine payload; stdout stays human-only.
json.dump(review, open(review_file, "w"))

if mode == "dry-run":
    print("="*72)
    print(f"DRY RUN — nothing posted. PR {pr.get('owner')}/{pr.get('repo')}#{pr.get('number')} @ {pr.get('head_sha','')[:12]}")
    print(f"event={event}  inline={len(inline)}  summary={len(summary)}  total={len(items)}")
    print(f"payload written to: {review_file}")
    print("="*72)
    print("\n--- REVIEW BODY ---\n")
    print(body)
    for cm in comments:
        print(f"\n--- INLINE @ {cm['path']}:{cm['line']} ({cm['side']}) ---\n")
        print(cm["body"])
PY

if [ "$mode" = "submit" ]; then
  # Idempotent re-review: drop comments whose id marker is already posted.
  existing=$(gh api "repos/$(jq -r .owner "$PR_FILE")/$(jq -r .repo "$PR_FILE")/pulls/$(jq -r .number "$PR_FILE")/comments" \
               --paginate -q '.[].body' 2>/dev/null | grep -oE 'zeus:review-pr id=[a-z0-9-]+' | sort -u || true)
  if [ -n "$existing" ]; then
    echo "post-review: existing posted ids:" >&2; echo "$existing" >&2
    # (filter $REVIEW_FILE.comments[] whose marker is in $existing before posting)
  fi
  gh api "repos/$(jq -r .owner "$PR_FILE")/$(jq -r .repo "$PR_FILE")/pulls/$(jq -r .number "$PR_FILE")/reviews" \
    --input "$REVIEW_FILE" && echo "post-review: review posted." >&2
fi
