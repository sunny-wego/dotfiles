#!/usr/bin/env bash
# render-confluence.sh — state JSON → Confluence-ready page body.
#
# The Confluence destination posts via createConfluencePage with
# contentFormat:"markdown" (the Atlassian MCP converts markdown server-side), so
# this does NOT re-implement the section grammar — it calls render.sh for the
# canonical, code-pinned markdown body (one source of truth; zero drift from the
# GitHub render) and applies only the fixups Confluence needs:
#
#   - strip the `<!-- audit:mention-once: … -->` guard — a GitHub-only audit
#     marker (audit-draft.sh / check.sh) with no meaning on a Confluence page.
#   - strip `<a name="…"></a>` HTML anchors — GitHub anchor syntax; Confluence
#     handles anchors via its own macro, and a bare <a name> renders as noise.
#   - optional --issue-url: prepend a "Tracking issue" backlink line (mirror mode,
#     where the GitHub issue stays canonical and the page links back to it).
#
# Deliberately NOT touched:
#   - ```mermaid fences — left verbatim. If the space has a Mermaid macro it
#     renders; otherwise it degrades to a readable code block. Either way the
#     diagram source survives, so this is the least-lossy choice. (A higher-
#     fidelity HTML-mode renderer — expand macros, panels, status lozenges,
#     decision lists — is a deliberate follow-up, not v1.)
#   - <details>/<summary> — supported by Confluence's HTML mode; in markdown mode
#     it degrades to visible content at worst.
#
# Usage:
#   render-confluence.sh <state-file> [--sha <sha>] [--repo <owner/repo>]
#                        [--issue-url <url>] [--out <path>]
#   --sha / --repo : forwarded to render.sh → pin-refs (derived from
#                    issue-context.sh when omitted).
#   --issue-url    : mirror-mode backlink to the canonical GitHub issue.
#   --out          : body path. Defaults to ${CLAUDE_JOB_DIR}/tmp (or /tmp)/confluence-body-<pid>.md
#
# Prints ONLY the body path on stdout, so callers can `BODY=$(render-confluence.sh …)`.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
state="${1:?Usage: render-confluence.sh <state-file> [--sha S] [--repo R] [--issue-url U] [--out path]}"; shift || true
sha=""; repo=""; issue_url=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha)       sha="$2";       shift 2 ;;
    --repo)      repo="$2";      shift 2 ;;
    --issue-url) issue_url="$2"; shift 2 ;;
    --out)       out="$2";       shift 2 ;;
    *) echo "render-confluence.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
[ -f "$state" ] || { echo "render-confluence.sh: state file not found: $state" >&2; exit 1; }

if [ -z "$out" ]; then
  base="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; base="${base:-/tmp}"
  mkdir -p "$base" 2>/dev/null || true
  out="$base/confluence-body-$$.md"
fi

# Canonical markdown render (scaffold-draft → pin-refs), forwarding sha/repo.
md=$(bash "$script_dir/render.sh" "$state" ${sha:+--sha "$sha"} ${repo:+--repo "$repo"})
[ -f "$md" ] || { echo "render-confluence.sh: render.sh produced no body" >&2; exit 1; }

{
  # Mirror-mode backlink to the canonical GitHub issue, at the very top.
  if [ -n "$issue_url" ]; then
    printf '> **Tracking issue:** %s\n\n' "$issue_url"
  fi
  # Confluence fixups (markdown mode → storage format):
  #   - drop the mention-once audit guard (GitHub-only audit marker)
  #   - drop bare <a name> anchors (GitHub anchor syntax)
  #   - strip <b>/</b> INSIDE a <summary>: a <details><summary> becomes a Confluence
  #     `expand` macro whose title is PLAIN TEXT, so inline tags leak literally
  #     (the code-grounding summary uses <b>…</b>; on a page that renders as
  #     `<b>…</b>` characters). Scaffold uses markdown `**` for bold elsewhere, so
  #     scoping the strip to <summary> lines leaves real content untouched.
  sed -E \
    -e '/^<!-- audit:mention-once:.*-->$/d' \
    -e 's/<a name="[^"]*"><\/a>//g' \
    -e '/<summary/ s#</?b>##g' \
    "$md"
} > "$out"

echo "$out"
