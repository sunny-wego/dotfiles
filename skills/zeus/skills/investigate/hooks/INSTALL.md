# Auto-link Stop hook (opt-in)

This makes PRs you create during an investigation attach themselves to the Epic + board,
so you just run `/zeus:create-pr` as usual.

> **Installed zeus as a plugin? This hook is already active.** It is registered in the plugin's
> `hooks/hooks.json` (path `${CLAUDE_PLUGIN_ROOT}/skills/investigate/hooks/stop-autolink.sh`) and loads
> automatically when the plugin is enabled. **Do NOT also add it to `settings.json`** — the manual entry
> below would make the Stop hook fire twice. The manual steps are only for a **standalone** (non-plugin)
> skill install, where no plugin manifest loads `hooks/hooks.json` for you.

## Install (standalone / non-plugin only)

It edits `settings.json`, so it's opt-in. Add to `~/.claude/settings.json` (user-level) or the
project's `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bash ~/.claude/skills/investigate/hooks/stop-autolink.sh" }
        ]
      }
    ]
  }
}
```

Notes:
- The hook command runs through a shell, so `~` expands; adjust the path if your skills live
  somewhere else — `settings.json` has no `${CLAUDE_SKILL_DIR}`, hooks run outside skill context.
- The hook **no-ops instantly** when no investigation is active in the worktree, so leaving it
  installed costs ~nothing on unrelated work.
- It goes dormant automatically when an investigation closes (`/zeus:investigate` clears the state).
- Prefer the `update-config` skill to apply this safely rather than hand-editing JSON.
- To disable, remove the block or run `investigate-state.sh clear` to make it dormant for the current investigation.
