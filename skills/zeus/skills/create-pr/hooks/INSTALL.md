# Suggest-PR Stop hook (opt-in)

`suggest-pr.sh` is a `Stop` hook: when a turn ends with **committed work on a feature
branch that has no open PR yet** (clean tree, ahead of base, in an isolated worktree),
it nudges the agent to run `/zeus:create-pr`. It exists to bridge an implementer that
*doesn't open PRs itself* — e.g. a built-in `/goal` driving from a `/zeus:propose`
artifact — into the Zeus pipeline: `create-pr` seeds the PR from the proposal, runs the
pre-PR review backstop (`/zeus:review-pr`), and opens the PR; the post-push hook then
nudges `/zeus:address-pr`.

> **Installed zeus as a plugin? This hook is already active.** It's registered in the
> plugin's `hooks/hooks.json` (`${CLAUDE_PLUGIN_ROOT}/skills/create-pr/hooks/suggest-pr.sh`)
> and loads automatically when the plugin is enabled. **Do NOT also add it to
> `settings.json`** — that would fire it twice. The manual steps below are only for a
> **standalone** (non-plugin) skill install.

## Install (standalone / non-plugin only)
Add to the `Stop` array in `~/.claude/settings.json`:

```json
{
  "matcher": "",
  "hooks": [
    { "type": "command", "command": "bash ~/.claude/skills/create-pr/hooks/suggest-pr.sh", "timeout": 10 }
  ]
}
```

## Behavior
Non-blocking — it emits `hookSpecificOutput.additionalContext` (a suggestion); the turn
still ends and the agent acts when ready, so a fire before the implementer is truly done
is harmless. State-driven and gated: only from a **linked worktree**, only on a non-default
branch with commits ahead of base, a **clean** tree, and **no open PR**, and at most **once
per head SHA**. The base branch is resolved (never hard-coded `main`/`master`).

## Disable
Remove the entry, or export `ZEUS_SKIP_PR_SUGGEST=1`.
