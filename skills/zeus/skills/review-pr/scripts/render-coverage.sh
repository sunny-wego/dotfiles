#!/usr/bin/env bash
# render-coverage.sh — reconcile the review's floor → scout → executed decision into
# the shared Coverage block, written to $COVERAGE_FILE.
#
# Inputs (per-run state, written by earlier steps):
#   $SELECT_FILE  select-mode.sh floor: {mode, applicable_handlers, ...}  (the candidates)
#   $SCOUT_FILE   step-3.75 scout:      {live_lenses, tier_per_lens, skipped:[{lens,why}], hotspots}
#   $TESTS_FILE   run-changed-tests.sh: {status, all_passed, groups}      (the cheap oracle)
#
# `ran` = lens ∈ scout.live_lenses; skipped rows = applicable_handlers − live_lenses,
# joined to scout.skipped[].why for the reason. When $SCOUT_FILE is absent (scout
# disabled or a trivial diff), everything in the floor ran at an unstated tier — still
# an honest, useful summary. When $SELECT_FILE is absent, we render nothing.
#
# Output: writes the rendered `<details>` block to $COVERAGE_FILE (empty when
# diagnostics are off or there's nothing to say). Usage: render-coverage.sh  (no args)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: > "$COVERAGE_FILE"
[ -s "$SELECT_FILE" ] || exit 0   # no floor → nothing to reconcile

SYNTH_MODEL="$(config_get review.synthesis_model claude-opus-4-8)"
norm="$(
  SELECT_FILE="$SELECT_FILE" SCOUT_FILE="$SCOUT_FILE" TESTS_FILE="$TESTS_FILE" \
  FINDINGS_FILE="$FINDINGS_FILE" PRIOR_FILE="$PRIOR_FILE" \
  REVIEWED_HEAD_FILE="$REVIEWED_HEAD_FILE" PR_FILE="$PR_FILE" SYNTH_MODEL="${SYNTH_MODEL:-}" python3 <<'PY'
import os, json

def load(path):
    try:
        with open(path) as fh: return json.load(fh)
    except Exception:
        return None

def load_text(path):
    try:
        with open(path) as fh: return fh.read().strip()
    except Exception:
        return ""

floor    = load(os.environ["SELECT_FILE"]) or {}
scout    = load(os.environ.get("SCOUT_FILE", "")) or {}
tests    = load(os.environ.get("TESTS_FILE", "")) or {}
findings = load(os.environ.get("FINDINGS_FILE", "")) or []
prior    = load(os.environ.get("PRIOR_FILE", "")) or []
pr       = load(os.environ.get("PR_FILE", "")) or {}
prev_head = load_text(os.environ.get("REVIEWED_HEAD_FILE", ""))
synth_model = os.environ.get("SYNTH_MODEL", "") or ""

# Did a scout actually run? Its file is present + non-empty only when step 3.75
# spawned one. Absent ⇒ the floor ran as-is; don't attribute the coverage to a
# scout decision that never happened (Tier/Why stay blank, footer says skipped).
scout_ran = bool(scout)

candidates = floor.get("applicable_handlers") or []
mode = floor.get("mode", "single")

# Scout narrowing. Absent scout ⇒ the floor ran as-is (all candidates, no drops).
live    = scout.get("live_lenses")
if live is None: live = list(candidates)
tiers   = scout.get("tier_per_lens") or {}
skipped = { s.get("lens"): (s.get("why") or "") for s in (scout.get("skipped") or []) if s.get("lens") }

# Candidate set = floor ∪ anything the scout kept (defensive; live ⊆ candidates normally).
seen, order = set(), []
for h in list(candidates) + [l for l in live if l not in candidates]:
    if h not in seen: seen.add(h); order.append(h)

def short_tier(m):
    m = (m or "").lower()
    if "opus" in m:   return "opus"
    if "sonnet" in m: return "sonnet"
    if "haiku" in m:  return "haiku"
    return m or None

units = []
for h in order:
    ran = h in live
    units.append({
        "name": h,
        "ran": ran,
        "tier": short_tier(tiers.get(h)) if ran else None,
        "why": ("" if ran else (skipped.get(h) or "not triggered by this diff")),
    })

# Test oracle → one human phrasing coverage.sh turns into a summary flag + footer line.
st = tests.get("status")
if st == "ran":
    ap = tests.get("all_passed")
    tests_str = "passed" if ap is True else ("some failing" if ap is False else "ran")
