#!/usr/bin/env bash
# post-review.sh — turn $FINDINGS_FILE into ONE GitHub review and (optionally)
# post it. Implements the rendering contract in references/comment-format.md and
# the validation in references/findings-schema.md.
#
# Output is keyed on ROLE (see detect-target.sh):
#   --self  reviewing MY work (pre-PR diff or my own PR) → render findings to stdout
#           for hand-back; NEVER posts. This is the only mode for a local diff.
#   --peer  reviewing SOMEONE ELSE'S PR (reviewer role) → render (post nothing) by
#           default; add --submit to POST one review.
#
# Usage:
#   post-review.sh --self  [--findings <file>]
#   post-review.sh --peer  [--submit [--request-changes]] [--findings <file>]
#     --submit          (peer only) actually POST the review (event COMMENT)
#     --request-changes with --submit, use event REQUEST_CHANGES (explicit only)
# Default role: self when $PR_FILE is a local diff, else peer (dry-run).
#
# Requires $PR_FILE, $ANCHORS_FILE, $FINDINGS_FILE to exist (setup steps run first).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

role="" submit=false event="COMMENT" findings="$FINDINGS_FILE"
while [ $# -gt 0 ]; do
  case "$1" in
    --self) role="self"; shift ;;
    --peer) role="peer"; shift ;;
    --submit) submit=true; shift ;;
    --request-changes) event="REQUEST_CHANGES"; shift ;;
    --findings) findings="${2:?}"; shift 2 ;; --findings=*) findings="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
[ -f "$PR_FILE" ]      || { echo "post-review: missing $PR_FILE (run identify/setup first)" >&2; exit 2; }
[ -f "$findings" ]     || { echo "post-review: missing findings file $findings" >&2; exit 2; }
[ -f "$ANCHORS_FILE" ] || echo '{}' > "$ANCHORS_FILE"

# A local (pre-PR) diff is always self-review — there is no PR to post to.
is_local=$(jq -r '.local // false' "$PR_FILE" 2>/dev/null || echo false)
[ -z "$role" ] && { [ "$is_local" = "true" ] && role="self" || role="peer"; }
if [ "$role" = "self" ] || [ "$is_local" = "true" ]; then
  role="self"
  if [ "$submit" = "true" ]; then
    echo "post-review: refusing --submit on a self-review — findings are handed back to fix, not posted. Drop --submit (or review the PR as --peer)." >&2
    exit 2
  fi
fi
# mode passed to the renderer: self | peer-dry | submit
if [ "$role" = "self" ]; then mode="self"
elif [ "$submit" = "true" ]; then mode="submit"
else mode="dry-run"; fi

# Idempotent re-review: on submit, drop findings whose id is ALREADY posted on the
# PR (an earlier round), so re-running this skill never duplicates comments. A
# finding can live in EITHER of two places, so we union both — missing one lets that
# kind re-post every round:
#   - inline review comments (/pulls/N/comments) → become resolvable threads, also
#     addressed in-thread by resolve-thread.sh (step 5b).
#   - prior review summary BODIES (/pulls/N/reviews) → non-anchored findings have NO
#     thread to resolve, so this dedup is the ONLY thing stopping them re-posting.
# Computed BEFORE rendering so the triage header excludes them too, not just inline.
export RP_EXISTING_IDS=""
if [ "$mode" = "submit" ]; then
  rp_owner=$(jq -r .owner "$PR_FILE"); rp_repo=$(jq -r .repo "$PR_FILE"); rp_number=$(jq -r .number "$PR_FILE")
  RP_EXISTING_IDS=$( {
      gh api "repos/$rp_owner/$rp_repo/pulls/$rp_number/comments" --paginate -q '.[].body' 2>/dev/null || true
      gh api "repos/$rp_owner/$rp_repo/pulls/$rp_number/reviews"  --paginate -q '.[].body' 2>/dev/null || true
    } | grep -oE 'zeus:review-pr id=[a-z0-9-]+' | sed 's/.*id=//' | sort -u | tr '\n' ' ' || true)
  export RP_EXISTING_IDS
  [ -n "${RP_EXISTING_IDS// /}" ] && { echo "post-review: already posted (skipped — handled in-thread or kept in the prior summary, not duplicated):" >&2; echo "  $RP_EXISTING_IDS" >&2; }
fi

python3 - "$PR_FILE" "$ANCHORS_FILE" "$findings" "$mode" "$event" "$REVIEW_FILE" <<'PY'
import sys, json, os

pr      = json.load(open(sys.argv[1]))
anchors = json.load(open(sys.argv[2]))
items   = json.load(open(sys.argv[3]))
mode, event, review_file = sys.argv[4], sys.argv[5], sys.argv[6]

# Re-review dedup: drop findings already posted in an earlier round (set only on
# submit, via RP_EXISTING_IDS). Done before rendering so neither the inline
# comments nor the triage header re-mention them.
_existing = set(os.environ.get("RP_EXISTING_IDS", "").split())
if _existing:
    items = [f for f in items if f.get("id") not in _existing]

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

if mode in ("dry-run", "self"):
    print("="*72)
    if mode == "self":
        where = (f"branch {pr.get('title') or '(detached)'} @ {pr.get('head_sha','')[:12]} vs {pr.get('base','')}"
                 if pr.get("local") else f"PR #{pr.get('number')} @ {pr.get('head_sha','')[:12]}")
        print(f"SELF-REVIEW (my work) — read-only, nothing posted. {pr.get('owner')}/{pr.get('repo')} {where}")
        print("Findings are handed back for you to fix; review-pr never edits.")
    else:
        print(f"PEER DRY RUN — nothing posted. PR {pr.get('owner')}/{pr.get('repo')}#{pr.get('number')} @ {pr.get('head_sha','')[:12]}")
        print("Add --submit to post this review to the PR.")
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
  # Dedup already happened pre-render (RP_EXISTING_IDS). Post one review IFF there
  # is something NEW — an empty review (all findings already posted, prior threads
  # handled in-thread) is skipped rather than posted blank.
  n_inline=$(jq '.comments | length' "$REVIEW_FILE")
  n_summary=$(jq -r '.body' "$REVIEW_FILE" | grep -c 'zeus:review-pr id=' || true)
  if [ "$n_inline" -eq 0 ] && [ "$n_summary" -eq 0 ]; then
    echo "post-review: no new findings to post — earlier comments are handled in-thread (resolve-thread.sh); nothing duplicated." >&2
  else
    gh api "repos/$(jq -r .owner "$PR_FILE")/$(jq -r .repo "$PR_FILE")/pulls/$(jq -r .number "$PR_FILE")/reviews" \
      --input "$REVIEW_FILE" && echo "post-review: review posted." >&2
  fi
fi

# Record the head we just reviewed as the delta base for the NEXT re-review (0b).
# Written for a completed review — self (my work, handed back) and peer submit —
# but NOT a peer dry-run (a preview, not a review: a later real pass of the SAME
# head must still see the full diff, not an empty delta). Persists across runs
# ($REVIEWED_HEAD_FILE is excluded from cleanup_run_state).
if [ "$mode" = "self" ] || [ "$mode" = "submit" ]; then
  head_sha=$(jq -r '.head_sha // empty' "$PR_FILE" 2>/dev/null || echo "")
  [ -n "$head_sha" ] && printf '%s\n' "$head_sha" > "$REVIEWED_HEAD_FILE"
fi
