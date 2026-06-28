#!/usr/bin/env bash
# resolve-reviewers.sh — resolve a PR's "who should review this?" set to
# Slack-ready mentions.
#
# INDIVIDUAL CODE OWNERS ONLY: @org/team usergroups (subteams) are dropped, so a
# path owned solely by a team resolves to no one. The skill pings the people who
# own the code, not org groups.
#
# Source order (first non-empty wins):
#   1. `gh pr view <pr> --json reviewRequests`
#         → already-resolved pending reviewers (teams are filtered out below)
#   2. .github/CODEOWNERS (or CODEOWNERS / docs/CODEOWNERS)
#         → last-match-wins owner glob, restricted to the PR's changed files
#
# Output:
#   JSON array of:
#     {
#       "gh_login":   "alice-wego",          # bare GitHub login (no @)
#       "is_team":    false,                 # true for "org/team" handles
#       "slack_id":   "U01ALICE" | null,     # null if no map entry
#       "display":    "<@U01ALICE>"          # ready to splice into mrkdwn
#                   | "<https://github.com/alice-wego|@alice-wego>"
#                                            # fallback link, no real mention
#       "source":     "requested" | "codeowners"
#     }
#
# Handle map (Slack ID resolution):
#   File at $SLACK_HANDLE_MAP_FILE (defaults to ~/.claude/slack-handles.json).
#   Schema: { "<gh-login-or-org/team>": "<U-or-S-id>", ... }
#   Missing file or missing entry → display falls back to the GitHub URL.
#
# Independence:
#   - No PR-side data → empty array (the caller decides what to do).
#   - Missing handle map → display still renders (link form).
#   - CODEOWNERS parsing only handles individual `@user` and `@org/team`
#     entries on glob lines. Comments, blanks, and inline `#` comments are
#     stripped. Section markers (`[required]`) are ignored.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"   # resolve_pr/resolve_target (shared identifier parser)

debug=false
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug) debug=true; shift ;;
    *) ARGS+=("$1"); shift ;;   # --pr/--repo + positional <pr> [owner/repo] → resolve_pr
  esac
done

resolve_pr "${ARGS[@]:-}"   # identifiers via the shared parser, not hand-rolled
pr="$PR"; repo="$REPO_SLUG"
if [ "${#REST[@]}" -gt 0 ]; then
  echo "resolve-reviewers: unexpected argument: ${REST[0]}" >&2; exit 2
fi
if [ -z "$pr" ]; then
  echo "usage: resolve-reviewers.sh <pr_number> [<owner/repo>]" >&2
  exit 2
fi

log() { $debug && echo "resolve-reviewers: $*" >&2 || true; }

# --- handle map ----------------------------------------------------------
# Read via handles.sh list (merged view: shipped defaults overlaid by the
# user override in ~/.config/request-review/). Missing or empty map →
# handle_map stays {} and every reviewer renders as a GitHub-link fallback
# (still names them; no @-ping).
script_dir="$(cd "$(dirname "$0")" && pwd)"
handle_map='{}'
if [ -x "$script_dir/handles.sh" ]; then
  if hm=$(bash "$script_dir/handles.sh" list 2>/dev/null); then
    handle_map=$(echo "$hm" | jq -c .)
    log "loaded handle map via handles.sh"
  fi
fi

# --- 1. reviewRequests ---------------------------------------------------
# shellcheck disable=SC2054  # gh --json field list, one arg
pr_args=(pr view "$pr" --json reviewRequests,files)
[ -n "$repo" ] && pr_args+=(--repo "$repo")

if ! pr_json=$(gh "${pr_args[@]}" 2>/dev/null); then
  echo "resolve-reviewers: gh pr view failed for #$pr" >&2
  exit 2
fi

