# Reviews Handler

Resolve all unresolved review threads and comments on the PR, regardless of author (bot, human, known or unknown). Classification is **content-driven**: apply the handler-contract verbs based on what the comment says, not who wrote it.

See `references/handler-contract.md` for shared rules (evaluation verbs, verification protocol, reply/resolve rules, outcome reporting).

## Fix

### 1. Fetch

```bash
REVIEWS_FILE="$(git rev-parse --absolute-git-dir)/address-pr/reviews.json"
if ! bash ${CLAUDE_SKILL_DIR}/scripts/fetch-review-comments.sh <PR> <owner/repo> > "$REVIEWS_FILE"; then
  echo "fetch-review-comments failed — aborting handler" >&2
  exit 1
fi
```

The guard is required: a non-zero exit (e.g. ARG_MAX overrun, gh/network error) leaves `$REVIEWS_FILE` empty/missing, and downstream `jq` reads zero-length arrays — which the rest of the handler can't distinguish from "no work to do." Exit non-zero so the orchestrator's `evaluate-iteration.sh` decides next steps rather than the handler silently declaring success.

No `--author` flag — returns all four buckets across every author.

Standalone-mode author filter (optional): when invoked as `/zeus:address-pr reviews <author-substring>`, post-filter the JSON in memory:

```bash
REVIEWS_FILE="$(git rev-parse --absolute-git-dir)/address-pr/reviews.json"
REVIEWS_FILTERED_FILE="$(git rev-parse --absolute-git-dir)/address-pr/reviews.filtered.json"
jq --arg a "<author-substring>" '{
  threads: [.threads[] | select((.comments.nodes[0].user // "") | test($a; "i"))],
  reviews: [.reviews[] | select(.user | test($a; "i"))],
  inline_comments: [.inline_comments[] | select(.user | test($a; "i"))],
  conversation_comments: [.conversation_comments[] | select(.user | test($a; "i"))],
  consistency: .consistency
}' "$REVIEWS_FILE" > "$REVIEWS_FILTERED_FILE"
```

### 2. Build a compact digest, then inspect only needed bodies

```bash
REVIEWS_FILE="$(git rev-parse --absolute-git-dir)/address-pr/reviews.json"
DIGEST_FILE="$(git rev-parse --absolute-git-dir)/address-pr/reviews.digest.json"
bash ${CLAUDE_SKILL_DIR}/scripts/review-digest.sh "$REVIEWS_FILE" > "$DIGEST_FILE"
jq '{counts, consistency, items: [.items[] | {bucket, id, author, path, line, updated_at, body_excerpt, has_suggestion, has_ai_prompt, has_question}]}' "$DIGEST_FILE"
```

| Bucket | What it contains | Resolvable? |
|---|---|---|
| `threads` | Unresolved inline review threads | Yes — `resolve-threads.sh` |
| `reviews` | Review-submission bodies with content (APPROVED / CHANGES_REQUESTED / COMMENTED) | No — reply only |
| `inline_comments` | All inline review comments (use `threads` for unresolved state) | Via `threads` |
| `conversation_comments` | Top-level PR issue comments | No — reply only, no resolve mechanism |

The digest is the token-saving triage surface. It includes counts, consistency, author/path/line metadata, flags for suggestion blocks and AI prompts, and short body excerpts. Read the full `REVIEWS_FILE` body only for digest items that appear actionable or ambiguous.

**Critical:** a reviewer (bot or human) often posts a structured multi-issue review in a single `conversation_comments` body. Checking only `threads.length` under-reports. Exit criteria: **all four** counts are zero AND no digest excerpt indicates an unanswered question or unaddressed actionable. If `.consistency.ok == false`, do not declare the handler clean; append a typed unresolved item and let the orchestrator retry or monitor.

### 3. Evaluate (content-driven, no regex tables)

For every unresolved inline thread, actionable review body, and actionable conversation comment, apply the contract verbs (`FIX` / `ATTEMPT FIX` / `DECLINE` / `ACCEPT ISSUE SUGGESTION` / `SKIP`). Read the comment body and judge by content:

- **Decompose multi-issue bodies.** A single numbered or bulleted comment body often packs 3–10 separate findings. Evaluate each item individually; post one consolidated reply grouped by outcome (Fixed / Not addressing / Deferred).
- **Severity/priority markers are signals, not rules.** Any of these — 🔴 🟠 🔵 🪄 (CodeRabbit), `P1`/`P2`/`P3` (Codex), `[HIGH]`/`[CRITICAL]`/`[LOW]`, `nit:`, `chore:`, `style:`, `question:` — may appear from any reviewer. Use them to weight the decision, but verify by reading the actual concern. In **Fix** mode: FIX high-signal items (correctness, security, stability, bugs); DECLINE pure nits/style/subjective preferences. In **Sweep** mode: also FIX clear-improvement nits.
- **Approved head = don't churn (author-agnostic).** If the PR already carries a live approval covering the current head — any non-author reviewer whose latest review is `APPROVED` at HEAD (`pr-status.sh`'s `approved_at_head`, recomputed from GitHub each pass; no per-reviewer list is kept) — then "generally agreed" already holds: do **NOT** make a code change for a nitpick/style/minor-improvement, because the resulting commit dismisses the approval and forces a re-review. DECLINE those with a one-line reply (or offer a follow-up issue) instead. You still FIX genuine correctness/security/stability blockers, a reviewer's `CHANGES_REQUESTED`, and direct questions — those mean it isn't actually agreed and legitimately supersede the approval. Replies, resolves, and 👍 reactions are always safe; only new commits dismiss an approval. In the main loop the orchestrator enforces this by routing an approved head to Fix mode instead of Sweep (`evaluate-iteration.sh` rule 1); in standalone `/zeus:address-pr reviews` there is no orchestrator, so apply this rule yourself.
- **Suggestion blocks.** When the comment contains a `` ```suggestion `` block, prefer it as the basis for the fix (the reviewer has already written the patch). Still verify against the surrounding code.
- **`Prompt for AI Agents` sections.** `<details><summary>Prompt for AI Agents</summary>…</details>` (CodeRabbit convention, but anyone can use it) contains structured fix guidance — read and incorporate.
- **"Open an issue?" questions.** If the comment asks "Do you want me to open an issue…?" or similar, reply "Yes, please open an issue to track this" and resolve. Do NOT attempt the underlying concern. This is `ACCEPT ISSUE SUGGESTION`.
- **Unanswered questions in APPROVED reviews.** An approving review can still contain a question in its body. Treat as actionable — answer it in a reply.
- **False positives from bots.** If a bot flags a pattern it lacks context for (intentional convention, framework idiom), run the contract's verification protocol (LSP → wrapper trace → data-flow) before declining. Reply with a one-line rationale.
- **Pre-existing / out-of-scope concerns.** DECLINE with a short explanation and, if appropriate, offer to open a follow-up issue.

### 4. Apply + queue (don't post yet)

GitHub's API has three reply paths (inline-threaded, review-body, PR-level), but in this skill all three are **queued** to state. Posting + resolving happens *after* `commit-and-push.sh` lands the new commit on the remote, so every reply cites a SHA that actually exists and a push failure cannot orphan a "Fixed" claim against unchanged code. Use the literal token `{{SHA}}` anywhere in the body where the new short SHA should appear; the flush step substitutes it after push.

1. **Edit files** with the Edit tool.

   **Bucket → queue command (strict — wrong route silently drops the reply):**

   | Source bucket | Queue command | Notes |
   |---|---|---|
   | `threads` / `inline_comments` | `queue-reply` | Inline-threaded reply via GitHub's pulls-comments endpoint with `in_reply_to=<id>`. |
   | `conversation_comments` | `queue-review-body-reply` with `source_id` (**required**) | Flat issue comment. `source_id` drives the 👍 reaction AND the auto-`@mention`: the flush looks up the source comment's author and prepends `@author` so the reply names who it answers and triggers bot reviewers (CodeRabbit/Codex only act on an @mention). Omitting `source_id` posts a context-free top-level comment that reads as addressing no one — don't. |
   | `reviews` (review bodies) | `queue-review-body-reply` (no `source_id`) | Flat issue comment. No source comment exists to look up, so add a quoted `[reply to @…]` header yourself so the reviewer gets notified. |

   The `state.sh` guards validate `comment_id` / `source_id` against the most recent `reviews.json` and reject crossed routes with a clear error — but the table above is the canonical mapping; consult it before queuing.
2. **Queue inline-thread replies** (`threads` / `inline_comments` bucket) — one call per reply:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/state.sh queue-reply \
     '{"comment_id": <id>, "body": "Fixed at {{SHA}}: extracted helper at src/auth/session.ts:42."}'
   ```
