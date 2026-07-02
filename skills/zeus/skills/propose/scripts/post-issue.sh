#!/usr/bin/env bash
# post-issue.sh — wrap `gh issue create` / `gh issue edit` with optional flags.
#
# Create:
#   post-issue.sh --title "feat(x): …" --body-file draft.md \
#     [--label l] [--assignee u] [--milestone m] [--repo owner/name] [--state f]
#
# Update (amend an existing issue — re-render the whole body from state and edit):
#   post-issue.sh --update <number> --title "…" --body-file draft.md \
#     [--label l] [--repo owner/name] [--state f]
#
# --update switches to `gh issue edit <number>`. The body is a full re-render
# from state (the issue's human-owned zone is the comment thread, not the body),
# so we replace the body wholesale — consistency holds by construction.
#
# --state <file> persists the state JSON under the issue number via state.sh so a
#   later amend can reload it.
#
# Prints the issue URL on success.

set -euo pipefail

title=""; body_file=""; milestone=""; repo=""; update_number=""; state_file=""
comment_number=""; force_amend=""
labels=(); assignees=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --label) labels+=("$2"); shift 2 ;;
    --assignee) assignees+=("$2"); shift 2 ;;
    --milestone) milestone="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --update) update_number="$2"; shift 2 ;;
    --comment) comment_number="$2"; shift 2 ;;
    --force-amend) force_amend="true"; shift ;;
    --state) state_file="$2"; shift 2 ;;
    *) echo "error: unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$body_file" ] || { [ -z "$title" ] && [ -z "$update_number" ] && [ -z "$comment_number" ]; }; then
  echo "usage: post-issue.sh [--update N | --comment N] --title <t> --body-file <path> [--label l] [--repo o/n] [--state f]" >&2
  exit 1
fi
[ -f "$body_file" ] || { echo "error: body file not found: $body_file" >&2; exit 1; }

script_dir="$(cd "$(dirname "$0")" && pwd)"
# Shared helpers via the skill shim (sources lib/gh-issue.sh → gh_issue_number, plus
# lib/state.sh + config) — one source point instead of an ad-hoc deep relative path.
# shellcheck source=./lib.sh
source "$script_dir/lib.sh"

# Sign the issue/RFC body — or, in --comment mode, the disposition comment — with
# the zeus origin tag (idempotent). One call covers all three modes since each
# reads $body_file. The reader-test gate below hashes state, not the body, so this
# does not perturb it. Best-effort: a missing/failed helper leaves the body as-is.
bash "$script_dir/watermark.sh" propose --in-place "$body_file" 2>/dev/null || true

# Reader-test enforcement — the shared gate (publish-contract.md clause 3; extracted
# to review-gate.sh so this backend and confluence.sh can't drift). Destination-
# neutral: it reads only the state. Skipped in --comment mode (the body is appended
# to a human-owned thread, not re-rendered, so no reader test applies).
if [ -z "$comment_number" ] && [ -n "$state_file" ]; then
  bash "$script_dir/review-gate.sh" "$state_file" || exit 1
fi

if [ -n "$comment_number" ]; then
  # ── Comment mode: gh issue comment ──────────────────────────────────
  # Used when the target issue isn't the viewer's own (see ownership gate
  # below) — we leave a comment instead of rewriting someone else's body.
  # The body is appended to the human-owned thread, so none of the body-state
  # persistence / pin tail applies; post and exit.
  args=(issue comment "$comment_number" --body-file "$body_file")
  [ -n "$repo" ] && args+=(--repo "$repo")
  url=$(gh "${args[@]}")
  echo "$url"
  echo "commented on #$comment_number (body untouched)" >&2
  exit 0
fi

if [ -n "$update_number" ]; then
  # ── Ownership gate: refuse to clobber a body that isn't yours ────────
  # An amend re-renders the whole body (below). On an issue you didn't author
  # that overwrites a teammate's text and no other gate catches it. ownership.sh
  # fails safe (mine:false when undetermined); --force-amend is the explicit
  # override for the rare case you really do own the edit (e.g. co-maintained).
  own=$(bash "$script_dir/ownership.sh" "$update_number" ${repo:+--repo "$repo"} 2>/dev/null || echo '{"mine":false,"determined":false}')
  mine=$(printf '%s' "$own" | jq -r '.mine // false')
  if [ "$mine" != "true" ] && [ "$force_amend" != "true" ]; then
    author=$(printf '%s' "$own" | jq -r '.author // "?"')
    viewer=$(printf '%s' "$own" | jq -r '.viewer // "?"')
    det=$(printf '%s' "$own" | jq -r '.determined // false')
    if [ "$det" = "true" ]; then
      echo "post-issue: #$update_number was authored by @$author, not you (@$viewer) — refusing to overwrite its body." >&2
    else
      echo "post-issue: could not confirm ownership of #$update_number — refusing to overwrite its body (fail-safe)." >&2
    fi
    echo "  Leave a comment instead:  post-issue.sh --comment $update_number --body-file <path>" >&2
    echo "  Or, if you really own this edit, re-run with --force-amend." >&2
    exit 1
  fi

  # ── Update mode: gh issue edit ──────────────────────────────────────
  args=(issue edit "$update_number" --body-file "$body_file")
  [ -n "$repo" ] && args+=(--repo "$repo")
  [ -n "$title" ] && args+=(--title "$title")
  for l in "${labels[@]:-}"; do [ -n "$l" ] && args+=(--add-label "$l"); done
  url=$(gh "${args[@]}")
  number="$update_number"
  # Echo WHAT was touched, not just where: the last-chance tripwire for a
  # wrong-target amend that survived confirmation — a mis-update announces
  # itself here instead of being discovered by the issue's owner.
  live_title=$(gh issue view "$number" ${repo:+--repo "$repo"} --json title -q .title 2>/dev/null || echo "")
  echo "$url"
  [ -n "$live_title" ] && echo "updated #$number: $live_title" >&2
else
  # ── Create mode: gh issue create ────────────────────────────────────
  args=(issue create --title "$title" --body-file "$body_file")
  [ -n "$repo" ] && args+=(--repo "$repo")
  [ -n "$milestone" ] && args+=(--milestone "$milestone")
  for l in "${labels[@]:-}"; do [ -n "$l" ] && args+=(--label "$l"); done
  for a in "${assignees[@]:-}"; do [ -n "$a" ] && args+=(--assignee "$a"); done
  url=$(gh "${args[@]}")
  echo "$url"
  number=$(gh_issue_number "$url")
fi

# Best-effort journey handoff write — never block the success path.
# Guard with -f (not -x): scripts are invoked via `bash X.sh`, so the executable
# bit is irrelevant and Write-created scripts are mode 644.
if [ -f "$script_dir/journey.sh" ] && [ -n "$number" ]; then
  bash "$script_dir/journey.sh" write-issue "$number" "$url" "$title" 2>/dev/null || true
fi

# Best-effort state persistence so a later amend can reload the source of truth,
# and pin this issue as the worktree's ACTIVE proposal (the /zeus:propose dispatch
# resume target when invoked with no #N). Both best-effort — never block the post.
if [ -n "$state_file" ] && [ -f "$state_file" ] && [ -f "$script_dir/state.sh" ] && [ -n "$number" ]; then
  bash "$script_dir/state.sh" save "$number" "$state_file" >/dev/null 2>&1 || true
  bash "$script_dir/state.sh" pin "$number" >/dev/null 2>&1 || true
fi
