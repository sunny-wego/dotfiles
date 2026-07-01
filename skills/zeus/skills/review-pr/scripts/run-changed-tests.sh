#!/usr/bin/env bash
# run-changed-tests.sh — run the CHANGED-AREA test slice before diagnosis, so the
# reviewer starts from the cheapest, highest-signal oracle: does the repo's own
# suite already cover (and pass on) the risky lines? A passing test that exercises
# a hypothesis's mechanism is a cheap refute; a failing one is a confirmed signal.
#
# Scope: only the test files this review's diff touched, PLUS the conventional
# sibling test of any changed source file (same-dir naming). Never the whole suite.
# Reads the delta diff on a re-review ($DELTA_DIFF_FILE) else the full diff.
#
# Best-effort under review-contract.md's Tier-1 fence: bounded per group by
# review.max_test_seconds, graceful skip on a missing runner / uninstalled deps /
# no throwaway env — never an error, never a blocker. Writes $TESTS_FILE:
#   { status: ran|no_changed_tests|skipped, reason?, all_passed: bool|null,
#     groups: [ {root, stack, runner, test_files, cmd, returncode, passed,
#                output_tail} ] }
#
# Usage: run-changed-tests.sh        # reads $DIFF_FILE / $DELTA_DIFF_FILE via lib.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

enabled="$(config_get review.tests_first true)"
if [ "$enabled" != "true" ]; then
  printf '%s\n' '{"status":"skipped","reason":"review.tests_first=false","all_passed":null,"groups":[]}' | tee "$TESTS_FILE"
  exit 0
fi
MAX_SECS="$(config_get review.max_test_seconds 120)"
# Keep tests-first cheap + infra-free: skip integration/e2e slices (they need a DB /
# services — the "no throwaway env → skip" fence). Overridable per repo.
EXCLUDE_RE="$(config_get review.test_exclude_regex '(^|/)(integration|e2e|end_to_end|functional|acceptance)(/|_)')"

# Prefer the delta scope on a re-review; else the full diff.
SRC_DIFF="$DIFF_FILE"
[ -s "$DELTA_DIFF_FILE" ] && SRC_DIFF="$DELTA_DIFF_FILE"
[ -f "$SRC_DIFF" ] || { printf '%s\n' '{"status":"skipped","reason":"no diff to scan","all_passed":null,"groups":[]}' | tee "$TESTS_FILE"; exit 0; }

# --- Plan: parse changed files → detected (root, stack, test_files) groups. -------
PLAN="$(python3 - "$SRC_DIFF" "$EXCLUDE_RE" <<'PY'
import json, os, re, sys

