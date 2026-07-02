#!/usr/bin/env bash
# journey-marker.sh — read/write a hidden, machine-only "journey" marker embedded
# in a PR body, so a fresh session (new clone/worktree, no .git/journey.json) can
# rehydrate cross-skill context straight from the PR. Vendored byte-identical by
# create-pr and address-pr — keep the two copies in sync when editing either.
#
# The marker is a single HTML comment line — invisible in rendered Markdown:
#   <!-- journey:v1 {"issue":456,"investigation":789,"slack":{"channel":"C..","thread_ts":"..","target":".."}} -->
#
# It lives OUTSIDE create-pr's managed block (appended at the end of the body), so
# `create-pr refresh` — which rewrites only the managed block — preserves it. All
# keys are optional and writes MERGE (a slack write never clobbers .issue). The
# marker holds only WRITE-ONCE / stable facts: issue + investigation linkage and the
# Slack thread coordinates (set once at the initial ping, never changed). Volatile
# state (iteration, reviewed SHA, queues) is NEVER stored here — it is re-derived
# from GitHub every run.
#
# Commands:
#   emit               stdin: JSON object       -> marker line on stdout
#   parse              stdin: PR body text       -> marker JSON (or {} if absent)
#   splice <bodyfile>  stdin: JSON (merged in)   -> new body text on stdout
#   read  <pr> [repo]                            -> marker JSON, with a GitHub-native
#                                                   fallback for .issue (closingIssues)
#   write <pr> [repo]  stdin: JSON (merged in)   -> gh pr edit --body-file (in place)
#
# Independence: every read tolerates an absent marker (-> {}); a fresh session with
# no marker degrades to the GitHub fallback in `read`. gh failures are non-fatal in
# `read` ({}), surfaced (exit 1) in `write`.

set -euo pipefail

MARKER_VERSION=1
# A marker line is `<!-- journey:vN <json> -->`; the payload is everything between
# the version tag and the closing ` -->`. The schema never contains the literal
# "-->", so the greedy match in parse_body/splice is safe.

emit() {
  local json
  json=$(cat)
  printf '<!-- journey:v%s %s -->\n' "$MARKER_VERSION" "$(printf '%s' "$json" | jq -c '.')"
}

# stdin: body text -> the LAST marker's JSON payload, or {} when none/invalid.
parse_body() {
  local payload
  payload=$(tr -d '\r' | sed -nE 's/^<!-- journey:v[0-9]+ (.*) -->[[:space:]]*$/\1/p' | tail -1)
  [ -z "$payload" ] && { echo '{}'; return; }
  printf '%s' "$payload" | jq -c '.' 2>/dev/null || echo '{}'
}

# stdin: JSON to merge -> new body (existing marker removed, merged marker appended).
splice() {
  local bodyfile="$1" incoming existing merged marker_line
  incoming=$(cat)
  existing=$(parse_body < "$bodyfile")
  merged=$(jq -cn --argjson a "$existing" --argjson b "$incoming" '$a * $b')
  marker_line=$(printf '%s' "$merged" | emit)
  # Drop any existing marker line(s) and trailing blank lines, then re-append.
  awk '
    !/^<!-- journey:v[0-9]+ .* -->[ \t]*$/ { lines[++n] = $0 }
    END {
      last = n
      while (last > 0 && lines[last] ~ /^[ \t]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  ' "$bodyfile"
  printf '\n%s\n' "$marker_line"
}

read_pr() {
  local pr="$1" repo="${2:-}" args data body marker gi out
  # shellcheck disable=SC2054  # gh --json field list, one arg
  args=(pr view "$pr" --json body,closingIssuesReferences)
  [ -n "$repo" ] && args+=(--repo "$repo")
  data=$(gh "${args[@]}" 2>/dev/null) || { echo '{}'; return 0; }
  body=$(printf '%s' "$data" | jq -r '.body // ""')
  marker=$(printf '%s' "$body" | parse_body)
  gi=$(printf '%s' "$data" | jq -r '.closingIssuesReferences[0].number // empty')
  out="$marker"
  if [ -n "$gi" ]; then
    out=$(printf '%s' "$out" | jq -c --argjson gi "$gi" 'if (.issue // null) == null then .issue = $gi else . end')
  fi
  printf '%s\n' "$out"
}

write_pr() {
  local pr="$1" repo="${2:-}" incoming btmp body newbody etmp eargs
  incoming=$(cat)
  local vargs=(pr view "$pr" --json body)
  [ -n "$repo" ] && vargs+=(--repo "$repo")
  body=$(gh "${vargs[@]}" --jq '.body // ""' 2>/dev/null) || {
    echo "journey-marker: gh pr view failed for #$pr" >&2; return 1; }
  btmp=$(mktemp "${TMPDIR:-/tmp}/jm-body.XXXXXX")
  printf '%s' "$body" > "$btmp"
  newbody=$(printf '%s' "$incoming" | splice "$btmp")
  rm -f "$btmp"
  etmp=$(mktemp "${TMPDIR:-/tmp}/jm-edit.XXXXXX")
  printf '%s\n' "$newbody" > "$etmp"
  eargs=(pr edit "$pr" --body-file "$etmp")
  [ -n "$repo" ] && eargs+=(--repo "$repo")
  gh "${eargs[@]}" >/dev/null || { rm -f "$etmp"; echo "journey-marker: gh pr edit failed for #$pr" >&2; return 1; }
  rm -f "$etmp"
}

cmd="${1:?Usage: journey-marker.sh <emit|parse|splice|read|write> ...}"
shift || true

case "$cmd" in
  emit)   emit ;;
  parse)  parse_body ;;
  splice) splice "${1:?usage: journey-marker.sh splice <body-file>}" ;;
  read)   read_pr "${1:?usage: journey-marker.sh read <pr> [repo]}" "${2:-}" ;;
  write)  write_pr "${1:?usage: journey-marker.sh write <pr> [repo]}" "${2:-}" ;;
  *) echo "journey-marker.sh: unknown command: $cmd" >&2; exit 2 ;;
esac
