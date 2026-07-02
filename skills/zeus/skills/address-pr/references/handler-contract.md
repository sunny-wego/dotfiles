# Handler Contract

Shared contract for every handler in `handlers/*.md`. Read this once.

## When the orchestrator invokes a handler's Fix section

- **Diagnose and fix only.** Do not commit, push, or watch checks. The orchestrator owns the loop.
- Apply fixes via the Edit tool. For fork PRs or cross-file fixes, cite the correct path in any review reply.
- After fixing, append a single outcome line to the state file (see "Reporting outcomes" below).
- A handler's *diagnosis* may already have been gathered by a parallel `zeus:diagnostician` subagent
  before the handler runs (SKILL.md → Parallel diagnosis, serial application). That changes nothing about
  this contract: the handler still owns **all** file mutations and its **single** outcome append —
  diagnosticians are read-only by construction (no Bash/Edit/Write) and never touch the worktree or the
  state file; they only return the root cause + proposed fix.

## Evaluation verbs

- **FIX** — correctness, security, or stability issues. Verify against actual code before acting.
- **ATTEMPT FIX** — valid but complex, large refactors, ambiguous comments. Never silently decline correctness/stability concerns. Flag in outcome.
- **DECLINE** — style, nitpicks, framework misunderstandings, pre-existing issues, subjective style.
- **ACCEPT ISSUE SUGGESTION** (review handlers only) — if the comment asks whether to open a follow-up issue, reply "Yes, please open an issue to track this." and resolve. Do NOT attempt the underlying concern.
- **SKIP** (check handlers only) — infrastructure failures, flaky tests, function-size limits. Flag in outcome.
- **LAST RESORT: `AskUserQuestion`** — only when a fix requires business/infrastructure context not in the code.

## Verification protocol (required before DECLINE on correctness/security)

1. **Find the definition** — LSP "go to definition" (Grep fallback) to locate the actual implementation.
2. **Trace wrappers** — error-handling bugs live in wrappers that conflate failure modes.
3. **Verify data flow** — follow the value end-to-end; correct in isolation ≠ correct in context.

If you can't complete all three → default to ATTEMPT FIX.

## Review-reply and thread-resolve rules (review handlers only)

- Reply to every inline comment via `scripts/reply-to-comments.sh` (batch call, one invocation).
- Reply to a `conversation_comments` item by queuing `queue-review-body-reply` **with its `source_id`** — the flush auto-prepends `@author` (resolved from `source_id`) so the reply names who it answers and triggers the reviewer. Without `source_id` it posts a context-free top-level comment addressed to no one, and bot reviewers (which only act on an @mention) won't respond. Don't hand-type the @mention; just pass `source_id`.
- Resolve every thread you addressed (fixed, declined, accepted-issue, already-addressed) via `scripts/resolve-threads.sh` (batch call, one invocation).
- After every acted-on comment (inline or conversation), queue a `+1` reaction via `state.sh queue-reaction` so the post-push flush adds a 👍 to the original comment. Review-submission bodies are skipped — the GitHub Reactions API does not support them.
- Threads never auto-resolve. Exit is gated on a ground-truth re-fetch, not on internal counts: any thread still `isResolved=false` at the end of the Fix section is recorded in `outcome.unresolved`.

### Queue payloads (exact shapes — don't guess)

Each `state.sh queue-*` command takes a specific JSON shape; the `state.sh` guards reject crossed routes, but pass the right shape the first time:

| Command | Payload | Use for |
|---|---|---|
| `queue-reply` | `{"comment_id": <numeric id>, "body": "..."}` | inline-thread reply (the `inline_comments` bucket, or a `threads` comment) |
| `queue-review-body-reply` | `{"body": "...", "source_id": <numeric id>}` | a `reviews` body or a `conversation_comments` item (`source_id` ⇒ auto-`@author`) |
| `queue-resolve` | `<thread_id>` (bare arg, not JSON) | resolving an addressed thread |
| `queue-reaction` | `{"target_type": "inline"\|"issue", "target_id": <numeric id>}` | 👍 on an acted-on comment |

`comment_id` / `target_id` / `source_id` are **numeric REST ids**. For a `threads` comment, that id is the comment's `.databaseId` (now in the fetch payload — no separate `gh api` call needed); for `inline_comments` / `conversation_comments` it's `.id`.

### Four-bucket rule for review-comment fetches

