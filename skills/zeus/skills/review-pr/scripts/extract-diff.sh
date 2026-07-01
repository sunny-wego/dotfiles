#!/usr/bin/env bash
# extract-diff.sh — produce the diff to review and the set of lines that can carry
# an inline review comment. Two sources, same output shape:
#
#   REMOTE (default): an open PR's diff via `gh pr diff` (reviewer role).
#   LOCAL  (--local):  the current branch's working diff vs its base, NO network —
#                      the pre-PR self-review the author runs before opening a PR.
#
# Writes (under $STATE_DIR, via lib.sh):
#   $PR_FILE       resolved PR/local metadata (uniform fields; .local=true in local mode)
#   $DIFF_FILE     the unified diff
#   $ANCHORS_FILE  { "<path>": [<RIGHT-side line numbers>], ... }  (via diff-anchors.py)
#
# Usage:
#   extract-diff.sh --pr <n> --repo <owner/repo>          # remote: a PR (URL/number ok)
#   extract-diff.sh --local [--base <ref>] [--include-dirty]
#     --base <ref>      base to diff against (default: repo default branch). A REF,
#                       so it is parsed HERE and never routed through the identifier
#                       parser (a ref like release/v1 would misparse as a repo).
#     --include-dirty   include uncommitted/staged changes (default: committed only)
#
#   --since <sha>       RE-REVIEW delta scoping (works with either mode above). In
#                       addition to the full diff+anchors (kept intact — needed for
#                       anchor validity and prior-finding re-verification), write
#                       $DELTA_DIFF_FILE = `git diff <sha> HEAD`, the change since the
#                       last-reviewed head. New-findings diagnosis reads the delta;
#                       posting/anchoring still use the full diff. A <sha> not present
#                       locally is best-effort fetched; if still missing the delta is
#                       skipped (full diff is always written) — never fatal.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- split out the local-mode + delta flags BEFORE resolve_target (refs/shas must not
#     reach the identifier parser); everything else is forwarded to it unchanged. ---
local_mode=false base="" include_dirty=false since=""
fwd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --local)         local_mode=true; shift ;;
    --base)          base="${2:?--base needs a ref}"; shift 2 ;;
    --base=*)        base="${1#*=}"; shift ;;
    --include-dirty) include_dirty=true; shift ;;
    --since)         since="${2:?--since needs a sha}"; shift 2 ;;
    --since=*)       since="${1#*=}"; shift ;;
    *)               fwd+=("$1"); shift ;;
  esac
done

# On a re-review, write $DELTA_DIFF_FILE = the change since the last-reviewed head.
# Called from both the local and remote terminal paths (HEAD is the reviewed head in
# both: the worktree is checked out at the PR head, and local HEAD is the branch tip).
write_delta() {
  [ -n "$since" ] || { rm -f "$DELTA_DIFF_FILE" 2>/dev/null || true; return 0; }
  if ! git cat-file -e "${since}^{commit}" 2>/dev/null; then
    git fetch --quiet origin "$since" 2>/dev/null || true   # best-effort; PR head may predate fetch
  fi
  if git cat-file -e "${since}^{commit}" 2>/dev/null; then
    git diff "$since" HEAD > "$DELTA_DIFF_FILE" 2>/dev/null || : > "$DELTA_DIFF_FILE"
    local n; n=$(awk '/^[+-]/ && !/^(\+\+\+|---)/ {c++} END{print c+0}' "$DELTA_DIFF_FILE")
    echo "{\"delta_since\":\"$since\",\"delta_diff_lines\":$n}" >&2
  else
    rm -f "$DELTA_DIFF_FILE" 2>/dev/null || true
    echo "{\"warn\":\"extract-diff: --since $since not found locally; delta skipped (full diff written)\"}" >&2
  fi
}

# ============================ LOCAL (pre-PR) path ============================
if [ "$local_mode" = true ] || [ -n "$base" ]; then
  head=$(git rev-parse HEAD 2>/dev/null) || { echo '{"error":"extract-diff --local: no HEAD commit"}' >&2; exit 1; }
  branch=$(git branch --show-current 2>/dev/null || echo "")

  # Default base = the repo's default-branch ref, resolved GIT-ONLY (no gh, no network)
  # via default_base_ref_git — local pre-PR review must not block on a gh timeout when
  # the author is offline. Resilient + stack-agnostic (no main/master hardcode).
  [ -z "$base" ] && base="$(default_base_ref_git)"

  mb=$(git merge-base HEAD "$base" 2>/dev/null) \
    || { echo "{\"error\":\"extract-diff --local: base ref '$base' not found (fetch it, or pass --base)\"}" >&2; exit 1; }

  # Synthetic metadata so post-review/select-mode read the same fields as remote.
  # Git-only (the local path stays network-free); slug may be empty if there's no
  # origin remote — harmless, it's cosmetic owner/repo display, not a lookup key.
  slug=$(git remote get-url origin 2>/dev/null | sed -E 's#(\.git)?$##; s#.*[:/]([^/]+/[^/]+)$#\1#' || true)
  owner="${slug%%/*}"; name="${slug#*/}"
  jq -nc --arg o "$owner" --arg r "$name" --arg h "$head" --arg b "$base" --arg t "$branch" \
    '{owner:$o, repo:$r, number:null, head_sha:$h, base:$b, url:"", title:$t, local:true}' > "$PR_FILE"

  # committed-only by default; merge-base → working tree when --include-dirty.
  if [ "$include_dirty" = true ]; then
    git diff "$mb" > "$DIFF_FILE"
  else
    git diff "$mb" HEAD > "$DIFF_FILE"
  fi

  python3 "$SCRIPT_DIR/diff-anchors.py" "$DIFF_FILE" > "$ANCHORS_FILE"
  write_delta
  jq -nc --argjson a "$(cat "$ANCHORS_FILE")" \
    '{files: ($a|keys|length), anchorable_lines: ([$a[]|length]|add // 0), local: true}' >&2
  echo "$ANCHORS_FILE"
  exit 0
fi

# ============================== REMOTE (PR) path =============================
resolve_target "${fwd[@]:-}"
[ -n "$PR" ] && [ -n "$REPO_SLUG" ] || { echo '{"error":"extract-diff.sh needs a PR and repo (URL, or --pr/--repo), or --local"}' >&2; exit 2; }

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

python3 "$SCRIPT_DIR/diff-anchors.py" "$DIFF_FILE" > "$ANCHORS_FILE"
write_delta

jq -nc --argjson a "$(cat "$ANCHORS_FILE")" \
  '{files: ($a|keys|length), anchorable_lines: ([$a[]|length]|add // 0)}' >&2
echo "$ANCHORS_FILE"
