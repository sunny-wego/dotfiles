#!/usr/bin/env bash
# render.sh — state JSON → post-ready draft body, in one deterministic call.
#
# Wraps the render steps that always run in sequence (scaffold-draft → pin-refs) so
# callers never run them out of order or forget to pin code references. Used by both
# create (compose) and amend (re-render from state). `--format` selects the
# destination:
#
#   github     (default) — the canonical GitHub-issue markdown body.
#   confluence           — the SAME canonical body with the Confluence fixups applied.
#       The destination posts via createConfluencePage with contentFormat:"markdown"
#       (the Atlassian MCP converts server-side), so this does NOT re-implement the
#       section grammar — it renders the one canonical body and applies only what
#       Confluence needs (zero drift from the GitHub render):
#         - strip the `<!-- audit:mention-once: … -->` guard — a GitHub-only audit
#           marker (audit-draft.sh / check.sh) with no meaning on a Confluence page.
#         - strip `<a name="…"></a>` anchors — GitHub anchor syntax; a bare <a name>
#           renders as noise on Confluence (it uses its own anchor macro).
#         - strip <b>/</b> INSIDE a <summary>: <details><summary> becomes a Confluence
#           `expand` macro whose title is PLAIN TEXT, so inline tags would leak
#           literally. Scoped to <summary> lines so real bold (markdown `**`) is safe.
#         - optional --issue-url: prepend a `both`-mode "Tracking issue" backlink.
#         - stamp the `_via `zeus:propose`_` origin watermark at the foot (idempotent).
#           The GitHub path stamps this in post-issue.sh (its post is a script); the
#           Confluence post is an agent MCP call with no script step to hook, so it
#           lands here — the last script before the page is published. Safe every
#           (re-)render: watermark.sh no-ops when present, and Confluence drift is
#           VERSION-based (confluence-drift.sh), so body content never perturbs it.
#       Deliberately NOT touched: ```mermaid fences and <details>/<summary> structure
#       (left verbatim; degrade readably in markdown mode).
#
# Usage: render.sh <state-file> [--format github|confluence] [--sha <sha>]
#                  [--repo <owner/repo>] [--issue-url <url>] [--out <path>]
#   --sha / --repo : forwarded to pin-refs. Derived from issue-context.sh when omitted
#                    (pass them in the create flow — you already have them — to avoid a
#                    second `gh` round-trip).
#   --issue-url    : (confluence) `both`-mode backlink to the canonical GitHub issue.
#   --out          : output path. Defaults to
#                    ${CLAUDE_JOB_DIR}/tmp (or /tmp)/{issue-draft,confluence-body}-<pid>.md
#
# Prints ONLY the output path on stdout (scaffold output goes to the file; pin-refs
# chatter goes to stderr), so callers can `DRAFT=$(render.sh ...)`.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
state="${1:?Usage: render.sh <state-file> [--format github|confluence] [--sha S] [--repo R] [--issue-url U] [--out path]}"; shift || true
format="github"; sha=""; repo=""; issue_url=""; out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format)    format="$2";    shift 2 ;;
    --sha)       sha="$2";       shift 2 ;;
    --repo)      repo="$2";      shift 2 ;;
    --issue-url) issue_url="$2"; shift 2 ;;
    --out)       out="$2";       shift 2 ;;
    *) echo "render.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done
case "$format" in github|confluence) ;; *) echo "render.sh: --format must be github|confluence" >&2; exit 2 ;; esac
[ -f "$state" ] || { echo "render.sh: state file not found: $state" >&2; exit 1; }

# Derive sha/repo once if not supplied — pin-refs needs both, else it's skipped.
if [ -z "$sha" ] || [ -z "$repo" ]; then
  ctx="$(bash "$script_dir/issue-context.sh" 2>/dev/null || echo '{}')"
  [ -z "$sha" ]  && sha="$(printf '%s'  "$ctx" | jq -r '.head_sha // empty' 2>/dev/null || true)"
  [ -z "$repo" ] && repo="$(printf '%s' "$ctx" | jq -r '.repo // empty'     2>/dev/null || true)"
fi

if [ -z "$out" ]; then
  base="${CLAUDE_JOB_DIR:+$CLAUDE_JOB_DIR/tmp}"; base="${base:-/tmp}"
  mkdir -p "$base" 2>/dev/null || true
  name="issue-draft"; [ "$format" = confluence ] && name="confluence-body"
  out="$base/$name-$$.md"
fi

# Canonical markdown render (scaffold-draft → pin-refs) — the single source of truth
# for both destinations. Pin only with both sha+repo; otherwise leave refs verbatim
# (best-effort). pin-refs chatter → stderr.
bash "$script_dir/scaffold-draft.sh" "$state" > "$out"
if [ -n "$sha" ] && [ -n "$repo" ]; then
  bash "$script_dir/pin-refs.sh" "$out" "$sha" "$repo" >&2 || true
fi

if [ "$format" = confluence ]; then
  tmp="$out.tmp"
  {
    # `both`-mode backlink to the canonical GitHub issue, at the very top.
    [ -n "$issue_url" ] && printf '> **Tracking issue:** %s\n\n' "$issue_url"
    # Confluence fixups (markdown mode → storage format) — see the header.
    sed -E \
      -e '/^<!-- audit:mention-once:.*-->$/d' \
      -e 's/<a name="[^"]*"><\/a>//g' \
      -e '/<summary/ s#</?b>##g' \
      "$out"
  } > "$tmp"
  mv "$tmp" "$out"
  # Origin watermark, last (the page is published verbatim from $out). Idempotent +
  # best-effort: a missing/failed helper leaves the body unstamped rather than blocking.
  bash "$script_dir/watermark.sh" propose --in-place "$out" 2>/dev/null || true
fi

echo "$out"