`scripts/fetch-review-comments.sh` returns **four** top-level arrays: `threads`, `reviews`, `inline_comments`, `conversation_comments`. Before declaring "no feedback," every review handler MUST inspect all four. `conversation_comments` (PR top-level comments, not tied to a review) have NO resolve state — they're easy to miss but often contain structured multi-issue review feedback. Only `threads` and `inline_comments` can be resolved; `reviews` bodies and `conversation_comments` require a reply only.

**Per-item shape (read this before writing `jq`).** Across **every** bucket `user` is a **login string** (e.g. `"coderabbitai[bot]"`), never an object — `.user.login` will fail; use `.user`. Common fields everywhere: numeric REST `id`, `user`, `body`, `created_at`, `updated_at`. Bucket extras:

| Bucket | Extra fields | Resolvable? | Reply via |
|---|---|---|---|
| `threads[].comments[]` | `databaseId` (REST id — use for replies), `path`, `line` | yes (`queue-resolve <thread id>`) | `queue-reply` with `comment_id: .databaseId` |
| `inline_comments` | `path`, `line`, `in_reply_to_id`, `diff_hunk` | yes | `queue-reply` with `comment_id: .id` |
| `reviews` | `state`, `commit_id`, `submitted_at` | no | `queue-review-body-reply` with `source_id: .id` |
| `conversation_comments` | — | no | `queue-review-body-reply` with `source_id: .id` |

Use `scripts/review-digest.sh <reviews.json>` as the first inspection pass. The digest is a compact triage surface with counts, consistency state, metadata, excerpts, and flags for suggestion blocks / AI prompts. Read full comment bodies from the original payload only for digest items that are actionable or ambiguous.

### Reply style (review handlers only)

Every reply body posted by a review handler MUST:

- Use hyphens (`-`) or colons (`:`). Never em-dashes (`—`) or en-dashes (`–`).
- Lead with the outcome verb: `Fixed`, `Not addressing`, `Deferred`, or `Yes, please open an issue to track this`.
- Cite a concrete reference where applicable: `path/to/file.ts:LINE`, function name, or commit SHA. Skip references only when truly not applicable (e.g. a yes/no answer).
- Stay 1-3 short sentences. No restating the reviewer's comment, no preamble.

Use the literal token `{{SHA}}` anywhere the body should cite the just-pushed short SHA. The orchestrator substitutes it after `commit-and-push.sh` lands the commit, so replies cite a SHA that actually exists on the remote. Examples: `"Fixed at {{SHA}}: extracted helper at src/auth/session.ts:42."`, `"> [reply to @coderabbitai`s review]\n\nFixed at {{SHA}}: null-guard added at src/api/booking.ts:118."`. For review-body replies, only the `[reply to @…]` header is `>`-prefixed; keep the reply body unquoted so GitHub doesn't render the whole comment as one blockquote.

**Post-push timing.** Review handlers queue replies/resolves via `state.sh queue-reply` / `queue-review-body-reply` / `queue-resolve` rather than posting inline. `commit-and-push.sh` flushes the queue *after* a successful push (substituting `{{SHA}}`), and surfaces the flush outcome under `.commit.flush` in the orchestrator's JSON. If the push fails, the queue is preserved and no replies hit GitHub — cause precedes effect.

The sign-off line is appended automatically by `reply-to-comments.sh` and `reply-to-review-body.sh`. Do not include it in handler-authored bodies.

## Reporting outcomes

After each handler finishes, append a single JSON outcome to state:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append <handler-name> \
  '{"fixed": N, "declined": N, "skipped": N, "unresolved": [{"path": "...", "line": N, "note": "..."}]}'
```

`report.sh` aggregates these into the final summary. If you skip this step, the final report will under-report.

## Sweep mode (review handlers only)

Called after all checks pass. Same rules, but **also FIX nitpicks and minor suggestions** if they're clear improvements. DECLINE only what truly doesn't affect PR quality.

The orchestrator only enters Sweep mode on a head with **no standing approval** (`evaluate-iteration.sh` rule 1 routes an `approved_at_head` head to Fix mode instead), so sweeping nits here cannot dismiss an approval. Conversely, in standalone `/zeus:address-pr reviews` there is no orchestrator gate — so if the current head already carries a live approval, apply the "Approved head = don't churn" rule from `handlers/reviews.md` (DECLINE nits rather than committing them) yourself.
