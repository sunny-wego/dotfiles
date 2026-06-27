#!/usr/bin/env bash
# select-mode.sh — decide single-context vs parallel fan-out, deterministically.
# The skill never makes this call by judgment; this script does, from the diff.
#
# Rule: parallel when reviewable_loc >= LOC_THRESHOLD OR reviewable_files >=
# FILE_THRESHOLD; else single. `reviewable` excludes lockfiles, generated/vendored
# output, and docs — so a 2000-line-lockfile PR with 50 lines of code counts as 50.
# Also emits the candidate handler set (path/keyword heuristics) so fan-out only
# spawns lenses the diff actually triggers, and single-context skips the rest.
#
# Overrides: --deep forces parallel, --single forces single (size ignored).
#
# Reads $DIFF_FILE (written by extract-diff.sh). Output JSON:
#   { mode, override, reviewable_loc, reviewable_files, excluded_files,
#     applicable_handlers, loc_threshold, file_threshold }

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Thresholds come from the unified config (lib/config.sh, sourced via lib.sh):
# repo .git/zeus/config.json > user ~/.config/zeus/config.json > shipped default.
# Env ZEUS_REVIEW_LOC_THRESHOLD / ZEUS_REVIEW_FILE_THRESHOLD override for one-offs.
LOC_THRESHOLD="$(config_get review.loc_threshold 400)"
FILE_THRESHOLD="$(config_get review.file_threshold 8)"
override="none"
for a in "$@"; do
  case "$a" in
    --deep) override="deep" ;;
    --single|--shallow) override="single" ;;
  esac
done
[ -f "$DIFF_FILE" ] || { echo '{"error":"select-mode: missing diff (run extract-diff.sh first)"}' >&2; exit 2; }

python3 - "$DIFF_FILE" "$LOC_THRESHOLD" "$FILE_THRESHOLD" "$override" <<'PY'
import sys, json, re
diff_path, loc_thr, file_thr, override = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

# Paths that don't count toward review weight.
EXCLUDE = [
    r'(^|/)[^/]*\.lock$', r'(^|/)package-lock\.json$', r'(^|/)go\.sum$',
    r'(^|/)(yarn|pnpm)-lock\.[a-z]+$', r'(^|/)(poetry|uv|Cargo|Gemfile)\.lock$',
    r'(^|/)vendor/', r'(^|/)node_modules/', r'(^|/)dist/', r'(^|/)build/',
    r'\.min\.[a-z]+$', r'_pb2\.py$', r'\.pb\.go$', r'(^|/)__snapshots__/', r'\.snap$',
    r'\.(md|mdx|rst|txt)$', r'(^|/)docs/',
]
EXC = [re.compile(p) for p in EXCLUDE]
def excluded(p): return any(e.search(p) for e in EXC)

# Keyword heuristics → candidate handlers (correctness + tests always on for code).
HANDLER_KW = {
    "concurrency-idempotency": r'\b(lock|mutex|async|await|asyncio|thread|goroutine|queue|dedup|idempoten|retry|concurren|transaction|webhook|claim|Promise\.all|atomic|race)\b',
    "resilience": r'\b(try|except|catch|finally|timeout|retr(y|ies)|raise|throw|HTTPException|status_code|5\d\d|fallback|circuit|backoff|cancel)\b',
    "data-migrations": r'\b(CREATE TABLE|ALTER|add_column|drop_column|migrat|schema|Column\(|@Entity|alembic|prisma|flyway|liquibase|index|constraint)\b',
    "api-contract": r'\b(request|response|payload|serialize|deserialize|endpoint|route|@app|@router|@router\.|header|status_code|json\.loads|json\.dumps|pydantic|BaseModel|DTO)\b',
    "security": r'\b(auth|token|secret|password|hmac|signature|crypto|hash|jwt|verify|sanitiz|escape|sql|subprocess|os\.system|eval\(|exec\()\b',
}

cur, reviewable, excluded_files = None, {}, []
add = re.compile(r'^\+(?!\+\+)')
dele = re.compile(r'^-(?!--)')
hunk = re.compile(r'^@@ ')
added_text = {h: [] for h in HANDLER_KW}
code_seen = False

with open(diff_path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.startswith('+++ '):
            p = line[4:].rstrip('\n')
            cur = None if p == '/dev/null' else (p[2:] if p[:2] in ('a/','b/') else p)
            if cur is not None and excluded(cur):
                if cur not in excluded_files: excluded_files.append(cur)
                cur = None
            elif cur is not None:
                reviewable.setdefault(cur, 0)
            continue
        if cur is None: continue
        if add.match(line) or dele.match(line):
            reviewable[cur] += 1
            if add.match(line):
                body = line[1:]
                code_seen = True
                for h, rx in HANDLER_KW.items():
                    if re.search(rx, body, re.I): added_text[h].append(1)

reviewable_loc = sum(reviewable.values())
reviewable_files = len([f for f, n in reviewable.items() if n > 0])

handlers = []
if code_seen:
    handlers += ["correctness", "tests"]            # always, for any code change
for h in ("concurrency-idempotency","resilience","data-migrations","api-contract","security"):
    if added_text[h]: handlers.append(h)
# stable priority order
order = ["correctness","concurrency-idempotency","resilience","data-migrations","api-contract","security","tests"]
handlers = [h for h in order if h in handlers]

if override == "deep":     mode = "parallel"
elif override == "single": mode = "single"
else:
    mode = "parallel" if (reviewable_loc >= loc_thr or reviewable_files >= file_thr) else "single"

print(json.dumps({
    "mode": mode, "override": override,
    "reviewable_loc": reviewable_loc, "reviewable_files": reviewable_files,
    "excluded_files": len(excluded_files),
    "applicable_handlers": handlers,
    "loc_threshold": loc_thr, "file_threshold": file_thr,
}))
PY
