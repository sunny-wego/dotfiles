# AGENTS.md — zeus

The **issue → code → PR → review** workflow as one skill family. Align on work as
GitHub issues (`propose`, `investigate`), write the code on a branch (a built-in
implementer like `/goal`, or by hand), surface it as a reviewer-friendly PR
(`create-pr`) — which reviews the diff via `review-pr` and verifies the linked
issue's contract before opening — drive it to mergeable (`address-pr`), and hand off
to a reviewer (`request-review`). `review-pr` is the shared review engine:
auto-detected **local** (pre-PR working diff) or **remote** (an open PR). `improve`
retrospects on the family itself. Skills share durable facts through a per-worktree
`journey.json` (and a hidden journey marker in the PR body), and invoke each other
**by name** through JSON contracts — never by calling one another's scripts directly.

```
propose / investigate → ⟨code: /goal or by hand⟩ ──▶ create-pr ──▶ address-pr → request-review
                                review-pr (local) + verify the issue contract   settle      ping reviewer
review-pr ── one engine, auto-detected: local (pre-PR) | remote (open PR)        improve ── retro on the family
```

This file documents the **shell-script CLI surface** of the family: the shared
argument convention, the parser every script uses, and a per-skill reference.
For the *behavioral* flow of a given skill, read its `SKILL.md`.

## Skills

| Skill | Trigger (examples) | What it does |
|---|---|---|
| [`propose`](./skills/propose/SKILL.md) | "propose X", "open an issue", "write an RFC" | Put a proposal/decision doc up for alignment as a GitHub issue. |
| [`investigate`](./skills/investigate/SKILL.md) | "investigate X", "open a postmortem", "record this finding" | Evidence-driven investigation maintained as a GitHub issue. |
| [`review-pr`](./skills/review-pr/SKILL.md) | "review pr", "code review", "review my changes before PR", a PR URL | Read-only review across 7 dimensions; **auto-detects** local (pre-PR working diff) vs remote (open PR). Diagnoses + hands findings back — never fixes. |
| [`create-pr`](./skills/create-pr/SKILL.md) | "create pr", "open a pr", "update pr body" | Author/refresh the human-facing PR title + body (stable Original Intent section); **reviews the diff** (`review-pr`) and **verifies the linked issue's contract** before opening. |
| [`address-pr`](./skills/address-pr/SKILL.md) | "fix pr", "address feedback", "resolve merge conflicts" | Drive a PR to **settled** (mergeable, checks green, reviews resolved), then watch. |
| [`request-review`](./skills/request-review/SKILL.md) | "ping reviewers", "request review", "re-review" | Notify a PR's code owners it's ready; re-ping in-thread when the head advances. |
| [`improve`](./skills/improve/SKILL.md) | "/zeus:improve", "retro this session", "iterate on the skills" | Meta/orthogonal: harvest a session's friction and land fixes in zeus or the repo's guidance. |

## Composition

The spine (intro diagram) is just the common path — **any skill is a valid entry
point**. The skills compose three ways: invoke-by-name hand-offs, a shared
`journey.json` bus, and two hooks. Each capability has exactly one owner, so a path
either reuses it or hands off to it — never duplicates it.

**Hand-offs** — the only inter-skill calls, always *by name*, never another skill's
scripts by path:

| Caller | Callee | When |
|---|---|---|
| `create-pr` | `review-pr` (self) | 1c gate, pre-open — findings handed back to fix (skipped when `.review` == HEAD) |
| `address-pr` | `request-review` | at settled, and on each watch re-review |
| `investigate` | *(opens a remediation issue)* | `remediate` → then code + `create-pr` |

`review-pr` and `request-review` are terminal (invoke nothing); `address-pr` never calls `review-pr`.

**The bus** — per-worktree `journey.json` facts, one writer class each (readers never re-derive them):

| Fact | Writer | Reader(s) | Why |
|---|---|---|---|
| `.issue` | propose, investigate | create-pr | seed the PR from the issue + verify its contract |
| `.review {sha}` | create-pr (1c) | create-pr | skip a redundant pre-PR review of the same tree on re-invocation |
| `.pr` | create-pr | address-pr | pick up the opened PR |
| `.investigation.epic` | investigate | create-pr | file the PR under the epic |
| PR-body marker (`slack`, `accepted_checks`) | address-pr | address-pr / request-review | re-thread the ping; honor accepted gates |

**Hooks** (automatic transitions, no call; state-driven, gated to a linked worktree) — see `hooks/hooks.json`:
- PostToolUse(push) → nudge `address-pr` after a push lands on a branch with an open PR.
- Stop → link the branch's open PR into the active `investigate` epic.
- Stop → suggest `create-pr` when a turn ends with committed work on a feature branch and **no** open PR. This bridges an implementer that doesn't open PRs itself (e.g. a built-in `/goal` driving from a `propose` artifact) into the pipeline: `propose → /goal → ⟨nudge⟩ create-pr (seeds from `.issue` + review gate + verify contract) → ⟨push hook⟩ address-pr → request-review`.

