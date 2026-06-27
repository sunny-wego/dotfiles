#!/usr/bin/env bash
# repo.sh — the family's git/GitHub repo helpers. SOURCE this (don't execute).
# Defines repo identity + base-branch resolution; sets no shell options and runs no
# top-level code. This is the ONE copy (repo_default_branch used to be duplicated,
# with create-pr's variant fragile offline and the base-branch fallback hard-coding
# main/master in several scripts — both fixed here so Zeus works for ANY default
# branch name: dev, trunk, develop, …).

repo_slug()  { gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null; }
repo_owner() { repo_slug | cut -d/ -f1; }
repo_name()  { repo_slug | cut -d/ -f2; }
current_branch() { git symbolic-ref --short HEAD 2>/dev/null || echo ""; }

# repo_default_branch — resolve the repo's default branch NAME, resilient and
# stack-agnostic:
#   1. gh API (authoritative)               2. origin/HEAD symbolic ref (offline-ok)
#   3. probe common names on origin/local   4. "main" (absolute last resort)
# Never assumes main/master before probing, so a repo whose default is dev/trunk/
# develop resolves correctly.
repo_default_branch() {
  local b
  b="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  for b in main master trunk develop dev; do
    if git rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1 \
       || git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
      printf '%s\n' "$b"; return 0
    fi
  done
  printf '%s\n' "main"   # last resort; everything above failed (no remote, no gh)
}

# default_base_ref — a ref suitable for `git diff <ref>...HEAD` / `git merge-base`,
# preferring the remote-tracking form (origin/<default>) so it reflects the pushed
# base. Used by review-pr's local mode to diff the working branch against its base.
default_base_ref() {
  local b; b="$(repo_default_branch)"
  if git rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1; then
    printf '%s\n' "origin/$b"
  elif git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
    printf '%s\n' "$b"
  else
    printf '%s\n' "origin/$b"   # best guess; merge-base errors clearly if absent
  fi
}
