# Post-push review hook (opt-in)

`post-push-review.sh` is a `PostToolUse(Bash)` hook: after a `git push`, it nudges the agent to invoke
`/zeus:address-pr` so review comments **and** checks get handled (not just CI). It lives with the skill it
triggers.

> **Installed zeus as a plugin? This hook is already active.** It is registered in the plugin's
> `hooks/hooks.json` (path `${CLAUDE_PLUGIN_ROOT}/skills/address-pr/hooks/post-push-review.sh`) and loads
> automatically when the plugin is enabled. **Do NOT also add it to `settings.json`** — the manual entry
> below would make the hook fire twice. The manual steps are only for a **standalone** (non-plugin) skill
> install, where no plugin manifest loads `hooks/hooks.json` for you.

## Install (standalone / non-plugin only)
Add this entry to the `PostToolUse` array in `~/.claude/settings.json` (coexists with any existing
`Bash` matcher hooks):

```json
{
  "matcher": "Bash",
  "hooks": [
    { "type": "command",
      "command": "bash ~/.claude/skills/address-pr/hooks/post-push-review.sh",
      "timeout": 10 }
  ]
}
```

(The hook command runs through a shell, so `~` expands; adjust the path if your skills live
somewhere else — `settings.json` has no `${CLAUDE_SKILL_DIR}`, hooks run outside skill context.)

## Behavior
Fires only for a real `git push`. No-ops (exit 0, silent) on: non-push commands, `--dry-run`, pushes to
`main`/`master`, or `SKIP_REVIEW=1`. The nudge is advisory — it asks the agent to run `/zeus:address-pr`,
which then drives the PR to settled.

## Disable
Remove the entry from `settings.json`, or set `SKIP_REVIEW=1` in the environment for a one-off skip.
