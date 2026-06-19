# AGENTS.md — zeus

The **issue → code → PR → review** workflow as one skill family. Align on work as
GitHub issues (`propose`, `investigate`), turn an issue into code on a branch
(`implement`), surface it as a reviewer-friendly PR (`create-pr`), drive it to
mergeable (`address-pr`), and hand off to a reviewer (`request-review`). Skills
share durable facts through a per-worktree `journey.json` (and a hidden journey
marker in the PR body), and invoke each other **by name** through JSON contracts —
never by calling one another's scripts directly.

This file documents the **shell-script CLI surface** of the family: the shared
argument convention, the parser every script uses, and a per-skill reference.
For the *behavioral* flow of a given skill, read its `SKILL.md`.

## Skills

| Skill | Trigger (examples) | What it does |
|---|---|---|
| [`propose`](./skills/propose/SKILL.md) | "propose X", "open an issue", "write an RFC" | Put a proposal/decision doc up for alignment as a GitHub issue. |
| [`investigate`](./skills/investigate/SKILL.md) | "investigate X", "open a postmortem", "record this finding" | Evidence-driven investigation maintained as a GitHub issue. |
| [`implement`](./skills/implement/SKILL.md) | "do #N", "implement the issue", "ship the proposal" | Read an issue as the spec, write the code on a branch, hand off to `create-pr`. |
| [`create-pr`](./skills/create-pr/SKILL.md) | "create pr", "open a pr", "update pr body" | Author/refresh the human-facing PR title + body (stable Original Intent section). |
| [`address-pr`](./skills/address-pr/SKILL.md) | "fix pr", "address feedback", "resolve merge conflicts" | Drive a PR to **settled** (mergeable, checks green, reviews resolved), then watch. |
| [`request-review`](./skills/request-review/SKILL.md) | "ping reviewers", "request review", "re-review" | Notify a PR's code owners it's ready; re-ping in-thread when the head advances. |

## CLI argument convention

Every script that takes a **PR / repo / SHA** resolves them through one shared
parser, so the form is identical everywhere. This exists because the surface had
drifted into incompatible signatures (`<pr> <owner> <repo>` vs `<pr> <owner/repo>`
vs `<owner> <repo> <pr>`), which silently misparsed.

**The rules:**

1. **Identifiers are flags, positional is tolerated.** `--pr <n>`, `--repo <owner/repo>`,
   `--sha <x>` are canonical. A bare all-digits token is taken as the PR and a bare
   `owner/repo` token as the repo, in any order — so old positional calls still work.
2. **A repo is ALWAYS one `owner/repo` slug.** The split `<owner> <repo>` form does
   not exist anywhere. (`--repo` rejects a non-slug value loudly.)
3. **Sub-commands stay positional.** Verb-dispatch scripts (`state.sh append …`,
   `journey-marker.sh write …`) keep the verb as the first bare positional — git-style.
4. **Bulk/structured payloads come via stdin or `--from <file>` (`-` = stdin)**, never
   as inline positional JSON.
5. **Refs/branches never go through the identifier parser.** A base like `release/v1`
   contains `/` and would be misread as a repo — so scripts that take a branch
   (`state.sh init`, `monitor-state.sh init`) keep plain positional sub-args and take
   no repo.

### The parser (`scripts/lib.sh`)

Defined in each skill's `scripts/lib.sh` (mirrored verbatim across skills — keep in
sync). Source the lib, then call one of:

```sh
resolve_pr "$@"       # parse identifiers, NO network. Sets the globals below.
resolve_target "$@"   # like resolve_pr, but defaults the repo via `gh` when omitted.
```

Both populate: `PR`, `REPO_SLUG` (`owner/repo`), `OWNER`, `REPO_NAME`, `SHA`, and
`REST=( … )` (unconsumed args, in order — expand as `"${REST[@]:-}"` under `set -u`).
Accepts `--pr/--repo/--sha` (and `--pr=…` / `--head-sha` alias) plus bare positional
digit→PR and slash→repo, in any order. A bare non-slash, non-numeric token lands in
`REST` (so a stale split call trips the caller's own usage check rather than
misparsing); a malformed `--repo` exits non-zero.

A typical migrated script:

```sh
source "$SCRIPT_DIR/lib.sh"
resolve_target "$@"
pr="$PR"; repo="$REPO_SLUG"; owner="$OWNER"; name="$REPO_NAME"
[ -n "$pr" ] && [ -n "$REPO_SLUG" ] || { echo "usage: … --pr <n> [--repo <owner/repo>]" >&2; exit 2; }
```

