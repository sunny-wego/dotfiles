#!/usr/bin/env bash
# gh-issue.sh — shared GitHub-issue primitives for the issue-maintaining skills
# (propose, investigate). SOURCE this (don't execute); functions only.
#
# The two skills open issues for DIFFERENT shapes — propose is a full publish
# backend (review/ownership/drift gates, state persistence); investigate
# opens lightweight labelled epics + hypothesis/remediation sub-issues — so the
# issue-open itself is deliberately NOT one wrapper. These are the primitives they
# genuinely share, kept in one place so the two don't drift (investigate's number
# parse used to be the weaker `grep -oE '[0-9]+$'`; both use the anchored form now).

# gh_issue_number <url> — the issue number from a `.../issues/N` create URL, or "".
# Anchored on /issues/ so a digit elsewhere in the URL can't be mismatched.
gh_issue_number() {
  printf '%s\n' "$1" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+$' | head -1
}

# ensure_label <label> [description] — create the label if missing (idempotent; a
# pre-existing label or a permission miss is not an error, so callers can always
# create-then-use without a prior existence check).
ensure_label() {
  local label="${1:?ensure_label: label required}" desc="${2-}"
  if [ -n "$desc" ]; then gh label create "$label" --description "$desc" 2>/dev/null || true
  else gh label create "$label" 2>/dev/null || true; fi
}