elif st in ("no_changed_tests", None):
    tests_str = "no changed tests" if st == "no_changed_tests" else None
else:
    # e.g. "skipped" — say WHY, not just that it was skipped. The reason lives in
    # the first group's output_tail ("skipped: <reason>"); surface it, capped.
    reason = ""
    for g in (tests.get("groups") or []):
        ot = (g.get("output_tail") or "").strip()
        if ot:
            reason = ot.split("skipped:", 1)[-1].strip() if "skipped:" in ot else ot
            reason = reason.splitlines()[0][:60]
            break
    tests_str = f"{st} ({reason})" if reason else st

# review-pr hotspots are {file, why}; flatten to display strings.
hotspots = []
for hs in (scout.get("hotspots") or []):
    if isinstance(hs, dict):
        f, w = (hs.get("file") or "").strip(), (hs.get("why") or "").strip()
        hotspots.append(f"{f} ({w})" if f and w else (f or w))
    elif str(hs).strip():
        hotspots.append(str(hs).strip())

ran_n = sum(1 for u in units if u["ran"])

def short_model(m):
    m = (m or "").lower()
    for k in ("opus", "sonnet", "haiku"):
        if k in m: return k
    return m or None

# ---- Extra diagnostics, rendered as their own lines inside the <details> block.
# Each answers a "what did the reviewer NOT do / how deep did it go?" question the
# run/skip table alone leaves silent. All derived from already-staged state files.
notes = []

# (1) What was reviewed vs. excluded — the honest scope line.
rf, rl = floor.get("reviewable_files"), floor.get("reviewable_loc")
ex = floor.get("excluded_files") or 0
if isinstance(rf, int):
    files_note = f"Files: {rf} reviewed"
    if isinstance(rl, int): files_note += f", {rl} LOC"
    if ex: files_note += f" · {ex} excluded (lockfile/generated/vendored)"
    notes.append(files_note)

# (2) Verification depth — reproduced vs. reasoned. The Confirmed/Hypothesis labels
# promise this; state it plainly so the reader can calibrate trust.
if findings:
    c = sum(1 for f in findings if f.get("status") == "confirmed")
    h = sum(1 for f in findings if f.get("status") == "hypothesis")
    n = sum(1 for f in findings if f.get("status") == "nit")
    parts = []
    if c: parts.append(f"{c} confirmed via executed repro")
    if h: parts.append(f"{h} hypothesis (static only)")
    if n: parts.append(f"{n} nit")
    notes.append("Verification: " + (" · ".join(parts) if parts else "—"))
else:
    notes.append("Verification: clean pass — no findings")

# (3) Re-review scope — a non-empty prior set is the skill's own definition of a
# re-review. Say how much was re-checked + the delta base, so a round-2 review
# doesn't read as a fresh full pass.
if prior:
    rr = f"Re-review: {len(prior)} prior comment(s) re-verified against this head"
    head = str(pr.get("head_sha") or "")
    if prev_head and head and prev_head != head:
        rr += f" · new commits since {prev_head[:7]}"
    notes.append(rr)

# (4) Triage — the scout's difficulty read + depth recommendation (only if it ran).
if scout_ran:
    diff = (scout.get("difficulty") or "").strip()
    rec  = (scout.get("recommend") or "").strip()
    if diff or rec:
        notes.append("Triage: " + " → ".join(x for x in (f"{diff} difficulty" if diff else "", rec) if x))

# (5) Reasoning model behind synthesis + central verify (the decisive, not-cheap step).
sm = short_model(synth_model)
if sm:
    notes.append(f"Models: synthesis + verify on {sm}")

out = {
    "skill": "review-pr",
    "unit_noun": "lenses",
    "floor": f"{mode} ({len(candidates)} candidate)" if candidates else mode,
    "selected_note": (
        (f"Scout kept {ran_n} of {len(units)}" if scout_ran else "Scout: skipped — floor lenses used as-is")
        if units else ""
    ),
    "units": units,
    "tests": tests_str,
    "notes": notes,
    "hotspots": [h for h in hotspots if h],
}
print(json.dumps(out))
PY
)"

printf '%s' "$norm" | bash "$SCRIPT_DIR/coverage.sh" - > "$COVERAGE_FILE" || : > "$COVERAGE_FILE"
