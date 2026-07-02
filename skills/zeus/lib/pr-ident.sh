#!/usr/bin/env bash
# pr-ident.sh — the family's single PR/repo/SHA identifier parser. SOURCE this
# (don't execute). Defines resolve_pr / resolve_target; sets no shell options and
# runs no top-level code, so it is safe to source into any `set -euo pipefail`
# script. This is the ONE copy — skills source it from lib.sh instead of carrying
# their own (the copies had already drifted: review-pr added URL support, which is
# now canonical here because it is a harmless superset for the others).
#
# House convention (see AGENTS.md): identifiers are flags, bare positionals are
# tolerated, a repo is ALWAYS one `owner/repo` slug (never split). A bare
# non-slash, non-numeric token is left in REST so a stale split `<owner> <repo>`
# call trips the caller's own usage check loudly instead of misparsing.
#
# resolve_pr "$@" — parse identifiers WITHOUT any network call. Sets globals:
#     PR, REPO_SLUG, OWNER, REPO_NAME, SHA   (any may be "")
#     REST=( … )                             unconsumed args, in order
#   Accepts, in any order: a full PR URL, --pr N|=N (or a bare all-digits token),
#   --repo owner/repo|=form (or a bare '/'-token), --sha|--head-sha X|=form.
#   Under `set -u`, expand REST as "${REST[@]:-}".
resolve_pr() {
  PR=""; REPO_SLUG=""; OWNER=""; REPO_NAME=""; SHA=""; REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)                 PR="${2:?--pr needs a value}"; shift 2 ;;
      --pr=*)               PR="${1#*=}"; shift ;;
      --repo)               REPO_SLUG="${2:?--repo needs a value}"; shift 2 ;;
      --repo=*)             REPO_SLUG="${1#*=}"; shift ;;
      --sha|--head-sha)     SHA="${2:?--sha needs a value}"; shift 2 ;;
      --sha=*|--head-sha=*) SHA="${1#*=}"; shift ;;
      --)                   shift; while [ $# -gt 0 ]; do REST+=("$1"); shift; done ;;
      https://*|http://*)
        if [[ "$1" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
          OWNER="${BASH_REMATCH[1]}"; REPO_NAME="${BASH_REMATCH[2]}"
          REPO_SLUG="$OWNER/$REPO_NAME"; PR="${BASH_REMATCH[3]}"
        else
          echo "resolve: unrecognized PR URL '$1'" >&2; return 2
        fi
        shift ;;
      *)
        if   [ -z "$PR" ] && [[ "$1" =~ ^[0-9]+$ ]];  then PR="$1"
        elif [ -z "$REPO_SLUG" ] && [[ "$1" == */* ]]; then REPO_SLUG="$1"
        else REST+=("$1"); fi
        shift ;;
    esac
  done
  if [ -n "$REPO_SLUG" ] && [[ "$REPO_SLUG" != */* ]]; then
    echo "resolve: --repo must be owner/repo (got '$REPO_SLUG')" >&2; return 2
  fi
  [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  return 0
}

# resolve_target "$@" — like resolve_pr, but defaults REPO_SLUG via `gh` when the
# caller supplied none (for scripts that always need owner/repo).
resolve_target() {
  resolve_pr "$@"
  if [ -z "$REPO_SLUG" ]; then
    REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    [ -n "$REPO_SLUG" ] && { OWNER="${REPO_SLUG%%/*}"; REPO_NAME="${REPO_SLUG#*/}"; }
  fi
  # Return 0 explicitly: the trailing `[ -n "$REPO_SLUG" ]` test above is falsy when no
  # repo resolves, and as the function's last command it would otherwise make
  # resolve_target return 1 — aborting `set -e` callers before their own usage check
  # (exit 2) runs, so a usage error surfaces as a bare exit 1 with no message.
  # resolve_pr ends with an explicit `return 0` for the same reason.
  return 0
}
