#!/usr/bin/env bash
# refresh.sh — refresh-mode orchestrator for /zeus:create-pr.
#
# Pipeline:
#   1. pr-context.sh refresh <target>   → identify the PR + current branch context
#   2. fetch current PR body            → tmp file
#   3. has-managed-block check          → bail if missing (no-op)
#   4. regenerate machine-owned block   → the caller writes this; refresh.sh
#                                         only handles the splice
#   5. body-sync.sh replace-managed     → produce a refreshed body file
#   6. diff old vs new                  → exit 0 with action=noop when unchanged
#   7. gh pr edit --body-file           → push the update
#
# Steps 4 (regenerate) is the only place the agent must do work — refresh.sh
# accepts the regenerated block as an input file. The remaining steps are
# pure I/O and decision logic that doesn't need an LLM.
#
# Usage:
#   refresh.sh prepare [<target>]
#       Identify the PR and emit a small JSON describing the state of
#       refresh inputs. The agent reads it to know:
#         - .pr_number / .pr_url
#         - .body_file    (current PR body on disk)
#         - .has_managed  (bool — if false, action must be noop)
#       Use this output to decide whether to regenerate the managed block.
#
#   refresh.sh apply <body_file> <managed_block_file> [--pr-number <N>]
#       Splice <managed_block_file> into <body_file> via body-sync.sh, then
#       diff against the original PR body. If identical, prints
#       {action: "noop"} and exits 0. Otherwise edits the PR via
#       `gh pr edit --body-file` and prints {action: "edited", pr_url: …}.
#
# Independence: PRs whose body has no managed block always produce
# {action: "noop", reason: "no managed block"} from `prepare`, exactly like
# today's prose-described refresh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

cmd="${1:?Usage: refresh.sh <prepare|apply> ...}"
shift

case "$cmd" in
  prepare)
    target="${1:-}"
    ctx=$(bash "$SCRIPT_DIR/pr-context.sh" refresh "$target")
    pr_json=$(echo "$ctx" | jq -c '.pr // null')
    if [ "$pr_json" = "null" ]; then
      jq -nc '{action: "noop", reason: "no PR found for current branch/target"}'
      exit 0
    fi

    pr_number=$(echo "$pr_json" | jq -r '.number')
    pr_url=$(echo "$pr_json" | jq -r '.url')
    body=$(echo "$pr_json" | jq -r '.body // ""')

    # Write the current body to a tmp file under STATE_DIR so the caller
    # has a stable path to read from / diff against.
    state_dir="$(git rev-parse --absolute-git-dir)/create-pr"
    mkdir -p "$state_dir"
    body_file="$state_dir/refresh-body-current.md"
    printf '%s' "$body" > "$body_file"

    has_managed=false
    if bash "$SCRIPT_DIR/body-sync.sh" has-managed-block "$body_file"; then
      has_managed=true
    fi

    jq -nc \
      --argjson pr_number "$pr_number" \
      --arg pr_url "$pr_url" \
      --arg body_file "$body_file" \
      --argjson has_managed "$has_managed" \
      '{
        action: "prepared",
        pr_number: $pr_number,
        pr_url: $pr_url,
        body_file: $body_file,
        has_managed: $has_managed
      }'
    ;;

  apply)
    body_file="${1:?body_file required}"
    managed_file="${2:?managed_block_file required}"
    shift 2
    pr_number=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pr-number) pr_number="$2"; shift 2 ;;
        *) echo "refresh.sh apply: unknown flag: $1" >&2; exit 1 ;;
      esac
    done

    if ! bash "$SCRIPT_DIR/body-sync.sh" has-managed-block "$body_file"; then
      jq -nc '{action: "noop", reason: "body has no managed block"}'
      exit 0
    fi

    state_dir="$(git rev-parse --absolute-git-dir)/create-pr"
    mkdir -p "$state_dir"
    new_body_file="$state_dir/refresh-body-new.md"
    bash "$SCRIPT_DIR/body-sync.sh" replace-managed "$body_file" "$managed_file" > "$new_body_file"

    if diff -q "$body_file" "$new_body_file" >/dev/null; then
      jq -nc --arg body "$new_body_file" \
        '{action: "noop", reason: "managed block unchanged", body_file: $body}'
      exit 0
    fi

    # Keep the zeus origin tag present on the refreshed body (idempotent — a no-op
    # when carried over from create; backfills it on a PR that predates the tag).
    bash "$SCRIPT_DIR/watermark.sh" create-pr --in-place "$new_body_file" 2>/dev/null || true

    args=(pr edit)
    [ -n "$pr_number" ] && args+=("$pr_number")
    args+=(--body-file "$new_body_file")
    gh "${args[@]}" >/dev/null

    jq -nc --arg body "$new_body_file" --argjson n "${pr_number:-0}" \
      '{action: "edited", pr_number: $n, body_file: $body}'
    ;;

  *)
    echo "refresh.sh: unknown command: $cmd" >&2
    exit 1
    ;;
esac
