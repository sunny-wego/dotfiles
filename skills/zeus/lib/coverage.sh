#!/usr/bin/env bash
# coverage.sh — render a scout's run/skip decision as a collapsible Coverage block.
#
# Both review skills run a cheap SCOUT that narrows a deterministic floor, then
# throw the decision away. This renderer turns that decision into one collapsible
# `<details>` footer appended to the posted review — so a reader sees what the
# reviewer chose to run, skip, or down-tier, and WHY. Read-only, unobtrusive.
#
# It is domain-agnostic on purpose: `review-pr` feeds it lenses, `propose` feeds it
# checks/stages. Only the RENDERER is shared (this file, symlinked into each skill's
# scripts/, like watermark.sh) — each skill assembles its own normalized JSON, since
# lenses and stages are genuinely different shapes.
#
# Usage:
#   coverage.sh <normalized.json>     # from a file
#   coverage.sh -                     # from stdin
#   coverage.sh                       # from stdin (same as -)
#
# Normalized input (see the two-layer contract in each skill's SKILL/rfc-mode):
#   { "skill": "review-pr",            # marker id: <!-- zeus:<skill> coverage -->
#     "unit_noun": "lenses",           # plural, for the summary ("4 lenses run")
#     "floor": "parallel (7 candidate)",   # human-readable floor summary (optional)
#     "selected_note": "Scout kept 4",     # one-line narrowing note (optional)
#     "units": [ { "name": "...", "ran": true, "tier": "opus", "why": "..." }, ... ],
#     "tests": "12 passed",            # full test-slice phrasing, or null (optional)
#     "hotspots": ["§4 vs §2 consistency"] }   # optional
#
# Output: the markdown `<details>` block on stdout, ending with the grep-detectable
# marker `<!-- zeus:<skill> coverage -->`. Gated by config `review.show_diagnostics`
# (default true): when off, prints NOTHING and exits 0, so callers can pipe it in
# unconditionally. Any malformed input also yields empty output (never blocks a post).
set -euo pipefail

# Resolve our real location through the symlink chain so config.sh (its sibling in
# lib/) is found whether we're run from lib/ or via a skills/*/scripts/ symlink.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
LIB_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=./config.sh
source "$LIB_DIR/config.sh"

# Gate: honor an explicit disable. `false`/`0`/`no`/`off` (any case) turns it off.
show="$(config_get review.show_diagnostics true)"
case "$(printf '%s' "$show" | tr '[:upper:]' '[:lower:]')" in
  false|0|no|off) exit 0 ;;
esac

src="${1:--}"
if [ "$src" = "-" ]; then input="$(cat)"; else input="$(cat "$src")"; fi
[ -n "${input// /}" ] || exit 0

# The JSON goes via env (not stdin): `python3 -` reads the PROGRAM from the heredoc
# on stdin, so stdin is unavailable for data.
COVERAGE_JSON="$input" python3 - <<'PY' || true
import os, sys, json
try:
    d = json.loads(os.environ["COVERAGE_JSON"])
except Exception:
    sys.exit(0)  # malformed → render nothing, never block a post

skill     = d.get("skill", "review")
noun      = d.get("unit_noun", "lenses")
units     = d.get("units") or []
floor     = (d.get("floor") or "").strip()
sel_note  = (d.get("selected_note") or "").strip()
tests     = d.get("tests")
tests     = tests.strip() if isinstance(tests, str) else None
hotspots  = [h for h in (d.get("hotspots") or []) if str(h).strip()]

ran     = sum(1 for u in units if u.get("ran"))
skipped = sum(1 for u in units if not u.get("ran"))

# Singular column header from the plural noun (lenses→Lens, checks→Check).
if noun.endswith("es") and len(noun) > 3: head = noun[:-2]
elif noun.endswith("s"):                  head = noun[:-1]
else:                                     head = noun
head = head[:1].upper() + head[1:]

# Compact test flag for the summary line (full phrasing goes in the footer).
def tests_flag(t):
    if not t: return ""
    low = t.lower()
    if "fail" in low:                                   return " · tests failing"
    if low in ("no changed tests", "skipped", "none", "n/a"): return ""
    return " · tests passed"

# Singular noun when exactly one ran ("1 lens run", not "1 lenses run").
run_noun = head.lower() if ran == 1 else noun
summary = f"🔎 Coverage — {ran} {run_noun} run, {skipped} skipped{tests_flag(tests)}"

out = [f"<details><summary>{summary}</summary>", ""]
if units:
    out += [f"| {head} | Ran? | Tier | Why |", "|---|---|---|---|"]
    for u in units:
        name = str(u.get("name", "")).strip()
        run  = "✅" if u.get("ran") else "⛔ skipped"
        tier = str(u.get("tier") or "—").strip() or "—"
        why  = str(u.get("why") or "—").strip() or "—"
        if not u.get("ran"): tier = "—"   # a skipped unit ran at no tier
        out.append(f"| {name} | {run} | {tier} | {why} |")
    out.append("")

# Footer paragraph: floor → narrowing note → tests, then hotspots on their own line.
foot = []
if floor:    foot.append(f"Floor: {floor}.")
if sel_note: foot.append(f"{sel_note}.")
if tests:    foot.append(f"Tests: {tests}.")
if foot: out.append(" ".join(foot))
if hotspots: out.append(f"Hotspots: {', '.join(str(h).strip() for h in hotspots)}")

out += ["</details>", f"<!-- zeus:{skill} coverage -->"]
sys.stdout.write("\n".join(out) + "\n")
PY