**Dedup guarantees:**
- Review runs **once per tree** — create-pr's 1c gate reviews pre-PR and stamps the
  `.review` watermark (only on a SHA a review actually ran against), so a re-invocation
  on the unchanged tree skips re-review. (A future upstream implementer that records its
  reviewed SHA hands off the same way — create-pr skips 1c when `.review` == HEAD.)
- **One notifier** (`request-review`, per-SHA dedup) — no skill posts Slack itself.
- **One reviewer engine** — `self` (hand back) and `peer` (post comments) are adapters over the same handlers.
- **State is re-derived, not stored** — `address-pr` is a level-triggered reconciler; GitHub is the only truth.

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

It checks: [1]/[2] no split `<owner> <repo>` in a script CLI call or a doc; [3] the
parser is defined once in `lib/pr-ident.sh` and sourced by the PR-workflow libs;
[4] no skill `lib.sh` re-defines a shared helper (`resolve_pr`/`with_lock`/`run`/…);
[5] no script hand-rolls a `--pr)` case — every PR-identifier script routes through
`resolve_pr`/`resolve_target`. **There are no exemptions** for `--pr`-taking scripts.
(Issue-centric skills that take only `--repo`, and the resolvers themselves —
`identify-pr.sh`/`detect-target.sh`/`pr-ident.sh` — are out of scope by construction.)
[6] publish backends conform to `publish-contract.md`; [7] every `zeus:<name>`
sub-agent reference resolves to an `agents/<name>.md` or a skill, and the archetype
invariants hold (`cold-reader` ships `tools: ""`, `diagnostician` stays read-only).
Run it when you add or edit a script.

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
| `journey.sh` | `write-issue` · `write-pr` · `write-review <sha>` · `write-investigation` · `lookup` · `issue-number` · `issue-url` · `pr-number` · `pr-url` · `reviewed-sha` · `investigation-epic` · `clear` |
| `journey-marker.sh` | `emit` · `parse` · `splice` · `read <pr> [owner/repo]` · `write <pr> [owner/repo]` (stdin JSON) |
| `check-pr-relevance-llm.sh` | `snapshot <pr> <pre\|post>` · `build-prompt <pr> [conflict_files]` · `gate - [threshold]` |
| `original-intent.sh` | `capture <pr>` · `parse` · `read` |
| `merge-conflict-prompts.sh` | `conflicts <base> <files_json>` · `relevance <decision_json>` |

**Helpers / no-identifier** (stdin / files / no args): `capture-conflicts.sh`,
`classify-checks.sh` (stdin: pr-status JSON), `dispatch-monitor.sh` (`<probe-json>|-`),
`fetch-failed-logs.sh` (`<branch> [commit]`), `find-sonar-project-key.sh`,
`pr-for-branch.sh` (`[--checkout]` — the open PR for the current branch), `resolve-threads.sh` (`<thread_id> …`),
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

## CLI reference — `review-pr`

