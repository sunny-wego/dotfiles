#!/usr/bin/env bash
# Capture PR snapshots and gate an LLM-only relevance decision after merge conflict resolution.
#
# Usage:
#   check-pr-relevance-llm.sh snapshot <pr_number> <pre|post>
#   check-pr-relevance-llm.sh build-prompt <pr_number> [conflict_files_json|path]
#   check-pr-relevance-llm.sh gate <decision_json|path|-> [threshold]
#
# `gate` expects JSON from the model:
#   {"risk":"low|review","confidence":0..1,"summary":"...","signals":[...],"unexpected_files":[...]}

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'USAGE'
Usage:
  check-pr-relevance-llm.sh snapshot <pr_number> <pre|post>
  check-pr-relevance-llm.sh build-prompt <pr_number> [conflict_files_json|path]
  check-pr-relevance-llm.sh gate <decision_json|path|-> [threshold]
USAGE
  exit 2
}

snapshot_path() {
  local label="$1"
  echo "$STATE_DIR/relevance-$label.json"
}

read_json_input() {
  local arg="$1"

  if [ "$arg" = "-" ]; then
    cat
    return 0
  fi

  if [ -f "$arg" ]; then
    cat "$arg"
    return 0
  fi

  echo "$arg"
}

capture_snapshot() {
  local pr="$1"
  local label="$2"
  local pr_meta files diffstat out snapshot

  if [ "$label" != "pre" ] && [ "$label" != "post" ]; then
    echo "snapshot label must be pre or post" >&2
    exit 1
  fi

  pr_meta=$(gh pr view "$pr" --json number,title,body,baseRefName,headRefName,url)
  files=$(gh pr diff "$pr" --name-only | sed '/^$/d' | jq -R -s 'split("\n") | map(select(length > 0))')
  diffstat=$(gh pr view "$pr" --json files --jq '[.files[] | "\(.path) | +\(.additions) -\(.deletions)"]')
  out=$(snapshot_path "$label")

  snapshot=$(jq -nc \
    --arg label "$label" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson pr "$pr_meta" \
    --argjson files "$files" \
    --argjson diffstat "$diffstat" \
    '{label: $label, generated_at: $generated_at, pr: $pr, files: $files, diffstat: $diffstat}')

  echo "$snapshot" > "$out"

  jq -nc \
    --arg path "$out" \
    --arg label "$label" \
    --argjson file_count "$(echo "$files" | jq 'length')" \
    '{saved: $path, label: $label, file_count: $file_count}'
}

build_prompt() {
  local pr="$1"
  local conflict_arg="${2:-[]}"
  local pre_file post_file pre post conflicts pre_files post_files new_files prompt original_intent body_input

  pre_file=$(snapshot_path pre)
  post_file=$(snapshot_path post)

  if [ ! -f "$pre_file" ] || [ ! -f "$post_file" ]; then
    echo "pre/post snapshots missing. Run snapshot <PR> pre and snapshot <PR> post first." >&2
    exit 1
  fi

  pre=$(cat "$pre_file")
  post=$(cat "$post_file")

  conflicts=$(read_json_input "$conflict_arg")
  if ! conflicts=$(echo "$conflicts" | jq -ec 'if type == "array" then . else [] end' 2>/dev/null); then
    conflicts='[]'
  fi

  if [ -f "$ORIGINAL_INTENT_FILE" ]; then
    original_intent=$(cat "$ORIGINAL_INTENT_FILE")
  else
    body_input=$(mktemp)
    echo "$post" | jq -r '.pr.body // ""' > "$body_input"
    original_intent=$(bash "$SCRIPT_DIR/original-intent.sh" parse "$body_input" 2>/dev/null || echo '{"present": false}')
    rm -f "$body_input"
  fi

  pre_files=$(echo "$pre" | jq -c '.files // []')
  post_files=$(echo "$post" | jq -c '.files // []')
  new_files=$(jq -nc --argjson pre "$pre_files" --argjson post "$post_files" '$post - $pre')

  prompt=$(cat <<'PROMPT'
You are reviewing a pull request after merge-conflict resolution.

Task:
Decide whether the PR still appears relevant to its original intent, or may be polluted by unrelated base-branch changes.

Inputs:
- PR title
- PR body/summary
- Optional Original Intent section with Purpose, Scope, and Non-goals
- Pre-merge changed files (name-only)
- Post-merge changed files (name-only)
- Newly introduced changed files after merge
- Pre diffstat
- Post diffstat
- Conflict files originally resolved

Evaluation rules:
1) Focus on scope relevance, not code style.
2) If Original Intent is present, treat it as the best available statement of intended scope and non-goals.
3) Treat changes as suspicious if they look unrelated to stated PR purpose or clearly cross into stated non-goals.
4) Be conservative: if unsure, mark "review".
5) Do not require certainty; provide best-effort risk judgment from available evidence.

