#!/usr/bin/env bash
# slack-thread.sh — Slack-thread <-> PR glue for the Slack-triggered review entry
# point. PURE string/JSON helpers ONLY: it never talks to Slack. The agent makes
# the slack_read_thread / slack_send_message MCP calls — the scripts just parse and
# persist, mirroring request-review's "agent sends, scripts only format" split.
#
# Subcommands:
#   parse <permalink>      stdout: {channel, thread_ts, msg_ts}
#       Decode a Slack message permalink (…/archives/<C>/p<digits>[?thread_ts=…]).
#       thread_ts is the PARENT to reply under (a ?thread_ts= query wins; else the
#       linked message's own ts) so the reply threads correctly; msg_ts is the
#       specific linked message. Pure — no git, no state; safe pre-isolation.
#   extract-pr             stdin: thread text/json -> first GitHub PR URL (exit 3 if none)
#   save --channel C --thread-ts T [--msg-ts M] [--pr-url URL] [--requester SLACK_UID]
#       Persist the coordinate to $SLACK_FILE (in the PR worktree's STATE_DIR). It
#       is EXCLUDED from cleanup_run_state, so it survives across same-session
#       re-reviews — a later "/zeus:review-pr" (no arg) still replies in the thread.
#       --requester is the Slack user id of whoever asked for the review (the `user`
#       of the linked message) — step 6b pings them with <@…>.
#   get                    stdout: $SLACK_FILE, or {} when none.
#
# parse/extract-pr are pre-isolation pure; save/get run INSIDE the PR worktree and
# source lib.sh for $SLACK_FILE.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:?Usage: slack-thread.sh <parse|extract-pr|save|get> ...}"
shift || true

case "$cmd" in
  parse)
    url="${1:?parse needs a Slack message permalink}"
    case "$url" in
      *slack.com/archives/*) : ;;
      *) echo '{"error":"slack-thread parse: not a Slack /archives/ message link"}' >&2; exit 2 ;;
    esac
    rest="${url#*/archives/}"
    channel="${rest%%/*}"                       # path segment after /archives/
    ppart="${rest#*/}"; ppart="${ppart%%\?*}"   # the p<digits> segment, query stripped
    ppart="${ppart%%/*}"
    digits="${ppart#p}"
    case "$digits" in
      ''|*[!0-9]*) echo '{"error":"slack-thread parse: no p<digits> message id in link"}' >&2; exit 2 ;;
    esac
    # Slack ts = the digits with a '.' before the last 6.
    if [ "${#digits}" -le 6 ]; then msg_ts="$digits"
    else msg_ts="${digits:0:${#digits}-6}.${digits: -6}"; fi
    # Reply under the PARENT: a ?thread_ts= query (linked msg is a reply) wins.
    thread_ts="$msg_ts"
    case "$url" in
      *[?\&]thread_ts=*) q="${url#*thread_ts=}"; thread_ts="${q%%[&#]*}" ;;
    esac
    [ -n "$channel" ] || { echo '{"error":"slack-thread parse: no channel id in link"}' >&2; exit 2; }
    jq -nc --arg c "$channel" --arg t "$thread_ts" --arg m "$msg_ts" \
      '{channel:$c, thread_ts:$t, msg_ts:$m}'
    ;;

  extract-pr)
    url="$(cat | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | head -1 || true)"
    [ -n "$url" ] || { echo '{"error":"slack-thread extract-pr: no GitHub PR URL in the linked message/thread"}' >&2; exit 3; }
    printf '%s\n' "$url"
    ;;

  save)
    # shellcheck source=lib.sh
    source "$SCRIPT_DIR/lib.sh"
    channel="" thread_ts="" msg_ts="" pr="" requester=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --channel)   channel="${2:?}"; shift 2 ;;
        --thread-ts) thread_ts="${2:?}"; shift 2 ;;
        --msg-ts)    msg_ts="${2:-}"; shift 2 ;;
        --pr-url)        pr="${2:-}"; shift 2 ;;
        --requester) requester="${2:-}"; shift 2 ;;
        *) echo "slack-thread save: unknown arg $1" >&2; exit 1 ;;
      esac
    done
    [ -n "$channel" ] && [ -n "$thread_ts" ] \
      || { echo "slack-thread save: --channel and --thread-ts required" >&2; exit 1; }
    with_lock "$SLACK_FILE.lock"
    tmp="$SLACK_FILE.tmp.$$"
    jq -nc --arg c "$channel" --arg t "$thread_ts" --arg m "$msg_ts" --arg pr "$pr" --arg rq "$requester" \
      '{channel:$c, thread_ts:$t}
       + (if $m  != "" then {msg_ts:$m}     else {} end)
       + (if $pr != "" then {pr:$pr}        else {} end)
       + (if $rq != "" then {requester:$rq} else {} end)' > "$tmp"
    mv "$tmp" "$SLACK_FILE"
    cat "$SLACK_FILE"
    ;;

  get)
    # shellcheck source=lib.sh
    source "$SCRIPT_DIR/lib.sh"
    [ -f "$SLACK_FILE" ] && cat "$SLACK_FILE" || echo '{}'
    ;;

  *)
    echo "slack-thread.sh: unknown command: $cmd" >&2; exit 1 ;;
esac
