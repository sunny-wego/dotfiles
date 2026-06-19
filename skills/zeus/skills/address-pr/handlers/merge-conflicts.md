# Merge Conflict Handler

Resolve merge conflicts with the base branch (and catch "behind base" even without conflicts).

See `references/handler-contract.md` for shared rules.

## Fix

### 1. Fetch base + capture pre-merge snapshot

```bash
gh pr view <PR> --json baseRefName -q '.baseRefName'
git fetch origin <BASE>
bash ${CLAUDE_SKILL_DIR}/scripts/check-pr-relevance-llm.sh snapshot <PR> pre
```

If the pre snapshot fails, continue conflict resolution but require manual confirmation in step 5.

### 2. Merge

```bash
git merge origin/<BASE> --no-edit
```

If no conflicts, continue to steps 4-5 anyway (use an empty conflict-file list from step 3).

### 3. Resolve conflicts (or capture empty conflict set)

```bash
CONFLICTS_JSON=$(bash ${CLAUDE_SKILL_DIR}/scripts/capture-conflicts.sh)
```

Writes `$STATE_DIR/conflicts.txt` and `$STATE_DIR/conflict-files.json`; prints the JSON array on stdout. Empty array → no conflicts (continue to steps 4-5).

- **Lockfiles** (`package-lock.json`/`yarn.lock`/`pnpm-lock.yaml`/`bun.lock`, `poetry.lock`/`uv.lock`, `Cargo.lock`, `go.sum`, `Gemfile.lock`) — accept one side, regenerate via the project's package manager.
- **Auto-generated files** — accept our side; regenerate via the build script if one exists.
- **Trivial source conflicts** — read markers, combine both sides with Edit.
- **Complex source conflicts** (overlapping logic) — `git merge --abort`, append outcome with unresolved list, then render the AskUserQuestion message:
  ```bash
  bash ${CLAUDE_SKILL_DIR}/scripts/merge-conflict-prompts.sh conflicts "<base>" "$CONFLICTS_JSON"
  ```
  Post the printed text via AskUserQuestion. Reply contract: `continue-manual` or `stop`.

### 4. Verify + capture post-merge snapshot

```bash
git diff --name-only --diff-filter=U   # must be empty
bash ${CLAUDE_SKILL_DIR}/scripts/check-pr-relevance-llm.sh snapshot <PR> post
```

If unresolved conflicts remain, stop and report.

### 5. LLM relevance check (mandatory)

Build the relevance prompt package from pre/post snapshots:

```bash
STATE_DIR="$(git rev-parse --absolute-git-dir)/address-pr"
CONFLICT_FILES_FILE="$STATE_DIR/conflict-files.json"
RELEVANCE_INPUT_FILE="$STATE_DIR/relevance-input.json"
bash ${CLAUDE_SKILL_DIR}/scripts/check-pr-relevance-llm.sh build-prompt <PR> "$CONFLICT_FILES_FILE" > "$RELEVANCE_INPUT_FILE"
```

Use `.prompt` and `.inputs` from `RELEVANCE_INPUT_FILE` and produce strict decision JSON:

```json
{
  "risk": "low" | "review",
  "confidence": 0-1,
  "summary": "one-sentence rationale",
  "signals": ["signal 1", "signal 2"],
  "unexpected_files": ["path1", "path2"]
}
```

Gate the decision at threshold `0.70`:

```bash
echo '<decision-json>' | bash ${CLAUDE_SKILL_DIR}/scripts/check-pr-relevance-llm.sh gate - 0.70
```

- If `action=auto-continue` → append relevance outcome and continue:
  ```bash
  bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append pr-relevance '{"status":"auto-continued","risk":"low","confidence":0.82,"summary":"Scope still matches PR intent."}'
  ```
- If `action=ask-user` → pause and render the AskUserQuestion message:
  ```bash
  bash ${CLAUDE_SKILL_DIR}/scripts/merge-conflict-prompts.sh relevance '<decision-json>'
  ```
  Post the printed text via AskUserQuestion. Reply contract: `continue` or `stop`.
  - If user confirms continue:
    ```bash
    bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append pr-relevance '{"status":"manual-confirmed","risk":"review","confidence":0.61,"summary":"User confirmed relevance despite broad merge churn."}'
    ```
  - If user does not confirm: stop and report.

If relevance passes (auto or confirmed) → orchestrator commits & pushes. Append merge-conflicts outcome with `fixed: N-files-resolved`.

## Standalone mode

`/zeus:address-pr merge-conflicts`: exit when `mergeable` is `MERGEABLE`. Typically one iteration.
