# Comment Format

How a finding becomes a posted comment. This file owns **rendering only** — it
never decides what qualifies as a finding (that's the handlers) or whether one is
real (that's `review-contract.md`). Change wording/structure here without
touching criteria.

Design decision this encodes: **post every qualifying finding, but make its
trust level unmissable.** The status label is the entire safety mechanism — it
replaces a draft/gate — so it must be the first thing the reader sees and it must
never overstate confidence.

## The three status labels

| Label | Rendered lead line | Means | Hard precondition |
|---|---|---|---|
| Confirmed | `🔴 **Confirmed — reproduced.**` | The mechanism was reproduced; the evidence block is real output. | `evidence` non-empty (schema rule 1). |
| Hypothesis | `⚪ **Hypothesis — please verify.**` | A concern not reproduced locally; the author should confirm or refute. | `verify` non-empty (schema rule 2). |
| Nit | `🟡 **Nit.**` | Minor; no verification claimed either way. | none |

The label is the **first line** of every comment body. Severity (`high/medium/
low`) is appended in parentheses: `🔴 **Confirmed — reproduced.** (high)`.

## Per-comment anatomy (6 parts, in order)

Render the finding's fields into exactly this shape. Omit a part only if its
field is null (`fix_aside`).

```
🔴 **Confirmed — reproduced.** (high)

{concern}

**Why:** {reasoning}

**Evidence — steps + output (rerun it yourself):**
```
{evidence}
```

**Question:** {question}

_(Fix aside: {fix_aside})_

_via `zeus:review-pr`_
```

For a Hypothesis, the Evidence block is replaced by:

```
**Not reproduced.** To confirm or refute: {verify}
```

`{evidence}` always carries both the ordered reproduction commands and the
literal observed output (schema rule 1), so a Confirmed comment is rerunnable, not
just an assertion.

## Anti-XY rules (enforced in phrasing)

- `concern` leads. It states the observable problem and impact — never the
  proposed fix. If a finding's first sentence is "we should …", it's malformed;
  rewrite to "X happens / can happen, because …".
- `question` asks about the **underlying guarantee or intent**, so the author
  can resolve it by establishing an invariant, not by adopting our fix. Good:
  "what guarantees the reconstructed URL always matches the stored one?" Bad:
  "should we switch to (repo, number)?"
- `fix_aside` is parenthetical and optional. It is never the headline and never
  phrased as a demand.
- Collective voice: "we", not "you". No finger-pointing.

## Inline vs summary

- `anchor != null` and the line validates against `$ANCHORS_FILE` → **inline
  comment** on that line.
- `anchor == null`, or the line is off-diff → the finding goes in the **review
  summary body**, grouped under its status, citing `path:line` in text.

## The review summary body (the triage header)

The review's top-level body always leads with a one-glance triage line, so the
author knows the split before reading a single inline comment:

```
**Review: {N} findings — {c} confirmed, {h} to verify, {n} nits.**

Confirmed findings include reproduction steps. "To verify" findings are concerns
I couldn't reproduce locally — each says how to confirm or refute it.

- 🔴 {title}  ·  `path:line`
- ⚪ {title}  ·  `path:line`
- 🟡 {title}  ·  `path:line`
```

Findings without a valid anchor are then rendered in full beneath this index
(same 6-part anatomy), since they have no inline home.

## The Coverage block (scout diagnostics footer)

After the findings and before the trailing `via` footer, the body carries one
collapsible **Coverage** block — the scout's floor→selected→executed decision made
visible, so a reader sees *what the reviewer chose to run, skip, or down-tier, and
why*. It is rendered by `render-coverage.sh` (→ `$COVERAGE_FILE`, via the shared
`lib/coverage.sh`) and appended by `post-review.sh` unless
`review.show_diagnostics=false`:

```
<details><summary>🔎 Coverage — 3 lenses run, 3 skipped · tests passed</summary>

| Lens | Ran? | Tier | Why |
|---|---|---|---|
| correctness | ✅ | opus | — |
| resilience | ⛔ skipped | — | no error/timeout paths touched |
| security | ⛔ skipped | — | no auth/crypto/untrusted input in diff |

Floor: parallel (6 candidate). Scout kept 3 of 6. Tests: passed.
Hotspots: worker.py (claim/dedup under retry)
</details>
<!-- zeus:review-pr coverage -->
```

- Rows reconcile `select-mode`'s `applicable_handlers` (the recall-safe candidates)
  against the scout's `live_lenses`; each skipped row cites the scout's `skipped[].why`.
- Its marker is `<!-- zeus:review-pr coverage -->` — **not** an `id=` marker, so it is
  invisible to the re-review finding-dedup and never counts as "a finding to post"
  (a review with only a Coverage block and zero findings is still skipped, not posted).
- It renders once per review; on a re-review it reflects that round's delta scope.

## GH review payload

Assemble ONE review (never N standalone comments), via
`POST /repos/{owner}/{repo}/pulls/{number}/reviews`:

```jsonc
{
  "commit_id": "<head_sha>",            // from pr.json — pin to the reviewed head
  "event": "COMMENT",                   // default; REQUEST_CHANGES only on explicit --request-changes
  "body": "<triage header + un-anchored findings>",
  "comments": [
    { "path": "...", "line": 358, "side": "RIGHT", "body": "<6-part body>" }
    // multi-line: add "start_line" + "start_side"
  ]
}
```

Rules:
- `event` defaults to `COMMENT` (published, non-blocking). `REQUEST_CHANGES`
  and `APPROVE` are explicit-only — the skill never auto-blocks a PR.
- Every comment body ends with a hidden marker `<!-- zeus:review-pr id=<id> -->`.
  On a re-review, `post-review.sh` reads existing review comments and skips ids
  already present → idempotent, no duplicate spam.
- Default mode is `--dry-run`: render the whole payload to stdout, post nothing.
  A live post is an explicit opt-in.

## Signature

Every posted comment and the review body carry a visible attribution line, as the
other zeus skills do, so readers know it came from the tool:

```
_via `zeus:review-pr`_
```

It sits just above the hidden `<!-- zeus:review-pr id=… -->` marker in each inline
comment, and as the last line of the review summary body. The visible signature is
for humans; the hidden marker is for idempotent re-review — keep both.

## Style (mirrors address-pr reply style)

- Hyphens or colons. Never em-dashes (—) or en-dashes (–).
- Lead with the label, then the concern. No preamble, no restating the diff.
- Cite a concrete `path:line`, symbol, or SHA wherever applicable.
- Keep each part tight — a comment is a prompt for the author, not an essay.
