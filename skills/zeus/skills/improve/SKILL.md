---
name: improve
description: >-
  Retrospective that turns a coding session's zeus-workflow friction into
  durable improvements to the zeus skills themselves, plus repo-level guidance.
  Use this whenever the user wants to improve or iterate on the workflow/tooling
  after using any zeus skill — issue (propose / investigate), code (implement),
  PR (create-pr / address-pr), or review (request-review) — triggers:
  "/zeus:improve", "improve the workflow", "what should we fix in zeus", "retro
  this session", "iterate on the skills", "retro the proposal", "improve
  investigate", "capture what we learned this session", "make zeus faster". It
  harvests friction signals, grades them real-vs-imaginary,
  classifies each as skill-level (lands in the zeus source) vs repo-level (lands
  in the repo's AGENTS.md), validates before shipping, and lands fixes on your
  confirmation — accumulating learnings in a cross-session ledger. NOT for
  improving arbitrary application/product code, performance, or non-zeus tooling;
  this improves the zeus workflow, not the product.
license: MIT
compatibility: Requires git, gh (GitHub CLI) authenticated, jq. SonarQube MCP optional (validation only).
metadata:
  author: sunnywong
  version: "0.2"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(jq:*) Read Edit Write Grep AskUserQuestion ScheduleWakeup Skill Task Agent mcp__sonarqube__*
---

# Improve — compound the zeus workflow, one session at a time

zeus is reused across every repo, so its rough edges repeat every session until
someone fixes them. This skill captures a session's friction the moment it's
freshest, decides what's worth fixing, and lands the fix where it belongs —
generic improvements in zeus, repo-specific ones in the repo. A cross-session
**ledger** makes it compound: a one-off becomes a tracked pattern, and the N-th
recurrence (or one high-severity miss) graduates it to "fix now."

Read `references/improvement-contract.md` once before grading or landing — it
holds the two-tier rule, the agnostic test, "real over imaginary", "ripe", and
the validate/land discipline. Read `references/signal-sources.md` for the harvest
map. The deterministic mechanics are scripts; the judgement is yours.

In the commands below, `$SKILL_DIR` is this skill's own directory — shown as
"Base directory for this skill" when the skill loads. Substitute it; the scripts
live at `$SKILL_DIR/scripts/`.

## When this fits

Run it at the **end of (or right after) a session** that used any zeus skill —
issue, code, PR, or review — while the conversation is still in context, because
that conversation is the richest input. It applies equally whether the session
opened a proposal, ran an investigation, implemented an issue, or drove a PR.
Running it cold in a fresh session still works but degrades to the durable signals
(see Harvest), which are richest for the PR pair and thinner for the issue-side
skills. It is **not** for improving product code — only the zeus workflow.

## The loop

### 1. Resolve the source (so fixes are durable)

```bash
ZEUS_SRC="$(cd "$(dirname "$(readlink ~/.claude/skills/zeus || echo ~/.claude/skills/zeus)")" 2>/dev/null && pwd -P)"
```

The skill's own `scripts/lib.sh` already resolves this via `pwd -P` for the ledger.
If `~/.claude/skills/zeus` is **not** a symlink to a writable source, warn the user
that edits to the installed copy won't survive a reinstall and ask where the source
is — don't hardcode a path.

### 2. Harvest — conversation first, then signals

- **(a) The live conversation (PRIMARY).** Reflect on *this* session's dialogue: the
  user's corrections and the principle behind each, approaches rejected and why,
  friction expressed, decisions made. This is the *why* behind every learning. You
  may invoke the `/reflect` skill for a structured pass, then add the zeus-specific
  grading/tiering below. (Cold start, no conversation in context → skip to (b) + a
  best-effort `/reflect` over the transcript.)
- **(b) Durable signals (corroboration).** Run the harvester for the recurrence/severity numbers:

  ```bash
  bash "$SKILL_DIR/scripts/harvest.sh"   # → friction JSON across the family: issue/epic pointers, spec-commits, iterations, failed checks, ping markers, cycle count
  ```

The conversation surfaces candidates and rationale; the signals quantify them.

### 3. Distill candidates

Each candidate = `{pattern, target, proposed_fix, evidence}`. **Real over
imaginary:** every candidate must cite a real signal (a user correction, or a
recurring/severe durable signal). Never propose for a failure mode you only
imagined.

### 4. Classify each candidate (required)

Apply the agnostic test (`references/improvement-contract.md`):
- **skill-level** → `tier:"skill"`, `destination` = a path under `$ZEUS_SRC` (or `~/.claude/hooks/...`).
- **repo-level** → `tier:"repo"`, `destination` = the repo's closest `AGENTS.md`/`CLAUDE.md` (or `.zeus/notes.md`).

Reclassify or split anything that fails the test — a repo/tech specific must never
enter zeus.

### 5. Record in the ledger

Append each candidate (one JSON object; dedup is by `.pattern`, which bumps the
recurrence `count`):

```bash
echo '{"pattern":"...","tier":"skill|repo","destination":"...","target":"...","severity":"high|med|low","grade":"real","fix":"...","evidence":{"session":"<id-or-date>","repo":"<owner/repo>","pr":<n>,"signal":"<what was observed>"}}' \
  | bash "$SKILL_DIR/scripts/ledger.sh" append --from -

bash "$SKILL_DIR/scripts/ledger.sh" digest    # grouped by tier; RIPE flagged
```

### 6. For each RIPE entry — branch by tier, with the user

- **skill-tier:** (a) **validate** with a concrete, agnostic check (a logic unit-test,
  or `mcp__sonarqube__analyze_code_snippet`); on fail/partial → `ledger.sh mark <pattern> deferred "<why>"` and stop. (b) Show the exact edit and **confirm**. (c) Land in
  `$ZEUS_SRC/...` (+ `~/.claude/hooks/...` for hooks), bump the target skill's
  `metadata.version`, `ledger.sh mark <pattern> shipped`. Leave the dotfiles edits
  uncommitted and offer to commit.
- **repo-tier:** (a) **validate** the hint is accurate and actually saves zeus a step
  (cite the evidence). (b) **confirm.** (c) Append a concise note to the repo's closest
  `AGENTS.md`/`CLAUDE.md` (or `.zeus/notes.md`), to be committed via the repo's own PR
  — never into zeus; `ledger.sh mark <pattern> shipped`. If the repo learning would
  need zeus to *read* it programmatically, file that as a **separate skill-tier
  candidate** ("teach zeus to read repo-local hints") — keep the split clean.

Never land without an explicit confirmation: this skill edits the user's own tooling.

### 7. Report

Summarize: harvested friction, ripe items split by tier, what shipped/deferred
where, and the current `ledger.sh digest`.

## Scripts & references

| Path | Purpose |
|---|---|
| `scripts/harvest.sh` | durable friction signals → JSON (source b) |
| `scripts/ledger.sh` | `append` / `digest` / `list` / `mark` the cross-session ledger |
| `scripts/lib.sh` | source resolution, ledger path, lock, arg parser |
| `references/improvement-contract.md` | two-tier rule, agnostic test, real-over-imaginary, ripe, validate/land |
| `references/signal-sources.md` | the harvest map (conversation + durable signals) |

The ledger is `learnings/ledger.jsonl` in the zeus source (git-tracked, cross-repo).
