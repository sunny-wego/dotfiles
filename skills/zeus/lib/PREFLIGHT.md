# Preflight bootstrap (shared)

Every *mutating* zeus skill runs `scripts/preflight.sh` before doing work, so a missing
dependency is reported with a fix instead of failing mid-task. (`review-pr` is read-only
and ships no preflight — it never mutates, so there is nothing to gate.) The mechanism is
identical across the skills that carry it; each such SKILL.md carries only the one-line
invocation and points here for the detail (this file is the single source — don't
re-explain the flow inline).

## Run it
```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo — under zsh, echo expands the escaped \n in .report and corrupts the JSON
```

`preflight.sh` reads the skill's `deps.json`, runs the always-on base checks (git
work tree, `gh` installed + authenticated, `jq`), and returns:

```
{ "ok": bool, "report": "<human summary>", "remediation": [ {tool, fix, auto}, … ] }
```

## On `.ok == false`
Present each `.remediation[]` entry to the user and **offer to install**, then
re-check with `--fix`:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh --fix
```

- `--fix` runs **only** the entries marked `auto: true` (package installs).
- Interactive steps such as `gh auth login` are `auto: false` — they are **listed,
  never auto-run**. Ask the user to run them, then re-check.

**Proceed only once preflight reports `ok: true`.**
