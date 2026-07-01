#!/usr/bin/env python3
# select-mode.py — the review-mode decision, given an extracted diff.
#   argv: <diff-file> <loc-threshold> <file-threshold> <override:none|deep|single>
# Emits the select-mode JSON on stdout (see select-mode.sh for the contract).
# Invoked by select-mode.sh, which resolves the thresholds + override first.
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