# Normalise reviewRequests. GitHub returns a mix of {login} (user) and
# {name, slug} or {organization, slug} (team). Surface a uniform shape.
requested=$(echo "$pr_json" | jq -c '
  [ (.reviewRequests // [])[]
    | if .login then
        {gh_login: .login, is_team: false}
      elif .slug then
        {gh_login: ((.organization.login // "") + "/" + .slug | sub("^/"; "")), is_team: true}
      else
        empty
      end
  ]
')

requested_count=$(echo "$requested" | jq 'length')
log "reviewRequests: $requested_count entries"

# --- 2. CODEOWNERS fallback ---------------------------------------------
owners='[]'
source_for_fallback="codeowners"
if [ "$requested_count" -eq 0 ]; then
  # Find a CODEOWNERS file. Try the three GitHub-recognised locations in
  # order; first hit wins. gh api returns base64 by default, but the -H
  # Accept header makes it raw.
  codeowners_text=""
  for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    api_repo="$repo"
    if [ -z "$api_repo" ]; then
      api_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
    fi
    [ -z "$api_repo" ] && break
    if text=$(gh api "/repos/$api_repo/contents/$path" -H "Accept: application/vnd.github.raw" 2>/dev/null); then
      codeowners_text="$text"
      log "CODEOWNERS found at $path"
      break
    fi
  done

  if [ -n "$codeowners_text" ]; then
    # Changed file paths from the PR (paginated automatically by gh).
    files=$(echo "$pr_json" | jq -c '[(.files // [])[] | .path]')
    files_count=$(echo "$files" | jq 'length')
    log "PR changed files: $files_count"

    # Parse CODEOWNERS into [{pattern, owners[]}] in original order. We use
    # awk to strip comments + collect owners (tokens starting with @).
    # Note: each token may have @user OR @org/team form. Both are kept; we
    # tag teams in the JSON shape later.
    rules=$(printf '%s\n' "$codeowners_text" | awk '
      {
        # Strip inline comments.
        sub(/[[:space:]]*#.*$/, "")
        # Skip blank / section headers.
        if ($0 ~ /^[[:space:]]*$/) next
        if ($0 ~ /^\[/) next
        # First token is the pattern; the rest are owners.
        n = split($0, t, /[[:space:]]+/)
        if (n < 2) next
        pattern = t[1]
        printf "{\"pattern\":\"%s\",\"owners\":[", pattern
        first = 1
        for (i = 2; i <= n; i++) {
          tok = t[i]
          if (substr(tok, 1, 1) != "@") continue
          # Strip leading @.
          gh = substr(tok, 2)
          if (gh == "") continue
          is_team = (index(gh, "/") > 0) ? "true" : "false"
          if (!first) printf ","
          first = 0
          printf "{\"gh_login\":\"%s\",\"is_team\":%s}", gh, is_team
        }
        printf "]}\n"
      }
    ' | jq -s '.')

    # CODEOWNERS uses last-match-wins semantics. We need a glob → file
    # matcher. Implement minimal fnmatch: supports `*`, `**`, leading `/`,
    # trailing `/`, and prefix matches. Anything fancy falls back to
    # substring containment (best-effort).
    matched_owners=$(jq -n --argjson rules "$rules" --argjson files "$files" '
      def glob_to_regex(p):
        p
        # 1. Escape regex metas we will not interpret. Do this on the raw
        #    pattern before any expansion so we do not double-escape the
        #    metacharacters we are about to introduce.
        | gsub("\\."; "\\.")
        | gsub("\\+"; "\\+")
        | gsub("\\("; "\\(")
        | gsub("\\)"; "\\)")
        # 2. Glob expansion. ** = any depth; * = anything except /.
        #    Use a placeholder for ** so the single-* substitution does not
        #    eat one of its asterisks.
        | gsub("\\*\\*"; "<DSTAR>")
        | gsub("\\*"; "[^/]*")
        | gsub("<DSTAR>"; ".*")
        # 3. Anchor. Absolute patterns (leading /) anchor at start;
        #    relative patterns match anywhere via (^|/).
        | (if startswith("/") then "^" + sub("^/"; "") else "(^|/)" + . end)
        # 4. Trailing / = directory match — also covers everything under it.
        | (if endswith("/") then . + ".*" else . end)
        | . + "$";

      # For each file, find the LAST matching rule. Bind each rule to $rule
      # before the test; otherwise `$f | test(...)` rebinds `.` inside the
      # test argument and `.pattern` would resolve against the file string
      # instead of the rule object.
      ( [ $files[] as $f
          | ( $rules
              | map(. as $rule | select($f | test(glob_to_regex($rule.pattern))))
              | last
            )
          | select(. != null) | .owners[]
        ]
        | unique_by(.gh_login)
      ) // []
    ')

    owners="$matched_owners"
    log "CODEOWNERS resolved: $(echo "$owners" | jq 'length') unique owners"
  else
    log "no CODEOWNERS file found (checked .github/, root, docs/)"
  fi
fi

# --- 3. Combine + apply handle map --------------------------------------
if [ "$requested_count" -gt 0 ]; then
  base="$requested"
  source_tag="requested"
else
  base="$owners"
  source_tag="$source_for_fallback"
fi

result=$(echo "$base" | jq -c \
  --argjson map "$handle_map" \
  --arg source "$source_tag" \
  '
    [ .[] |
      # Ping individual code owners only — never @org/team usergroups (subteams).
      # A path owned solely by a team therefore resolves to no one.
      select(.is_team != true) |
      . as $r
      | ($map[.gh_login] // null) as $sid
      | {
          gh_login: .gh_login,
          is_team: .is_team,
          slack_id: $sid,
          source: $source,
          display: (
            if $sid != null and $sid != "" then
              "<@" + $sid + ">"
            else
              # Fallback: GitHub link with @-prefixed login. No real mention,
              # but reviewers see who is being asked.
              "<https://github.com/" + .gh_login + "|@" + .gh_login + ">"
            end
          )
        }
    ]
  '
)

echo "$result"
