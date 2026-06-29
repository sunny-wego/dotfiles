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

# repo_default_branch_git — resolve the default branch NAME with GIT ONLY (no gh, no
# network), resilient and stack-agnostic:
#   1. origin/HEAD symbolic ref   2. probe common names on origin/local   3. "main"
# Never assumes main/master before probing, so a repo whose default is dev/trunk/
# develop resolves correctly. This is the offline core; repo_default_branch layers
# the authoritative gh lookup on top.
repo_default_branch_git() {
  local b
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  for b in main master trunk develop dev; do
    if git rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1 \
       || git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
      printf '%s\n' "$b"; return 0
    fi
  done
  # Pure guess — gh (if tried), origin/HEAD, and the name-probe all failed. Surface it
  # so a wrong base isn't used silently (the old per-skill copies aborted here instead).
  echo "repo.sh: could not determine the default branch; assuming 'main'" >&2
  printf '%s\n' "main"
}

# repo_default_branch — authoritative resolution: gh API first (catches a renamed
# remote default that a stale origin/HEAD would miss), falling back to the git-only
# core when gh is absent/offline.
repo_default_branch() {
  local b
  b="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
  [ -n "$b" ] && { printf '%s\n' "$b"; return 0; }
  repo_default_branch_git
}

# _base_ref_for <default-branch-name> — turn a branch name into a ref suitable for
# `git diff <ref>...HEAD` / `git merge-base`, preferring the remote-tracking form
# (origin/<default>) so it reflects the pushed base.
_base_ref_for() {
  local b="$1"
  if git rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null 2>&1; then
    printf '%s\n' "origin/$b"
  elif git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
    printf '%s\n' "$b"
  else
    printf '%s\n' "origin/$b"   # best guess; merge-base errors clearly if absent
  fi
}

# default_base_ref — gh-authoritative base ref (remote/peer-review use).
default_base_ref()     { _base_ref_for "$(repo_default_branch)"; }
# default_base_ref_git — GIT-ONLY base ref (no network). Used by review-pr's local
# pre-PR mode so an author reviewing uncommitted work offline never blocks on gh.
default_base_ref_git() { _base_ref_for "$(repo_default_branch_git)"; }
