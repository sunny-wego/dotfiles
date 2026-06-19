#!/usr/bin/env bash
# ready-slack-message.sh — turn a `ready-for-review.sh` verdict into a Slack
# message envelope the agent can pass straight to the Slack MCP tool.
#
# This script does NOT send to Slack. MCP tools are agent-side; only the
# agent can call `slack_send_message` / `slack_send_message_draft`. This
# script is the formatting + dedup layer (same pattern as
# merge-conflict-prompts.sh for AskUserQuestion text).
#
# Usage:
#   ready-slack-message.sh <pr_number> [<owner/repo>]
#       Runs ready-for-review.sh internally and emits the envelope below.
#
#   ready-slack-message.sh --from <ready-json-file>
#       Skip the probe; build the envelope from a previously-captured
#       readiness JSON. Useful when step 5 already ran the probe.
#
#   ready-slack-message.sh --from-stdin
#       Read the readiness JSON from stdin.
#
# Flags:
#   --pr <n> / --repo <owner/repo>   identify the PR (also accepted positionally).
#   --from <file> / --from-stdin     feed a cached readiness verdict (skip the probe).
#
# Recipients: this skill pings the PR's CODEOWNERS only — there is NO single
# primary reviewer. Owners are resolved per changed path (resolve-reviewers.sh:
# pending review requests, else CODEOWNERS-by-path) and mentioned in the message.
#
# Output (JSON envelope):
#   {
#     "should_send":   true | false,
#     "skip_reason":   "not_ready" | "already_pinged_at_<sha>" | null,
#     "channel":       "C0ABAK2NKQR",        # channel ID from $SLACK_REVIEW_CHANNEL (caller-supplied)
#     "text":          "<mrkdwn message>",
#     "head_sha":      "<sha to stamp on send>",
#     "pr_url":        "<url>",
#     "pr_number":     <n>,
#     "reviewers":     [ {gh_login, display, …}, … ]   # the resolved code owners
#   }
#
# Agent contract:
#   1. Capture this envelope.
#   2. If `should_send == true`, call slack_send_message (or
#      slack_send_message_draft) with `channel` and `text`.
#   3. After the send returns OK, call:
#        review-thread.sh set <pr> <head_sha> [--thread-ts <ts>] [--channel <id>]
#      so the next probe knows to skip (and a re-review can thread under it).
#
# Independence:
#   - Missing review-thread.sh / no stamped SHA → no dedup, should_send mirrors
#     the readiness verdict.
#   - SLACK_REVIEW_CHANNEL supplies the channel (callers set it from the repo's
#     auto-ping policy). No channel ⇒ exit 3 with a configuration hint — there
#     is no baked-in default destination.
#   - --from / --from-stdin let callers feed in cached readiness JSON
#     without re-running the probe (saves a few `gh` calls).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/slack-envelope.sh"   # review_gate_base (shared with re-review-message.sh)

# Channel resolution: the caller passes SLACK_REVIEW_CHANNEL (typically from the
# repo's auto-ping policy, `auto-ping.sh … .channel`). There is deliberately NO
# baked-in fallback channel — a published skill must not silently route messages
# to a hardcoded destination. No channel ⇒ explicit error below, telling the
# caller to configure the repo (auto-ping.sh enable) or set the env var.
DEFAULT_CHANNEL="${SLACK_REVIEW_CHANNEL:-}"

ready_json=""
mode="probe"
pr=""
repo=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) ready_json=$(cat "$2"); mode="cached"; shift 2 ;;
    --from-stdin) ready_json=$(cat); mode="cached"; shift ;;
    --pr) pr="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | head -n -1 | sed 's/^# \{0,1\}//' >&2
      exit 0
      ;;
    *)
      if [ -z "$pr" ]; then pr="$1"
      elif [ -z "$repo" ]; then repo="$1"
      else
        echo "ready-slack-message: unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