### The checker — keep it consistent

Positional tolerance means a stale/split call still *works*, so consistency can't be
left to luck. Run the lint:

```sh
bash zeus/lib/check-arg-conventions.sh   # exit 0 = clean, 1 = violations
```

It fails on any split `<owner> <repo>` in a script CLI call or a doc, and verifies
`resolve_pr`/`resolve_target` exist in both PR-workflow libs. **There are no
exemptions** — every identifier-taking script routes through the parser. Run it (and
update docs) when you add or edit a script.

## CLI reference — `address-pr`

**Orchestration entry points** (driven by `SKILL.md`):

| Script | Signature |
|---|---|
| `setup.sh` | *(no args)* — identify PR, init state, capture Original Intent |
| `pr-status.sh` | `--pr <n>` — snapshot checks + merge state |
| `wait-and-evaluate.sh` | `--pr <n> <push_exit>` — probe + decide next action (`push_exit` ∈ -1/0/1) |
| `commit-and-evaluate.sh` | `"<commit_msg>" <iteration> <max_iterations>` — stage→commit→push→flush→evaluate |
| `commit-and-push.sh` | `"<commit message>"` — commit + push (repo derived from git remote) |
| `evaluate-iteration.sh` | `<pr_status_file> <push_exit> <iteration> <max_iterations>` |
| `ready-for-review.sh` | `--pr <n> [--repo <owner/repo>] [--plain]` — the settled verdict (exit 0 ready / 1 not / 2 probe fail) |
| `report.sh` | *(no args)* — aggregate handler outcomes |
| `ensure-worktree.sh` | `[--pr <n>]` — reuse/create the PR's isolated worktree (pre-isolation; bare number ok) |

**Identifier-taking utilities** (canonical `--pr/--repo/--sha`, positional tolerated):

| Script | Signature |
|---|---|
| `rehydrate.sh` | `--pr <n> [--repo <owner/repo>] [--sha <head>]` |
| `monitor-probe.sh` | `--pr <n> [--repo <owner/repo>]` |
| `monitor-step.sh` | `--pr <n> [--repo <owner/repo>]`  •  `complete-process <pr_updated_at> [--acked-ids id1,id2]` |
| `fetch-review-comments.sh` | `--pr <n> [--repo <owner/repo>]` — 4-bucket review payload (order-agnostic) |
| `find-failed-vercel-checks.sh` | `--pr <n> [--repo <owner/repo>]` |
| `flush-pending-replies.sh` | `--pr <n> --repo <owner/repo> --sha <short_sha>` |
| `reply-to-comments.sh` | `--pr <n> --repo <owner/repo> [--from <pairs.json>\|-]` |
| `reply-to-review-body.sh` | `--pr <n> --repo <owner/repo> [--from <bodies.json>\|-]` |
| `wait-for-sha.sh` | `--pr <n> --sha <expected_sha>` |

**Verb-dispatch state / prompt builders** (verb positional; PR positional within verb):

| Script | Sub-commands |
|---|---|
| `state.sh` | `init <pr> <branch> <base>` · `iteration` · `bump-iteration` · `append <handler> <json>` · `read` · `clear` · `queue-reply` · `queue-review-body-reply` · `queue-resolve` · `queue-reaction` · `flush-queue` |
| `monitor-state.sh` | `init <pr> <head_sha> [last_seen]` · `get` · `set-last-seen <ts>` · `pr` · `last-seen` · `bump-idle` · `reset-idle` · `idle-streak` · `bump-probe-failure` · `reset-probe-failures` · `probe-failures` · `set-last-acked` · `last-acked` · `clear` |
| `journey.sh` | `write-issue` · `write-pr` · `write-investigation` · `lookup` · `issue-number` · `issue-url` · `pr-number` · `pr-url` · `investigation-epic` · `clear` |
| `journey-marker.sh` | `emit` · `parse` · `splice` · `read <pr> [owner/repo]` · `write <pr> [owner/repo]` (stdin JSON) |
| `check-pr-relevance-llm.sh` | `snapshot <pr> <pre\|post>` · `build-prompt <pr> [conflict_files]` · `gate - [threshold]` |
| `original-intent.sh` | `capture <pr>` · `parse` · `read` |
| `merge-conflict-prompts.sh` | `conflicts <base> <files_json>` · `relevance <decision_json>` |

