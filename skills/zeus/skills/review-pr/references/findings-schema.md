# Findings Schema

The contract between the two halves of review-pr: **handlers produce findings,
the renderer consumes them.** As long as a finding matches this shape, the
review criteria (`handlers/*.md`) and the output format (`comment-format.md`) can
each be rewritten without touching the other. This file is the only thing both
sides import.

A review run accumulates findings into `$FINDINGS_FILE` (see `lib.sh`) as a JSON
array. Each element:

```json
{
  "id": "dedup-before-process",
  "handler": "concurrency-idempotency",
  "status": "confirmed",
  "severity": "high",
  "title": "Transient failure permanently drops the webhook event",
  "concern": "If run_followup fails transiently on the first delivery we return 502, but the dedup row is already committed, so GitHub's retry is deduped away and the follow-up never fires.",
  "reasoning": "claim_delivery commits at github_webhook.py:357-359 before run_followup; a GitHubReadError becomes a 502 at :414-419.",
  "evidence": "Reproduce (head ca9ac21, throwaway Postgres):\n  1. gh pr checkout 223  # or the worktree at the PR head\n  2. cd zurk/orchestrator && uv sync --extra dev\n  3. createdb rp_<id>; DATABASE_URL=...rp_<id>; alembic upgrade head\n  4. drive the handler: monkeypatch run_followup to raise GitHubReadError, POST /api/webhooks/github twice with the SAME fresh X-GitHub-Delivery\nObserved:\n  [attempt 1] 502 {\"detail\":\"github labels lookup: 503 ...\"}\n  [retry    ] 200 {\"accepted\":false,\"reason\":\"duplicate delivery\"}  ← event lost",
  "verify": null,
  "anchor": { "path": "zurk/orchestrator/src/orchestrator/api/github_webhook.py", "line": 358, "start_line": null, "side": "RIGHT" },
  "question": "When run_followup fails on the first delivery, do we want the event retried or dropped — i.e. is claim-before-process the intended contract here?",
  "fix_aside": "Committing the claim only after success (or returning 200 on the transient failure) would keep the retry alive."
}
```

## Field contract

| Field | Type | Required | Rule |
|---|---|---|---|
| `id` | string (kebab-case) | yes | Stable across re-runs of the same finding. Used as the dedup marker in posted comments (`<!-- zeus:review-pr id=<id> -->`) so a re-review updates rather than duplicates. |
| `handler` | string | yes | The producing dimension (`correctness`, `concurrency-idempotency`, …). Lets the renderer group and the run report tally per handler. |
| `status` | enum | yes | `confirmed` \| `hypothesis` \| `nit`. **The trust signal.** See the hard rules below. |
| `severity` | enum | yes | `high` \| `medium` \| `low`. Orthogonal to status: a finding can be a confirmed-low or a hypothesis-high. |
| `title` | string (≤80) | yes | One-line headline, readable on its own. |
| `concern` | string | yes | The observable problem and its impact — **X, not the fix.** This is the load-bearing sentence (anti-XY). |
| `reasoning` | string | yes | The code path, with `file:line` refs so it's checkable. |
| `evidence` | string | iff `confirmed` | **Reproduction steps + observed output**, so the author can rerun it verbatim. Must contain (a) the ordered commands you ran (native to the repo's stack — see review-contract.md) and (b) the literal output you observed. **A finding may carry `status:confirmed` only if this is non-empty.** |
| `verify` | string \| null | iff `hypothesis` | The exact check the author can run to confirm/refute. Required when `hypothesis`; null otherwise. |
| `anchor` | object \| null | no | `{path, line, start_line, side}` for an inline comment. `null` → the finding is posted in the review summary body instead. `line` is a RIGHT-side line; `start_line` for a multi-line range (else null). |
| `question` | string | yes | One question, asked about the underlying guarantee/intent — never about the proposed fix (anti-XY). |
| `fix_aside` | string \| null | no | A demoted, parenthetical suggestion. Never the headline. |

## Hard rules (enforced by the renderer, not just convention)

1. **`status:confirmed` ⇒ `evidence` non-empty, and contains both steps and
   output.** No evidence, no badge. A reproduction that wasn't captured — or whose
   steps aren't recorded so the author can rerun it — is a hypothesis.
2. **`status:hypothesis` ⇒ `verify` non-empty.** A concern you can't reproduce
   must tell the author how to settle it; otherwise it's noise.
3. **`anchor.line` must be in the diff.** The renderer validates every anchor
   against `$ANCHORS_FILE`; an off-diff anchor is rewritten to `null` (the
   finding moves to the summary body) rather than failing the whole review —
   the GitHub reviews API rejects an entire review if one inline line is
   off-diff.
4. **`id` is stable.** The same finding on a re-review keeps its `id` so the
   posted-comment marker dedups it.

## Validation

`post-review.sh` validates the array against these rules before assembling the
GH review and refuses to post if rules 1–2 are violated (a labeling bug is worse
than a missing comment). Rule 3 is auto-repaired (anchor → summary). Keep this
file and `post-review.sh`'s validator in sync.