# If we weren't fed a readiness JSON, run the probe. Capture stdout + exit
# code separately: exit 1 still prints valid JSON (not ready), and we want
# to surface that as `should_send=false skip_reason=not_ready` — only exit
# 2 (probe failure) is fatal here.
if [ "$mode" = "probe" ]; then
  # request-review is verdict-agnostic: it has no arbiter. The caller (e.g.
  # address-pr) computes the verdict and pipes it via --from / --from-stdin.
  if [ ! -x "$SCRIPT_DIR/ready-for-review.sh" ]; then
    echo "ready-slack-message: no local arbiter — pipe a readiness verdict via --from <file> or --from-stdin" >&2
    exit 2
  fi
  if [ -z "$pr" ]; then
    echo "ready-slack-message: <pr_number> required (or use --from / --from-stdin)" >&2
    exit 2
  fi
  args=("$pr")
  [ -n "$repo" ] && args+=("$repo")
  set +e
  ready_json=$(bash "$SCRIPT_DIR/ready-for-review.sh" "${args[@]}" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    echo "ready-slack-message: readiness probe failed (exit 2)" >&2
    exit 3
  fi
fi

# Validate the readiness JSON.
if ! echo "$ready_json" | jq -e . >/dev/null 2>&1; then
  echo "ready-slack-message: invalid readiness JSON" >&2
  exit 2
fi

ready=$(echo "$ready_json"     | jq -r '.ready')
pr_url=$(echo "$ready_json"    | jq -r '.pr_url')
pr_number=$(echo "$ready_json" | jq -r '.pr_number')
title=$(echo "$ready_json"     | jq -r '.title')
head_sha=$(echo "$ready_json"  | jq -r '.head_sha')
issue_url=$(echo "$ready_json" | jq -r '.linked_issue.url // empty')
issue_num=$(echo "$ready_json" | jq -r '.linked_issue.number // empty')

# Channel resolution. No channel => refuse to silently misroute.
channel="$DEFAULT_CHANNEL"
if [ -z "$channel" ]; then
  echo "ready-slack-message: no channel — set SLACK_REVIEW_CHANNEL=<C…>, or configure the repo:" >&2
  echo "  auto-ping.sh enable <owner/repo> --channel <C…> [--mode send|draft|ask] [--re-review]" >&2
  exit 3
fi

# Dedup. Best-effort: a missing review-thread.sh just means no dedup.
last_sha=""
if [ -x "$SCRIPT_DIR/review-thread.sh" ]; then
  last_sha=$(bash "$SCRIPT_DIR/review-thread.sh" sha "$pr_number" 2>/dev/null || echo "")
fi

should_send=true
skip_reason="null"

# Shared ready-gate + per-SHA dedup (same decision re-review-message.sh uses).
case "$(review_gate_base "$ready" "$last_sha" "$head_sha")" in
  not_ready) should_send=false; skip_reason='"not_ready"' ;;
  already:*) should_send=false; skip_reason="\"already_pinged_at_${last_sha:0:7}\"" ;;
esac

# Resolve the PR's code owners → Slack mentions (resolve-reviewers.sh: pending
# review requests, else CODEOWNERS-by-changed-path). This is the ONLY recipient
# model — there is no configured primary reviewer. Best-effort: a probe failure
# leaves an empty set and the message still posts (to the channel, no mention).
reviewers='[]'
args=("$pr_number")
[ -n "$repo" ] && args+=("$repo")
set +e
reviewers=$(bash "$SCRIPT_DIR/resolve-reviewers.sh" "${args[@]}" 2>/dev/null)
set -e
if ! echo "$reviewers" | jq -e 'type == "array"' >/dev/null 2>&1; then
  reviewers='[]'
fi

# The owners LEAD the message — they are the reviewers. Space-joined mentions
# (individuals as <@U…>, usergroups as <!subteam^S…>, unmapped as GH links).
owners_mention=$(echo "$reviewers" | jq -r '[.[] | .display] | join(" ")')

# Build the Slack mrkdwn text. Angle-bracket links render as clickable labels.
text=$(jq -nr \
  --argjson n "$pr_number" \
  --arg url "$pr_url" \
  --arg title "$title" \
  --arg issue_url "$issue_url" \
  --arg issue_num "$issue_num" \
  --arg mentions "$owners_mention" \
  '
    ":eyes: " + (if $mentions != "" then $mentions + " " else "" end) +
    "please review and approve — <\($url)|#\($n) \($title)>" +
    (if $issue_num != "" then " (spec <\($issue_url)|#\($issue_num)>)" else "" end)
  ')

# Sign the ping with the zeus origin tag (idempotent). Renders as italic in Slack
# mrkdwn; best-effort, so a missing/failed helper leaves the text unchanged.
text="$(printf '%s' "$text" | bash "$SCRIPT_DIR/watermark.sh" request-review - 2>/dev/null || printf '%s' "$text")"

jq -nc \
  --argjson should_send "$should_send" \
  --argjson skip_reason "$skip_reason" \
  --arg channel "$channel" \
  --arg text "$text" \
  --arg head_sha "$head_sha" \
  --arg pr_url "$pr_url" \
  --argjson pr_number "$pr_number" \
  --argjson reviewers "$reviewers" \
  '{
    should_send: $should_send,
    skip_reason: $skip_reason,
    channel: $channel,
    text: $text,
    head_sha: $head_sha,
    pr_url: $pr_url,
    pr_number: $pr_number,
    reviewers: $reviewers
  }'