Confidence rubric (0.00 to 1.00):
- 0.90-1.00: very strong evidence
- 0.75-0.89: strong evidence, minor ambiguity
- 0.60-0.74: mixed signals, meaningful uncertainty
- <0.60: weak evidence

Scoring guidance:
- Start at 0.50
- +0.20 if PR purpose/scope is clear from title/body/original intent
- +0.20 if file-level scope strongly supports your judgment
- +0.10 if diff magnitude supports your judgment
- -0.20 if context is missing/ambiguous
- Clamp to [0,1]

Return STRICT JSON only:
{
  "risk": "low" | "review",
  "confidence": 0-1,
  "summary": "one-sentence rationale",
  "signals": [
    "short bullet signal 1",
    "short bullet signal 2"
  ],
  "unexpected_files": ["path1", "path2"]
}
PROMPT
)

  jq -nc \
    --arg prompt "$prompt" \
    --argjson threshold 0.70 \
    --argjson pre "$pre" \
    --argjson post "$post" \
    --argjson new_files "$new_files" \
    --argjson conflict_files "$conflicts" \
    --argjson original_intent "$original_intent" \
    '{
      prompt: $prompt,
      threshold: $threshold,
      inputs: {
        pr_number: $post.pr.number,
        pr_url: $post.pr.url,
        pr_title: $post.pr.title,
        pr_body: ($post.pr.body // ""),
        original_intent: $original_intent,
        base_branch: $post.pr.baseRefName,
        head_branch: $post.pr.headRefName,
        pre_files: ($pre.files // []),
        post_files: ($post.files // []),
        new_files: $new_files,
        pre_diffstat: ($pre.diffstat // []),
        post_diffstat: ($post.diffstat // []),
        conflict_files: $conflict_files
      }
    }'
}

gate_decision() {
  local decision_arg="$1"
  local threshold_raw="${2:-0.70}"
  local threshold decision risk confidence action status reason

  threshold=$(jq -nc --arg t "$threshold_raw" '$t | tonumber? // 0.70')

  decision=$(read_json_input "$decision_arg")
  if ! decision=$(echo "$decision" | jq -ec '{
      risk: (.risk // null),
      confidence: (.confidence // null),
      summary: (.summary // ""),
      signals: (.signals // []),
      unexpected_files: (.unexpected_files // [])
    }
    | select(.risk == "low" or .risk == "review")
    | select((.confidence | type) == "number")
    | .signals |= (if type == "array" then . else [] end)
    | .unexpected_files |= (if type == "array" then . else [] end)' 2>/dev/null); then
    jq -nc '{action: "ask-user", status: "invalid-output", reason: "LLM output malformed; manual confirmation required."}'
    exit 0
  fi

  risk=$(echo "$decision" | jq -r '.risk')
  confidence=$(echo "$decision" | jq -r '.confidence')

  if [ "$risk" = "low" ] && jq -ne --argjson c "$confidence" --argjson t "$threshold" '$c >= $t' >/dev/null; then
    action="auto-continue"
    status="auto-continued"
    reason="risk=low and confidence meets threshold"
  else
    action="ask-user"
    status="review-required"
    if [ "$risk" = "review" ]; then
      reason="model flagged potential PR scope drift"
    else
      reason="confidence below threshold"
    fi
  fi

  jq -nc \
    --arg action "$action" \
    --arg status "$status" \
    --arg reason "$reason" \
    --argjson threshold "$threshold" \
    --argjson decision "$decision" \
    '{action: $action, status: $status, reason: $reason, threshold: $threshold, decision: $decision}'
}

main() {
  if [ "$#" -lt 1 ]; then
    usage
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    snapshot)
      [ "$#" -eq 2 ] || usage
      capture_snapshot "$1" "$2"
      ;;
    build-prompt)
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
      build_prompt "$1" "${2:-[]}"
      ;;
    gate)
      [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
      gate_decision "$1" "${2:-0.70}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