`review-pr` runs one engine on two **auto-detected** axes: `source` (local working
diff vs an open PR) and `role` (self = my work, hand findings back; peer = someone
else's PR, post comments). `--local`/`--base`, a PR arg, and `--as self|peer` are
overrides. `--base` takes a ref, so (per rule 5) it is parsed by these scripts
directly and never routed through the identifier parser.

**Target detection & diff** (run in order; pre-isolation scripts take no state dir):

| Script | Signature |
|---|---|
| `detect-target.sh` | `[<url\|number>] [--repo <owner/repo>] [--local] [--base <ref>] [--as self\|peer]` — emits `{source:"local"\|"remote", role:"self"\|"peer", …}`. Auto by default (source from branch/PR state; role from PR authorship); flags/arg are overrides. |
| `identify-pr.sh` | `<url\|number> [--repo <owner/repo>]` — resolve a PR to metadata (remote mode only; one network call). |
| `ensure-checkout.sh` | `--pr <n> --repo <owner/repo> [--foreign <bool>] [--sha <head>]` — isolate the PR head in a worktree / blobless clone (remote only). |
| `extract-diff.sh` | `--pr <n> --repo <owner/repo>` (remote)  •  `--local [--base <ref>] [--include-dirty]` (local, no network) — writes the diff + anchorable lines. |
| `select-mode.sh` | `[--deep\|--single]` — reads the extracted diff; emits `{mode:single\|parallel, applicable_handlers, …}`. |
| `post-review.sh` | `--self` (render + hand back, never posts) • `--peer [--submit [--request-changes]]` — `--submit` posts one COMMENT review (the peer default per SKILL.md; bare `--peer` is the dry-run preview), dedups already-posted ids on re-review. `[--findings <file>] [--coverage <file>]` (Coverage block, defaults to `$COVERAGE_FILE`); a local diff is forced to `--self`. |

**Re-review & Slack entry point** (the re-review loop + the Slack-triggered entry):

| Script | Signature |
|---|---|
| `prior-findings.sh` | *(no args; reads `$PR_FILE`)* — recover this skill's own **unresolved** prior comments (matched by the `zeus:review-pr id=` marker) so a re-review addresses them; empty array = first review. |
| `resolve-thread.sh` | `--comment-id <dbid> --thread-id <node_id> --body-file <f> [--resolve]` — reply in a prior thread with the re-verify verdict; `--resolve` closes it (verified fixed/moot). The only place review-pr writes to a thread it opened. |
| `slack-thread.sh` | `parse <permalink>` · `extract-pr` (stdin) · `save --channel C --thread-ts T [--msg-ts M] [--pr-url URL] [--requester UID]` · `get` — pure parse/persist glue for the Slack entry point; the agent makes the `slack_read_thread` / `slack_send_message` calls. |

**Helpers** (no-identifier): `diff-anchors.py` (`<diff-file>` → `{path:[lines]}`; shared
by both `extract-diff.sh` paths), `select-mode.py` (`<diff> <loc-thr> <file-thr> <override>`
→ the mode JSON; invoked by `select-mode.sh` after it resolves thresholds/override),
`render-coverage.sh` (*no args*; reconciles `$SELECT_FILE`+`$SCOUT_FILE`+`$TESTS_FILE`
→ `$COVERAGE_FILE` via `coverage.sh`), `coverage.sh` (shared renderer, symlinked from
`lib/`; normalized JSON → `<details>` block), `lib.sh` (sourced; `resolve_pr`/`resolve_target`).

> The other skills (`propose`, `investigate`, `create-pr`,
> `improve`) carry their own scripts under `skills/<skill>/scripts/`. They follow the
> same house rules (identifiers as `--pr/--repo`, verbs positional, payloads via
> stdin); the detailed per-script reference above covers the PR-workflow pair where
> the parser currently lives. New or edited scripts in any skill should route
> identifiers through `resolve_pr`/`resolve_target` and pass `check-arg-conventions.sh`.

## Structure & shared lib

```
zeus/
├── .claude-plugin/        plugin manifest
├── lib/                   the family's single source for shared code, two kinds:
│   ├── (sourced fragments) pr-ident.sh  lock.sh  run.sh  repo.sh  config.sh
│   │      state.sh (per-worktree state: state_root/atomic_write/json_mutate/json_field)
│   │      original-intent.sh (the PR Original-Intent grammar: emit + parse)
│   │      gh-issue.sh (gh_issue_number/ensure_label — shared by propose + investigate)
│   │      ↳ sourced by each skill's scripts/lib.sh — define functions, no top-level code
│   ├── (vendored scripts)  journey.sh  journey-marker.sh  preflight.sh
│   │      watermark.sh  preview.sh
│   │      coverage.sh (scout run/skip decision → collapsible Coverage <details> block)
│   │      ↳ symlinked into skills' scripts/
│   ├── config.defaults.json          shipped config defaults (the only config in the repo)
│   └── check-arg-conventions.sh      the CLI-convention lint (run from anywhere)
├── agents/                the family's shared sub-agent definitions (one per archetype,
│   │                      referenced by name — same "define once" rule as lib/):
│   ├── cold-reader.md     text-only critic/persona (NO tools) — judges a rendered doc
│   │                      from the body alone. Used by propose Stage-1 + steelman,
│   │                      investigate coherence reader.
│   ├── diagnostician.md   read-only analyzer (Read/Grep/Glob/LSP; NO Bash/Edit/Write) —
│   │                      returns findings, never writes. Used by review-pr per-lens
│   │                      fan-out, address-pr check/thread diagnosis, propose grounding +
│   │                      implementer persona.
│   └── scout.md           cheap triage router (haiku default) — sizes a fan-out + picks
│                          model tiers. Used by review-pr + propose Stage-0.
├── hooks/hooks.json
└── skills/<skill>/
    ├── SKILL.md           the behavioral contract (read this for flow)
    ├── scripts/           the skill's CLI (each sources scripts/lib.sh)
    │   └── lib.sh         a thin shim: sources the lib/ fragments it needs + the
    │                      skill's own STATE_DIR / helpers (NO copied family helpers)
    ├── handlers/          (address-pr) per-operation playbooks
    └── references/        long-form contracts
```

- **One copy of every shared helper, in `zeus/lib/`.** `resolve_pr`/`resolve_target`
  (pr-ident.sh), `with_lock` (lock.sh), `run` (run.sh), and the repo/
  base-branch helpers (repo.sh) are defined ONCE and **sourced** by each skill's
  `lib.sh` — never pasted (the old per-skill copies drifted; `check-arg-conventions.sh`
  rule [4] now forbids re-defining them). The vendored *scripts* (journey.sh, …) are
  **symlinked** into `scripts/`, so editing `lib/` updates every skill at once.
- **Config: one home, nothing committed.** `lib/config.sh` reads merged config —
  `env ZEUS_<KEY>` > repo `.git/zeus/config.json` > user `$ZEUS_CONFIG_DIR/config.json`
  (default `~/.config/zeus/`) > shipped `lib/config.defaults.json`. Per-concern blobs
  (Slack handles, ping policy, Confluence) live as their own files under
  `$ZEUS_CONFIG_DIR/<concern>/`. The repo holds only `*.default.json` templates.
- **Per-worktree state** lives under `.git/<skill>/` (e.g. `.git/address-pr/`),
  isolated across worktrees, never committed.
- **One definition per sub-agent archetype, in `zeus/agents/`.** The skills fan work
  out to sub-agents (Task/Agent tool) for three recurring jobs — a text-only doc
  **critic** (`cold-reader`), a read-only repo **diagnostician**, and a cheap triage
  **scout**. Each is defined once as a plugin agent and invoked **by name** —
  `zeus:cold-reader`, `zeus:diagnostician`, `zeus:scout` — the same "define once,
  reference by name" rule as `lib/`, never re-specified inline per call site. Two
  properties are **structural, not prose**: `cold-reader` ships `tools: ""` (no repo
  or tool access — it reasons over the body it's handed), and `diagnostician` ships a
  read-only toolset (Read/Grep/Glob/LSP, **no Bash/Edit/Write**) so "diagnose only,
  never mutate" can't be violated — it **returns** findings and the orchestrator is the
  sole writer. Models are a per-invocation override (haiku→sonnet→opus per the
  `review.*` tiers), so the dynamic tiering keeps working over one static definition.
  A skill grants the capability by listing `Task Agent` in its `allowed-tools`
  (`review-pr`, `address-pr`, `propose`, `investigate`, `improve` do; the terminal
  `create-pr`/`request-review` don't). Adding a new fan-out uses an existing
  archetype, or a new file in `agents/` — never an ad-hoc inline agent spec.

## House conventions

- Skills call skills **by name** with JSON contracts — never another skill's scripts
  by path. GitHub / `gh` is the source of truth; the PR body is never a state store
  (except the hidden journey marker, which is durable cross-session context).
- **Script I/O contract:** machine output is JSON on **stdout**; logs and human text
  go to **stderr**; errors are `{"error":"…"}` on stderr; exit `0` ok / `1` runtime /
  `2` usage. Identifiers route through `resolve_pr`/`resolve_target`; sub-commands are
  positional; bulk payloads come via stdin or `--from <file|->`; refs/branches never
  go through the identifier parser.
- **Shared helpers are sourced from `lib/`, never copied** into a skill. Config is read
  via `config.sh`, never hard-coded; user/repo config is never committed.
- **Optional external integrations have one owner, reached by name.**
  Confluence lives in `propose`; SonarQube / Vercel are `address-pr` handlers. Other
  skills never post to those directly or call the owner's scripts by path — they
  invoke the owner skill with a JSON contract, so its `allowed-tools` are the *only*
  place that integration's MCP tools appear (e.g. `address-pr` carries no Slack tools
  — it hands the verdict to `request-review`). **Slack is owned per _direction_, not
  by a single skill:** `request-review` owns **outbound** reviewer notification
  (broadcast pings to code owners, per-SHA dedup); `review-pr` owns the **threaded
  reply to a review it was explicitly summoned for via a Slack link** — it reads that
  thread and posts one informational reply in it (`reply_broadcast` stays false),
  never a broadcast. Both keep the house split — scripts format/persist
  (`*-message.sh`, `slack-thread.sh`), the agent makes the MCP call — so those two
  skills are the only places Slack tools appear.
  Each integration is **MCP-gated and degrades gracefully**: MCP reachability can't
  be probed from a script, so the owning skill confirms it live and falls back to the
  GitHub-only path when it's absent (never a hard failure). A *new* integration
  (e.g. Jira) follows the same shape — pick an owner, don't add a posting lib.
- **Stay agnostic:** no language/stack/CI assumptions — detect at runtime and degrade
  gracefully; resolve the base branch via `repo.sh` (never hard-code `main`/`master`).
- When you add or change a script's CLI, update its `Usage:` header, the call-sites in
  the owning `SKILL.md`, and run `bash zeus/lib/check-arg-conventions.sh`.