diff = sys.argv[1]
EXCLUDE = re.compile(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
changed = []
with open(diff, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.startswith("+++ "):
            p = line[4:].rstrip("\n")
            if p == "/dev/null":
                continue
            changed.append(p[2:] if p[:2] in ("a/", "b/") else p)

IS_TEST = {
    "python": re.compile(r"(^|/)(test_[^/]+|[^/]+_test)\.py$"),
    "node":   re.compile(r"\.(test|spec)\.[cm]?[jt]sx?$"),
    "go":     re.compile(r"_test\.go$"),
}
# changed source → conventional same-dir sibling test (only if it exists on disk)
def sibling_tests(path):
    d, b = os.path.split(path)
    stem, ext = os.path.splitext(b)
    cands = []
    if ext == ".py":
        cands = [f"{d}/test_{stem}.py", f"{d}/{stem}_test.py"]
    elif ext in (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cts", ".mts"):
        cands = [f"{d}/{stem}.test{ext}", f"{d}/{stem}.spec{ext}"]
    elif ext == ".go":
        cands = [f"{d}/{stem}_test.go"]
    return [c for c in cands if os.path.isfile(c)]

MANIFESTS = [  # (filename, stack) — nearest ancestor wins
    ("pyproject.toml", "python"), ("setup.cfg", "python"),
    ("setup.py", "python"), ("requirements.txt", "python"),
    ("package.json", "node"), ("go.mod", "go"),
]
def find_root(path):
    d = os.path.dirname(path)
    while True:
        for fn, stack in MANIFESTS:
            if os.path.isfile(os.path.join(d, fn)):
                return d or ".", stack
        parent = os.path.dirname(d)
        if parent == d:
            return None, None
        d = parent

# Collect test files (changed tests + siblings of changed source), minus excludes.
tests = set()
for f in changed:
    if EXCLUDE and EXCLUDE.search(f):
        continue
    stack_hit = next((s for s, rx in IS_TEST.items() if rx.search(f)), None)
    if stack_hit and os.path.isfile(f):
        tests.add(f)
    elif not stack_hit:
        for t in sibling_tests(f):
            if not (EXCLUDE and EXCLUDE.search(t)):
                tests.add(t)

groups = {}  # (root, stack) -> [test files rel to root]
for t in sorted(tests):
    root, stack = find_root(t)
    if not root:
        continue
    # test file's own stack must match the manifest stack
    if not IS_TEST.get(stack, re.compile(r"$^")).search(t):
        continue
    rel = os.path.relpath(t, root)
    groups.setdefault((root, stack), []).append(rel)

out = [{"root": r, "stack": s, "test_files": fs} for (r, s), fs in groups.items()]
print(json.dumps(out))
PY
)"

if [ "$(printf '%s' "$PLAN" | jq 'length')" = "0" ]; then
  printf '%s\n' '{"status":"no_changed_tests","all_passed":null,"groups":[]}' | tee "$TESTS_FILE"
  exit 0
fi

# --- Portable bounded runner (macOS lacks `timeout`; fall back to a watchdog). ----
run_bounded() { # $1=secs; rest=cmd...  → prints combined output; returns rc (124 on timeout)
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@" 2>&1; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@" 2>&1; return $?; fi
  local tmp; tmp="$(mktemp)"
  ( "$@" >"$tmp" 2>&1 ) & local pid=$!
  # Detach the watchdog's fds (>/dev/null 2>&1). Without this it inherits the
  # command-substitution stdout pipe and `out="$(run_bounded …)"` blocks for the
  # full `sleep` even after the child returns — the fd stays open in the sleeper.
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & local wd=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$wd" 2>/dev/null || true          # stop the watchdog if the child won the race
  cat "$tmp"; rm -f "$tmp"; return "$rc"
}

# Build the runner command for a (root, stack); echoes the argv, or nothing to skip.
build_cmd() { # $1=root $2=stack ; remaining=test files (rel)
  local root="$1" stack="$2"; shift 2
  case "$stack" in
    python)
      # Only an ALREADY-installed project venv — never sync/network (the fence).
      if [ -x "$root/.venv/bin/pytest" ]; then echo ".venv/bin/pytest -q -p no:cacheprovider $*"; return; fi
      if [ -x "$root/.venv/bin/python" ]; then echo ".venv/bin/python -m pytest -q -p no:cacheprovider $*"; return; fi
      ;;  # no ready venv → skip (deps not installed)
    node)
      if [ -x "$root/node_modules/.bin/vitest" ]; then echo "node_modules/.bin/vitest run $*"; return; fi
      if [ -x "$root/node_modules/.bin/jest" ];   then echo "node_modules/.bin/jest $*"; return; fi
      ;;  # npm test runs the whole suite → too heavy; skip rather than over-run
    go)
      # unique package dirs of the changed *_test.go files
      local pkgs; pkgs="$(for f in "$@"; do dirname "$f"; done | sort -u | sed 's#^#./#' | tr '\n' ' ')"
      if command -v go >/dev/null 2>&1; then echo "go test $pkgs"; return; fi
      ;;
  esac
  echo ""  # no runner → skip this group
}

results="[]"; any=false; all_passed=true
while read -r g; do
  root="$(printf '%s' "$g" | jq -r .root)"
  stack="$(printf '%s' "$g" | jq -r .stack)"
  files=()  # bash 3.2-safe (no mapfile)
  while IFS= read -r line; do files+=("$line"); done < <(printf '%s' "$g" | jq -r '.test_files[]')
  cmd="$(build_cmd "$root" "$stack" "${files[@]}")"
  if [ -z "$cmd" ]; then
    results="$(jq --arg r "$root" --arg s "$stack" --argjson f "$(printf '%s' "$g" | jq .test_files)" \
      '. + [{root:$r, stack:$s, runner:null, test_files:$f, cmd:null, returncode:null, passed:null, output_tail:"skipped: no direct test runner / deps not installed"}]' <<<"$results")"
    continue
  fi
  any=true
  # errexit-safe: a failing/killed test must NOT abort the whole script (the `||`
  # keeps `set -e` from firing on a non-zero rc). Capture rc via the idiom.
  out="$(cd "$root" && run_bounded "$MAX_SECS" bash -c "$cmd")" && rc=0 || rc=$?
  passed=false; [ "$rc" -eq 0 ] && passed=true
  [ "$passed" = false ] && all_passed=false
  tail_out="$(printf '%s\n' "$out" | tail -n 40)"
  results="$(jq --arg r "$root" --arg s "$stack" --arg c "$cmd" --argjson rc "$rc" \
    --argjson p "$passed" --arg t "$tail_out" --argjson f "$(printf '%s' "$g" | jq .test_files)" \
    '. + [{root:$r, stack:$s, runner:($c|split(" ")[0]), test_files:$f, cmd:$c, returncode:$rc, passed:$p, output_tail:$t}]' <<<"$results")"
done < <(printf '%s' "$PLAN" | jq -c '.[]')

status="ran"; ap="$all_passed"
[ "$any" = false ] && { status="skipped"; ap="null"; }
jq -n --arg st "$status" --argjson ap "$ap" --argjson g "$results" \
  '{status:$st, all_passed:$ap, groups:$g}' | tee "$TESTS_FILE"