3. **Queue review-body or conversation replies** (`reviews` / `conversation_comments` buckets — both use GitHub's flat issue-comments resource, no native threading; for `reviews` entries prefix with a quoted header so the reviewer gets notified). Only the `[reply to @…]` header line is `>`-prefixed; the reply body itself is plain text. Quoting the body too makes GitHub render the entire reply (fixes list, deferred items, sign-off) as one blockquote.
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/state.sh queue-review-body-reply \
     '{"body": "> [reply to @coderabbitai`s review]\n\nFixed at {{SHA}}: null-guard at src/api/booking.ts:118."}'
   ```
   For `conversation_comments`, **always** include the source comment id: the flush drops a 👍 on the original comment AND auto-prepends an `@author` mention (resolved from `source_id`) so the reply names who it answers and notifies/triggers the reviewer. You don't hand-type the @mention — just pass `source_id`:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/state.sh queue-review-body-reply \
     '{"source_id": <conversation_comment_id>, "body": "Fixed at {{SHA}}: ..."}'
   ```
4. **Queue thread resolves** for every thread you addressed (fixed, declined, accepted-issue, already-addressed):
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/state.sh queue-resolve <thread_id>
   ```
   Only `threads` / `inline_comments` are resolvable. Review-body and conversation replies are reply-only.
5. **Queue a 👍 reaction** on every acted-on comment so reviewers see at a glance that the comment was looked at. Scope: any comment you engaged with (FIX, ATTEMPT FIX, DECLINE, ACCEPT ISSUE SUGGESTION, already-addressed). Skipped items get no reaction.

   For inline thread / inline comments (`threads` / `inline_comments` buckets):
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/state.sh queue-reaction \
     '{"target_type": "inline", "target_id": <comment_id>}'
   ```
   For conversation comments (`conversation_comments` bucket):
   ```bash
   bash ${CLAUDE_SKILL_DIR}/scripts/state.sh queue-reaction \
     '{"target_type": "issue", "target_id": <conversation_comment_id>}'
   ```
   **Skip the `reviews` bucket** — GitHub's Reactions API does not support reactions on review submission bodies. Queue a reply via step 3 but no reaction. The reaction queue de-dups on `(target_type, target_id)`, so re-queueing the same comment across iterations is safe.

After the orchestrator runs `commit-and-evaluate.sh`, the queue is automatically flushed against the new commit's short SHA; the flush result appears under `.commit.flush` in the orchestrator's JSON (`{ replied_inline, replied_body, resolved, reacted, errors, counts, sha }`). If push fails, the queue is preserved for the next attempt; if any individual post fails after a successful push, the error is surfaced in `.commit.flush.errors` for the next iteration's `unresolved` accounting (reaction errors are tagged `phase: "reaction"`).

If posting is denied by the environment's write policy (the queue calls themselves succeed but the actual POST fails post-push), surface the denial in this iteration's `outcome.unresolved` with `note: "needs manual reply (denied by posting policy)"`.

### 5. Verify on ground truth

Re-fetch and gate the exit on GitHub's state, not the handler's internal tally — this catches failed resolves, GraphQL index lag, and threads that landed mid-turn. **Run this AFTER the commit-and-evaluate step (which performs the flush)**, not immediately after step 4, since pre-flush the queue hasn't posted anything yet.

```bash
REVIEWS_FILE="$(git rev-parse --absolute-git-dir)/address-pr/reviews.json"
if ! bash ${CLAUDE_SKILL_DIR}/scripts/fetch-review-comments.sh <PR> <owner/repo> > "$REVIEWS_FILE"; then
  orphans='[{"note":"post-fix verify failed: fetch-review-comments error"}]'
else
  orphans=$(jq -c '
    [ .threads[] | {
        thread_id: .id,
        path: (.comments.nodes[0].path // null),
        line: (.comments.nodes[0].line // null),
        note: "thread still unresolved after fix phase"
      }
    ] + (if .consistency.ok then [] else [{note: ("graphql reviewThreads stale: " + .consistency.reason)}] end)
  ' "$REVIEWS_FILE")
fi
```

If the re-fetch fails, do NOT declare the handler done. Append the typed orphan above to `outcome.unresolved` and let `evaluate-iteration.sh` choose to retry or stop.

### 6. Append outcome

Merge any orphans into `unresolved` (tag per-author counts so the report can group later if desired):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append reviews \
  "$(jq -nc --argjson o "$orphans" \
     '{fixed:N, declined:N, skipped:0, unresolved:$o, by_author:{}}')"
```

Reply format: see `references/handler-contract.md` "Reply style" for the required rules (no em-dashes, lead with outcome verb, cite a concrete reference, 1-3 sentences, prefer `{{SHA}}` for the SHA citation). The sign-off line is appended automatically by the reply scripts — do not include it in the JSON body. The example bodies above are illustrative.

## Standalone mode

- `/zeus:address-pr reviews` — run the handler over all reviewers (same as in-loop behavior).
- `/zeus:address-pr reviews <author-substring>` — post-filter to just reviewers whose login matches (case-insensitive substring). Examples: `coderabbitai`, `wego`, `chatgpt-codex`, `alice-wego`.

Exit condition: the post-fix re-fetch (step 5) shows `threads: []` AND `consistency.ok: true`. Any residual threads — from a failed resolve, a mid-turn arrival, or a stale GraphQL index — are appended to `outcome.unresolved` with a typed `note`; the orchestrator's `evaluate-iteration.sh` then decides whether to loop again or stop. `conversation_comments` and review-body replies are gated by the reply scripts' non-zero exit on HTTP errors — a silent failure can't slip through.

## Monitor-mode filter

When invoked from the orchestrator's monitor loop (SKILL.md step 6), the fetch step is replaced by a reduced payload already filtered by `last_seen`. `monitor-step.sh` returns a `filtered_path` field whose file has the same four-bucket shape.

Skip step 1 and use that file directly:

```bash
FILTERED="<filtered_path from monitor-step.sh>"
# then use $FILTERED in place of the full review payload for steps 2–5
```

Everything else (digest, evaluate, apply, reply, resolve, outcome) is identical. After the handler completes and any commit/push is handled, the caller invokes `complete-process` with `--acked-ids` listing every item from `$FILTERED` that this pass actually processed (replied to, resolved, declined-with-reply, or already-addressed):

```bash
ACKED=$(jq -r '
  [
    (.threads // [])[] | .id,
    (.reviews // [])[] | (.id | tostring),
    (.inline_comments // [])[] | (.id | tostring),
    (.conversation_comments // [])[] | (.id | tostring)
  ] | join(",")
' "$FILTERED")

# Replace `<pr_updated_at>` with the value monitor-step.sh returned earlier;
# the `completion_command_template` field shows the full form.
bash ${CLAUDE_SKILL_DIR}/scripts/monitor-step.sh complete-process "<pr_updated_at>" --acked-ids "$ACKED"
```

The above acks every item in the filtered payload. When this pass intentionally leaves some items un-processed (deferred, blocked, or wrong scope), drop those ids from `$ACKED` so the next probe re-surfaces them — `complete-process` won't advance `last_seen` past any un-acked item. The returned JSON includes `acked_count`, `pending_count`, and `pending_ids` for observability. `--acked-ids` is required whenever `filtered_path` has items: the bare `.completion_command` (no `--acked-ids`) now exits non-zero rather than silently aging out fetched items. To intentionally defer everything to the next probe, pass an empty string: `--acked-ids ""`.

Then schedule from that command's JSON if `schedule == true`.
