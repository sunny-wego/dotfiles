#!/usr/bin/env python3
# diff-anchors.py — given a unified diff on argv[1], print
#   { "<path>": [<RIGHT-side line numbers>], ... }
# RIGHT-side anchorable lines = added ('+') and context (' ') lines, numbered in
# the NEW file. These are the lines a `side:RIGHT` inline comment may target; the
# GitHub reviews API rejects an entire review if any inline comment points outside
# the diff, so the renderer validates every anchor against this manifest first.
#
# Shared by extract-diff.sh's PR path AND its --local path so there is exactly ONE
# parser. Works on any unified diff (gh pr diff, git diff) — it never calls out.
import sys, json, re

hunk = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
anchors, path, newline = {}, None, None
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if line.startswith('+++ '):
            p = line[4:].rstrip('\n')
            path = None if p == '/dev/null' else (p[2:] if p[:2] in ('b/', 'a/') else p)
            newline = None
            continue
        m = hunk.match(line)
        if m:
            newline = int(m.group(1))
            continue
        if path is None or newline is None:
            continue
        tag = line[:1]
        if tag == '+':
            anchors.setdefault(path, []).append(newline); newline += 1
        elif tag == ' ':
            anchors.setdefault(path, []).append(newline); newline += 1
        elif tag == '-':
            pass  # left side only — no new-file line consumed
        # '\' (no-newline marker) and anything else: ignore
print(json.dumps(anchors))
