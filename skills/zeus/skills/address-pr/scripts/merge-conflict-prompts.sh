#!/usr/bin/env bash
# merge-conflict-prompts.sh — print the canonical AskUserQuestion text for
# the two merge-conflict pause points. Centralizing here means the prompt
# wording can't drift between SKILL.md and what the agent posts.
#
# Usage:
#   merge-conflict-prompts.sh conflicts <base> <files-json>
#       Renders the "Merge conflicts could not be resolved automatically"
#       prompt. <files-json> is a JSON array of paths (output of
#       capture-conflicts.sh).
#
#   merge-conflict-prompts.sh relevance <decision-json>
#       Renders the "Relevance check flagged possible PR drift" prompt.
#       <decision-json> must contain keys: risk, confidence, summary,
#       signals (array), unexpected_files (array).

set -euo pipefail

cmd="${1:?Usage: merge-conflict-prompts.sh <conflicts|relevance> ...}"

case "$cmd" in
  conflicts)
    base="${2:?base branch required}"
    files_json="${3:?conflict files JSON required}"
    {
      printf 'Merge conflicts could not be resolved automatically.\n'
      printf 'Base branch: %s\n' "$base"
      printf 'Unresolved files:\n'
      printf '%s\n' "$files_json" | jq -r '.[] | "- " + .'
      printf 'Reply with one of: continue-manual, stop\n'
    }
    ;;

  relevance)
    decision_json="${2:?decision JSON required}"
    {
      printf 'Relevance check flagged possible PR drift after merge resolution.\n'
      printf '%s\n' "$decision_json" | jq -r '
        "Risk: \(.risk // "unknown")\n" +
        "Confidence: \(.confidence // "unknown")\n" +
        "Summary: \(.summary // "(no summary)")\n" +
        "Signals:\n" +
        ((.signals // []) | map("- " + .) | join("\n")) +
        "\nUnexpected files:\n" +
        ((.unexpected_files // []) | map("- " + .) | join("\n"))
      '
      printf '\nReply with one of: continue, stop\n'
    }
    ;;

  *)
    echo "merge-conflict-prompts.sh: unknown mode: $cmd" >&2
    exit 1
    ;;
esac
