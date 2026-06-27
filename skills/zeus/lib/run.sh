#!/usr/bin/env bash
# run.sh — the family's dry-run command wrapper. SOURCE this (don't execute).
# Defines run(); sets no shell options and runs no top-level code. This is the ONE
# copy (the two skill copies had drifted: investigate's was `set -u`-unsafe and used
# a different prefix). `${DRY_RUN:-0}` is safe under `set -u`.
#
# DRY_RUN=1 prints the command instead of running it — every mutating helper in the
# family honours this so a run can be previewed against a sandbox.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY-RUN: %s\n' "$*" >&2
    return 0
  fi
  "$@"
}
