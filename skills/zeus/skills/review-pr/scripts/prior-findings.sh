#!/usr/bin/env bash
# prior-findings.sh — recover THIS skill's previously-posted findings on a PR so a
# re-review can address them (verify fixed vs still-open) instead of ignoring or
# duplicating them. Read-only: it fetches the PR's review threads, keeps the ones
# whose root comment carries our `<!-- zeus:review-pr id=… -->` marker and are not
# already resolved, and emits them.
#
# Output (stdout + $PRIOR_FILE): a JSON array, each element:
#   {id, thread_id, comment_id, prior_status, path, line, outdated, body}
#   - prior_status ∈ {confirmed, hypothesis, nit, unknown} parsed from the label.
#   - thread_id  → resolveReviewThread (resolve-thread.sh --resolve)
#   - comment_id → the root comment's databaseId (reply target)
# An empty array means "first review of this PR" (or every prior thread is already
# resolved) — the caller skips the address stage.
#
# Usage: prior-findings.sh        # reads owner/repo/number from $PR_FILE
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

[ -f "$PR_FILE" ] || { echo "prior-findings: missing $PR_FILE (resolve the PR first)" >&2; exit 2; }
owner=$(jq -r .owner "$PR_FILE"); repo=$(jq -r .repo "$PR_FILE"); number=$(jq -r .number "$PR_FILE")

# A local (pre-PR) diff has no PR to recover comments from → empty.
if [ "$(jq -r '.local // false' "$PR_FILE")" = "true" ] || [ -z "$number" ] || [ "$number" = "null" ]; then
  echo '[]' | tee "$PRIOR_FILE"; exit 0
fi

# --paginate walks every page (a long-lived PR can carry >100 review threads; a
# single page would silently truncate and we'd miss — then re-post — prior findings).
# gh feeds $endCursor between pages as long as the query declares it + pageInfo; -q
# streams each node and `jq -s` slurps the pages back into one array for the parser.
gh api graphql --paginate -f owner="$owner" -f repo="$repo" -F number="$number" -f query='
query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      reviewThreads(first:100, after:$endCursor){
        pageInfo{ hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line originalLine
          comments(first:1){ nodes { databaseId body } }
        }
      }
    }
  }
}' -q '.data.repository.pullRequest.reviewThreads.nodes[]' | jq -s '.' > "$STATE_DIR/_threads.json"

python3 - "$STATE_DIR/_threads.json" "$PRIOR_FILE" <<'PY'
import json, re, sys
threads = json.load(open(sys.argv[1])) or []
MARKER = re.compile(r'zeus:review-pr id=([a-z0-9-]+)')
LABELS = (("confirmed", "Confirmed"), ("hypothesis", "Hypothesis"), ("nit", "Nit"))
out = []
for t in threads:
    if t.get("isResolved"):                 # already closed — nothing to address
        continue
    nodes = (t.get("comments") or {}).get("nodes") or []
    if not nodes:
        continue
    body = nodes[0].get("body") or ""
    m = MARKER.search(body)
    if not m:                               # not one of ours
        continue
    first_line = body.split("\n", 1)[0]
    status = next((k for k, w in LABELS if w in first_line), "unknown")
    out.append({
        "id": m.group(1),
        "thread_id": t["id"],
        "comment_id": nodes[0]["databaseId"],
        "prior_status": status,
        "path": t.get("path"),
        "line": t.get("line") or t.get("originalLine"),
        "outdated": bool(t.get("isOutdated")),
        "body": body,
    })
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(json.dumps(out, indent=1))
PY
rm -f "$STATE_DIR/_threads.json"
