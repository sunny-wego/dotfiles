#!/usr/bin/env bash
# watermark.sh — sign a zeus-skill message with its origin tag, idempotently.
#
# Every human-facing message a zeus skill originates — a PR body, an issue/RFC
# body, a review reply, an issue comment, a Slack ping — carries a compact
# origin tag so the recipient can see which skill produced it:
#
#     _via `zeus:<skill>`_
#
# The tag is italic in GitHub-flavored Markdown and reads cleanly in Slack
# mrkdwn (which already uses code spans), so one form covers every destination.
# The backticked `zeus:<skill>` token is what makes it both human-legible and
# grep-detectable.
#
# Appending is IDEMPOTENT: a body that already carries this skill's token is
# returned unchanged, so re-renders, amends, managed-block edits, and re-runs
# never double-stamp.
#
# Usage:
#   watermark.sh <skill> <file>            # file content -> watermarked text on stdout
#   watermark.sh <skill> -                 # stdin -> watermarked text on stdout
#   watermark.sh <skill> --in-place <file> # rewrite <file> in place (best-effort)
#   watermark.sh --tag <skill>             # print just the tag line
#
# <skill> is the bare skill name (create-pr, propose, investigate, …); the tag
# renders it as `zeus:<skill>`. Callers degrade gracefully: on any failure the
# original body should be posted unchanged rather than blocked.
set -euo pipefail

if [ "${1:-}" = "--tag" ]; then
  skill="${2:?Usage: watermark.sh --tag <skill>}"
  printf '_via `zeus:%s`_\n' "$skill"
  exit 0
fi

skill="${1:?Usage: watermark.sh <skill> <file|-|--in-place file>}"
src="${2:?source required: a file path, -, or --in-place <file>}"

in_place=false
if [ "$src" = "--in-place" ]; then
  in_place=true
  src="${3:?--in-place needs a file path}"
fi

if [ "$src" = "-" ]; then
  body="$(cat)"
else
  body="$(cat "$src")"
fi

token="\`zeus:${skill}\`"   # the detectable core — identical across destinations
tag="_via ${token}_"

render() {
  case "$body" in
    *"$token"*) printf '%s\n' "$body" ;;            # already signed — leave as-is
    *)          printf '%s\n\n%s\n' "$body" "$tag" ;;
  esac
}

if [ "$in_place" = "true" ]; then
  out="$(render)"
  printf '%s\n' "$out" > "$src"
else
  render
fi