**Helpers / no-identifier** (stdin / files / no args): `capture-conflicts.sh`,
`classify-checks.sh` (stdin: pr-status JSON), `dispatch-monitor.sh` (`<probe-json>|-`),
`fetch-failed-logs.sh` (`<branch> [commit]`), `find-sonar-project-key.sh`,
`identify-pr.sh` (`[--checkout]`), `resolve-threads.sh` (`<thread_id> …`),
`review-digest.sh` (`<reviews_json> [excerpt_chars]`), `safe-stage.sh`,
`preflight.sh` (`[--fix]`), `lib.sh` (sourced).

## CLI reference — `request-review`

**Identifier-taking** (canonical `--pr/--repo/--sha`, positional tolerated):

| Script | Signature |
|---|---|
| `ping-gap.sh` | `--pr <n> --repo <owner/repo> --sha <head_sha>` — is a ping owed for this head? |
| `thread-restore.sh` | `--pr <n> --repo <owner/repo> [--sha <head>]` (stdin: thread record) |
| `ready-slack-message.sh` | `--pr <n> [--repo <owner/repo>] [--from <file>\|--from-stdin]` — initial-ping envelope |
| `re-review-message.sh` | `--pr <n> [--repo <owner/repo>] (--from <file>\|--from-stdin)` — threaded re-review envelope |
| `resolve-reviewers.sh` | `--pr <n> [--repo <owner/repo>]` — PR reviewers / CODEOWNERS → Slack mentions |

**Verb-dispatch state / policy:**

| Script | Sub-commands |
|---|---|
| `auto-ping.sh` | `<owner/repo>` (lookup) · `enable <owner/repo> --channel <C…> [--mode send\|draft\|ask] [--re-review]` · `disable <owner/repo>` · `list` · `path` |
| `review-thread.sh` | `set <pr> <head_sha> [--thread-ts <ts>] [--channel <id>]` · `get <pr>` · `sha <pr>` · `clear <pr>` |
| `handles.sh` | `path` · `init` · `get <gh-login>` · `set <gh-login> <slack-id>` · `remove <gh-login>` · `list` · `missing-from-codeowners` · `bootstrap-template` |

**Helpers** (sourced / no-identifier): `slack-envelope.sh` (sourced),
`watermark.sh` (`--tag <skill>` | `<skill> <file>|-|--in-place <file>`),
`preflight.sh` (`[--fix]`), `lib.sh` (sourced).

> The other four skills (`propose`, `investigate`, `implement`, `create-pr`) carry
> their own scripts under `skills/<skill>/scripts/`. They follow the same house
> rules (identifiers as `--pr/--repo`, verbs positional, payloads via stdin); the
> detailed per-script reference above covers the PR-workflow pair where the parser
> currently lives. New or edited scripts in any skill should route identifiers
> through `resolve_pr`/`resolve_target` and pass `check-arg-conventions.sh`.

## Structure & shared lib

```
zeus/
├── .claude-plugin/        plugin manifest
├── lib/                   shared script TEMPLATES, vendored into each skill's scripts/
│   ├── journey-marker.sh  journey.sh  preflight.sh  watermark.sh  telemetry.sh  preview.sh
│   └── check-arg-conventions.sh   ← the CLI-convention lint (run from anywhere)
├── hooks/hooks.json
└── skills/<skill>/
    ├── SKILL.md           the behavioral contract (read this for flow)
    ├── scripts/           the skill's CLI (each sources scripts/lib.sh)
    │   └── lib.sh         per-skill helpers + resolve_pr / resolve_target
    ├── handlers/          (address-pr) per-operation playbooks
    └── references/        long-form contracts
```

- **`resolve_pr` / `resolve_target` live in each skill's `scripts/lib.sh`.** The two
  PR-workflow copies are kept identical; if you change one, change the other.
- **`zeus/lib/` is the vendoring source**, not a runtime import — shared scripts
  (e.g. `journey-marker.sh`) are copied into each skill's `scripts/`. Edit the source
  in `zeus/lib/` AND the vendored copies together.
- **Per-worktree state** lives under `.git/<skill>/` (e.g. `.git/address-pr/`,
  `.git/request-review/`), isolated across worktrees.

## House conventions

- Skills call skills **by name** with JSON contracts — never another skill's scripts
  by path. GitHub / `gh` is the source of truth; the PR body is never a state store
  (except the hidden journey marker, which is durable cross-session context).
- When you add or change a script's CLI, update its `Usage:` header, the call-sites in
  the owning `SKILL.md`, and run `bash zeus/lib/check-arg-conventions.sh`.
