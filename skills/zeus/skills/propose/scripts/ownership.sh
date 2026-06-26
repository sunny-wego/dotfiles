#!/usr/bin/env bash
# ownership.sh — decide whether an existing issue is the viewer's OWN to amend.
#
# WHY: an amend re-renders the whole body (post-issue.sh --update replaces it
# wholesale). On an issue you didn't open that's clobbering a teammate's authored
# text — invisible to the drift gate (which compares an issue to its own body) and
# to the reader-test gate (which only checks the rendered draft). So before any
# --update we ask a separate question: is this MINE? If not, the skill leaves a
# comment instead of editing the body.
#
# "Mine" = the issue author's login equals the authenticated gh viewer's login
# (case-insensitive — GitHub logins are). Assignment does NOT count: being assigned
# a teammate-filed issue doesn't make its body yours to rewrite. The SAME gate
# applies to a Confluence page (parity): a page authored by a teammate is theirs —
# amend yours, footer-comment on theirs.
#
# Fail-safe: if either identity can't be determined (lookup error, no auth), we
# report mine:false + determined:false so the caller REFUSES the amend rather than
# risking a clobber. Always exits 0 — the caller decides what to do with the verdict.
#
# Two modes:
#   GitHub   — ownership.sh <number> [--repo <owner/name>]
#              fetches issue author + gh viewer login itself (network via gh).
#   Compare  — ownership.sh --author <id> --viewer <id>
#              compares two pre-fetched identities, NO network. Used for Confluence
#              (the agent fetches the page authorId via getConfluencePage and the
#              viewer accountId via atlassianUserInfo, then passes both) — bash can't
#              call the Atlassian MCP, so the network half is the agent's, the
#              comparison half is here.
# Output: {"number":N|null,"author":"…","viewer":"…","mine":bool,"determined":bool}

set -euo pipefail

number=""; repo=""; author_in=""; viewer_in=""; compare=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)   repo="$2"; shift 2 ;;
    --author) author_in="$2"; compare=1; shift 2 ;;
    --viewer) viewer_in="$2"; compare=1; shift 2 ;;
    *) number="$1"; shift ;;
  esac
done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ "$compare" -eq 1 ]; then
  # Pre-fetched identities (Confluence): compare only, no network.
  author="$author_in"; viewer="$viewer_in"
else
  [ -n "$number" ] || { echo "usage: ownership.sh <number> [--repo owner/name]  |  ownership.sh --author <id> --viewer <id>" >&2; exit 2; }
  view=(issue view "$number" --json author)
  [ -n "$repo" ] && view+=(--repo "$repo")
  author=$(gh "${view[@]}" -q '.author.login' 2>/dev/null || echo "")
  viewer=$(gh api user -q .login 2>/dev/null || echo "")
fi

if [ -n "$author" ] && [ -n "$viewer" ]; then
  determined=true
  [ "$(lower "$author")" = "$(lower "$viewer")" ] && mine=true || mine=false
else
  determined=false; mine=false
fi

jq -nc --argjson n "${number:-null}" --arg a "$author" --arg v "$viewer" \
  --argjson mine "$mine" --argjson det "$determined" \
  '{number:$n, author:$a, viewer:$v, mine:$mine, determined:$det}'
