#!/usr/bin/env bash
# extract-diff.sh — fetch the PR's unified diff and compute the set of lines that
# can carry an inline review comment. The GitHub reviews API rejects an ENTIRE
# review if any one inline comment points at a line outside the diff, so the
# renderer must validate every anchor against this manifest first.
#
# Writes (under $STATE_DIR, via lib.sh):
#   $DIFF_FILE     the unified diff (gh pr diff)
#   $ANCHORS_FILE  { "<path>": [<RIGHT-side line numbers>], ... }
#                  RIGHT-side anchorable lines = added ('+') and context (' ')
#                  lines, numbered in the new file. These are what `side:RIGHT`
#                  inline comments may target.
#
# Usage: extract-diff.sh --pr <n> --repo <owner/repo>   (also accepts a URL/number)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

resolve_target "$@"
[ -n "$PR" ] && [ -n "$REPO_SLUG" ] || { echo '{"error":"extract-diff.sh needs a PR and repo (URL, or --pr/--repo)"}' >&2; exit 2; }

# Persist PR metadata into STATE_DIR (post-review reads $PR_FILE here). identify-pr
# runs pre-isolation against the launch checkout, so its output never lands in the
# worktree's state dir; extract-diff runs inside the worktree, so it owns this.
gh pr view "$PR" --repo "$REPO_SLUG" \
   --json number,headRefOid,baseRefName,url,title 2>/dev/null \
 | jq --arg owner "${REPO_SLUG%%/*}" --arg repo "${REPO_SLUG#*/}" \
     '{owner:$owner, repo:$repo, number:.number, head_sha:.headRefOid, base:.baseRefName, url:.url, title:.title}' \
 > "$PR_FILE" \
  || { echo "{\"error\":\"gh pr view $PR failed for $REPO_SLUG\"}" >&2; exit 1; }

gh pr diff "$PR" --repo "$REPO_SLUG" > "$DIFF_FILE" 2>/dev/null \
  || { echo "{\"error\":\"gh pr diff $PR failed for $REPO_SLUG\"}" >&2; exit 1; }

python3 - "$DIFF_FILE" > "$ANCHORS_FILE" <<'PY'
import sys, json, re
hunk = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
anchors, path, newline = {}, None, None
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.startswith('+++ '):
            p = line[4:].rstrip('\n')
            path = None if p == '/dev/null' else (p[2:] if p[:2] in ('b/', 'a/') else p)
            newline = None
            continue
        m = hunk.match(line)
        if m:
            newline = int(m.group(1))
            continue
        if path is None or newline is None:
            continue
        tag = line[:1]
        if tag == '+':
            anchors.setdefault(path, []).append(newline); newline += 1
        elif tag == ' ':
            anchors.setdefault(path, []).append(newline); newline += 1
        elif tag == '-':
            pass  # left side only — no new-file line consumed
        # '\' (no-newline marker) and anything else: ignore
print(json.dumps(anchors))
PY

jq -nc --argjson a "$(cat "$ANCHORS_FILE")" \
  '{files: ($a|keys|length), anchorable_lines: ([$a[]|length]|add // 0)}' >&2
echo "$ANCHORS_FILE"
