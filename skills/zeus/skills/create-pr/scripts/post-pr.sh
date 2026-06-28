#!/usr/bin/env bash
# post-pr.sh — wrap `gh pr create -F <body-file>` with optional flags and
# best-effort journey state persistence.
#
# Mirrors propose/scripts/post-issue.sh so both ends of the journey
# share the same post-then-record pattern.
#
# Usage:
#   post-pr.sh --title "feat(x): …" --body-file path/to/body.md \
#     [--base <branch>] [--draft] [--label <l>] [--assignee <u>] [--reviewer <u>] \
#     [--repo <owner/name>] [--yes]
#
# --yes is accepted for parity with non-interactive callers but is a no-op
#   here (confirmation happens in the agent, not in this script).
#
# Self-audit chokepoint: refuses to create the PR if validate-pr.sh fails on the
# body (missing required sections), so a malformed body can't publish even when a
# caller bypasses the SKILL's step-2b validate. Mirrors post-issue.sh.
#
# Prints the created PR URL on success. Best-effort writes to
# `.git/journey.json` via journey.sh (if present); never blocks on a
# journey failure.

set -euo pipefail

title=""
body_file=""
base=""
draft=false
labels=()
assignees=()
reviewers=()
repo=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --body-file) body_file="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --draft) draft=true; shift ;;
    --label) labels+=("$2"); shift 2 ;;
    --assignee) assignees+=("$2"); shift 2 ;;
    --reviewer) reviewers+=("$2"); shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --yes) shift ;;
    *) echo "error: unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$title" ] || [ -z "$body_file" ]; then
  echo "usage: post-pr.sh --title <title> --body-file <path> [--base <branch>] [--draft] [--label l] [--assignee u] [--reviewer u] [--repo owner/name]" >&2
  exit 1
fi
if [ ! -f "$body_file" ]; then
  echo "error: body file not found: $body_file" >&2
  exit 1
fi

args=(pr create --title "$title" --body-file "$body_file")
[ -n "$repo" ] && args+=(--repo "$repo")
[ -n "$base" ] && args+=(--base "$base")
[ "$draft" = "true" ] && args+=(--draft)
for l in "${labels[@]:-}"; do
  [ -n "$l" ] && args+=(--label "$l")
done
for a in "${assignees[@]:-}"; do
  [ -n "$a" ] && args+=(--assignee "$a")
done
for r in "${reviewers[@]:-}"; do
  [ -n "$r" ] && args+=(--reviewer "$r")
done

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Chokepoint self-audit (mirrors propose/post-issue.sh refusing an unaudited issue):
# refuse to OPEN a PR whose body fails the required-sections contract — even if a
# caller skipped the SKILL's step-2b validate. validate-pr.sh exits non-zero only on a
# missing required section (its soft warnings don't block) and explains on stderr.
# Runs before any body mutation / push / create, so a malformed body never publishes.
if [ -x "$script_dir/validate-pr.sh" ] && ! bash "$script_dir/validate-pr.sh" "$body_file" >/dev/null; then
  echo "post-pr: refusing to open a PR — body fails validate-pr (see above). Compose a complete body (the /zeus:create-pr render step) and retry." >&2
  exit 1
fi

# Sign the PR description with the zeus origin tag (idempotent). Done BEFORE the
# journey-marker splice so the visible tag lands above the hidden marker (which
# stays last). Best-effort: a missing/failed helper leaves the body untouched.
bash "$script_dir/watermark.sh" create-pr --in-place "$body_file" 2>/dev/null || true

# Embed a hidden journey marker into the body so a fresh session can rehydrate the
# issue/investigation linkage straight from the PR (see journey-marker.sh). Best-effort:
# values come from this worktree's journey.json; a missing marker script or empty
# journey leaves the body untouched. The marker is appended outside the managed
# block, so `create-pr refresh` preserves it.
if [ -x "$script_dir/journey-marker.sh" ] && [ -x "$script_dir/journey.sh" ]; then
  mj='{}'
  ji=$(bash "$script_dir/journey.sh" issue-number 2>/dev/null || true)
  je=$(bash "$script_dir/journey.sh" investigation-epic 2>/dev/null || true)
  [ -n "$ji" ] && mj=$(printf '%s' "$mj" | jq -c --argjson n "$ji" '.issue=$n' 2>/dev/null || printf '%s' "$mj")
  [ -n "$je" ] && mj=$(printf '%s' "$mj" | jq -c --argjson n "$je" '.investigation=$n' 2>/dev/null || printf '%s' "$mj")
  if [ "$mj" != '{}' ]; then
    nb=$(printf '%s' "$mj" | bash "$script_dir/journey-marker.sh" splice "$body_file" 2>/dev/null) \
      && printf '%s\n' "$nb" > "$body_file" || true
  fi
fi

# gh pr create cannot create a PR for a branch with no remote head — it errors
# "you must first push the current branch to a remote". Creating a PR implies
# publishing the branch, so push it first (idempotent): set an upstream if none
# exists, otherwise push only when the local branch is ahead. Surfaced on stderr;
# a push failure aborts (gh can't proceed anyway). Skipped when --repo targets a
# different repo (fork/cross-repo) — the caller owns the head there.
if [ -z "$repo" ]; then
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
    if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      echo "post-pr: branch '$branch' has no upstream; pushing with -u origin" >&2
      git push -u origin "$branch" >&2
    elif [ "$(git rev-list '@{u}..HEAD' --count 2>/dev/null || echo 0)" -gt 0 ]; then
      echo "post-pr: local branch ahead of upstream; pushing" >&2
      git push >&2
    fi
  fi
fi

url=$(gh "${args[@]}")
echo "$url"

# Best-effort journey write — see post-issue.sh for the rationale. A missing
# journey.sh or unparseable URL leaves PR creation entirely unaffected.
number=$(printf '%s\n' "$url" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+$' | head -1)
if [ -x "$script_dir/journey.sh" ] && [ -n "$number" ]; then
  bash "$script_dir/journey.sh" write-pr "$number" "$url" 2>/dev/null || true
fi

# Best-effort: append a Claude Code token-usage + cost footer to the PR body.
# Self-disabling outside Claude Code (no session id) and via CLAUDE_PR_TELEMETRY=0.
# Never blocks PR creation — failures are swallowed inside the script.
if [ -n "$number" ]; then
  telem_args=(--pr "$number")
  [ -n "$repo" ] && telem_args+=(--repo "$repo")
  bash "$script_dir/telemetry.sh" "${telem_args[@]}" 2>/dev/null || true
fi
