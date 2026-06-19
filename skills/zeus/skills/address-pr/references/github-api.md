# GitHub API Reference

Only the two GitHub operations still done directly by handlers (everything else lives in `scripts/fetch-review-comments.sh`, `scripts/reply-to-comments.sh`, `scripts/resolve-threads.sh`).

**Sign-off (required).** Every message this skill posts must end with the zeus
origin tag so the recipient can see which skill produced it:

```
_via `zeus:address-pr`_
```

The batch scripts (`reply-to-comments.sh`, `reply-to-review-body.sh`) append this
automatically — handlers must NOT add it to queued bodies. The direct `gh api`
paths below bypass those scripts, so include the tag yourself, exactly as
shown in each example.

## Reply to a top-level conversation comment

Top-level PR comments aren't threaded and can't use `in_reply_to`. Post a new issue comment:

```bash
gh api repos/{owner}/{repo}/issues/{PR}/comments \
  --method POST --field body="<reply text>

_via \`zeus:address-pr\`_"
```

## Reply to an inline comment (single reply)

For batching, use `scripts/reply-to-comments.sh`. Single reply:

```bash
gh api repos/{owner}/{repo}/pulls/{PR}/comments \
  --method POST \
  --field body="<reply text>

_via \`zeus:address-pr\`_" \
  --field in_reply_to=COMMENT_ID
```

## Resolve a review thread (single)

For batching, use `scripts/resolve-threads.sh`. Single:

```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: { threadId: $threadId }) {
      thread { id isResolved }
    }
  }
' -f threadId=THREAD_NODE_ID
```
