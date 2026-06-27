#!/usr/bin/env bash
# lock.sh — the family's advisory file locks. SOURCE this (don't execute). Defines
# with_lock / acquire_lock; sets no shell options and runs no top-level code. This
# is the ONE copy (four byte-identical with_lock copies used to live in the skills).
#
# Both are mkdir-based (atomic), steal a dead holder's lock (PID check), and clean
# up via an EXIT trap, so a short-lived script invocation acquires once and releases
# when it exits.

# with_lock <lock_dir> — block until the lock is held, then take it. A ~5s timeout
# (50 × 0.1s) steals a presumed-dead lock so a holder that died without cleanup
# can't deadlock the family. Use around a read-modify-write of shared state.
with_lock() {
  local lock="$1" i=0 pid=""
  while ! mkdir "$lock" 2>/dev/null; do
    pid=""; [ -f "$lock/pid" ] && pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$lock"; continue; fi
    i=$((i + 1)); [ "$i" -ge 50 ] && { rm -rf "$lock"; continue; }
    sleep 0.1
  done
  echo $$ > "$lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" EXIT
}

# acquire_lock <lock_dir> — non-blocking: take the lock or, if a LIVE holder owns
# it, exit 1 with a message (used by address-pr to refuse a second concurrent run
# in the same worktree). A dead holder's lock is stolen.
acquire_lock() {
  local lock="$1"
  if mkdir "$lock" 2>/dev/null; then
    echo $$ > "$lock/pid"
    # shellcheck disable=SC2064
    trap "rm -rf '$lock'" EXIT
    return 0
  fi
  local pid=""
  [ -f "$lock/pid" ] && pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "Another run is already active in this worktree (pid $pid). Wait for it to finish or remove $lock." >&2
    exit 1
  fi
  rm -rf "$lock"; mkdir "$lock"; echo $$ > "$lock/pid"
  # shellcheck disable=SC2064
  trap "rm -rf '$lock'" EXIT
}
