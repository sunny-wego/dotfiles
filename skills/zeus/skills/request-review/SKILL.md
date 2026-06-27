---
name: request-review
description: >-
  Notify an existing PR's code owners that it is ready for review, and re-ping
  them in-thread when the PR changes. Use after a PR is
  settled / ready for review, or to re-request review after pushing changes. Triggers
  on: "ask for review", "ping reviewers", "request review in slack", "request a
  re-review", "tell the reviewers it's ready", "notify reviewers". This only
  *notifies* an already-open PR's reviewers — it does not create or modify the PR
  (authoring/opening is /zeus:create-pr) or fix its checks (/zeus:address-pr).
  Pairs with /zeus:address-pr (which produces the readiness verdict) and
  /zeus:create-pr, but runs standalone.
license: MIT
compatibility: Requires git, gh (GitHub CLI) authenticated, jq. Slack MCP for sending.
metadata:
  author: sunnywong
  version: "1.0"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) AskUserQuestion mcp__plugin_slack_slack__slack_send_message mcp__plugin_slack_slack__slack_send_message_draft mcp__plugin_slack_slack__slack_search_users
---

# Review Handoff

Notify a PR's **code owners** that it is ready, and keep them in sync with a threaded re-review when it
changes. The skill has two states per repo: **ping the code owners** (enabled) or **ping no-one**
(disabled) — there is no single primary reviewer. **Verdict-agnostic by design:** it never decides "is the
PR ready?" — an *arbiter* (e.g. `/zeus:address-pr`'s `ready-for-review.sh`) computes that and pipes the
verdict in. This skill owns only the *notification* concern: policy (which repos), the handle map, per-SHA
dedup, the Slack thread, and formatting the message. The agent performs the actual Slack send; the scripts
only format.

## The verdict contract (input)
Callers pipe a readiness verdict JSON (the shape `ready-for-review.sh` emits):
`{ ready, blockers, warnings, head_sha, pr_url, pr_number, title, branch, linked_issue? }`.
Every entry point takes it via `--from <file>` or `--from-stdin`. This skill computes nothing about
CI/merge/review state itself — feed it from an arbiter, a CI job, or a test fixture.

## Invocation contract (for sibling skills)

Sibling skills (e.g. `/zeus:address-pr`) invoke this skill **by name** — never its scripts by path. The
invocation carries data only:

1. **The verdict JSON** (shape above) — required.
2. **A persisted thread record** (optional): `{channel, thread_ts}` recovered from durable storage the
   *caller* owns (e.g. a PR-body journey marker; a legacy `target` field is ignored). When present and
   this worktree's thread state is missing for the PR, seed it first — `scripts/thread-restore.sh`
   (fill-gaps-only) — *before* formatting the envelope, so dedup and threading see the restored history.

There is no separate "is a ping owed?" pre-check for callers: the returned envelope IS the answer
(`should_send:false` + `skip_reason: already_pinged_at_<sha>` / disabled repo / `not_ready`), so invoking
on an already-handled SHA is always a safe no-op. `ping-gap.sh` remains for in-skill use and for a human
running a standalone probe — sibling skills should rely on the envelope instead.

## Modes

| Invocation | Intent |
|---|---|
| `ping`      | Initial "ready for review" message (formats an envelope from the verdict) |
| `re-review` | Threaded "please re-review, here's the delta since your last look" |
| `status`    | Print the stored thread/policy for a PR (read-only) |

## Preflight

Verify dependencies before doing any work (same engine + flow as the rest of the family):

```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo: under zsh, echo expands the escaped \n in .report and corrupts the JSON
```

On `.ok == false`, present each `.remediation[]` entry and offer to install; `preflight.sh --fix`
installs the `auto:true` entries (interactive steps like `gh auth login` are listed, never auto-run).
The Slack MCP can't be script-checked (only the harness sees the tool list) — if the send tools are
missing, fall back to `draft` text the user can paste, and say so.

## Initial ping
The skill pings the PR's **code owners** — there is no primary-reviewer flag to
construct; `ready-slack-message.sh` resolves the owners itself. Just resolve the
channel from the policy and format the envelope:
```bash
export SLACK_REVIEW_CHANNEL=$(bash ${CLAUDE_SKILL_DIR}/scripts/auto-ping.sh "$OWNER/$REPO" | jq -r '.channel // empty')
ENVELOPE=$(ready-for-review.sh --pr "$PR" --repo "$OWNER/$REPO" \
  | bash ${CLAUDE_SKILL_DIR}/scripts/ready-slack-message.sh --from-stdin --repo "$OWNER/$REPO")
```
Read `ENVELOPE.should_send` (`false` ⇒ `skip_reason` `not_ready` / `already_pinged_at_<sha>`; `true` ⇒
send). On `true`, the agent sends and stamps the thread (capture the channel **id** + `ts` from the send):
```
slack_send_message(channel_id=ENVELOPE.channel, message=ENVELOPE.text)        # or _draft
```
**Send `ENVELOPE.text` verbatim — it is the complete message.** Do not append CI/check status, SonarQube
or CodeRabbit notes, "heads-up" caveats, or any prose narrating the verdict's `blockers`/`warnings`: those
fields drive only the `should_send` gate, never the message body. The message is a deliberately terse
one-liner by design; if a PR isn't clean enough to ping with that line, the gate returns
`should_send:false` — it is never the message's job to explain why a check is red.
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/review-thread.sh set "$PR" "$(echo "$ENVELOPE" | jq -r .head_sha)" \
  --thread-ts "$TS" --channel "$CHANNEL_ID"
```

## Re-review
```bash
RR=$(ready-for-review.sh --pr "$PR" --repo "$OWNER/$REPO" \
  | bash ${CLAUDE_SKILL_DIR}/scripts/re-review-message.sh --pr "$PR" --repo "$OWNER/$REPO" --from-stdin)
```
`should_send: true` only when: the repo's `auto-ping.json` has `re_review: true`, a prior ping thread
exists, the verdict is ready, and the head SHA advanced past the last reviewed one. The code owners are
**re-resolved for the current head** (the changed-path set may have moved them). Post a **threaded** reply
(`thread_ts` from `RR`) and re-stamp the reviewed SHA (`review-thread.sh set "$PR" <head_sha>` — thread
persists). See `references/reviewer-ping.md` for the full contract, policy, and skip reasons.

## Policy, handles, scoping

Config is two-layered so user policy survives skill updates: shipped defaults live in the skill dir,
user edits live in `${XDG_CONFIG_HOME:-~/.config}/request-review/` (override wins per key). All write
commands target the override; the in-skill files are never mutated.

- **Per-repo ping policy** — `enabled`, `mode` (`send`/`draft`/`ask`), `channel` (a Slack `C…` ID),
  `re_review`. Repos absent from both layers ⇒ disabled. Read with
  `scripts/auto-ping.sh <owner/repo>`; opt a repo in with
  `scripts/auto-ping.sh enable <owner/repo> --channel <C…> [--mode send|draft|ask] [--re-review]`
  (and `disable` to turn it off). Two states only: **enabled ⇒ ping the PR's code owners** (resolved per
  changed path), **disabled ⇒ ping no-one**. There is no single primary reviewer. There is no built-in
  default channel: an unconfigured repo with no `$SLACK_REVIEW_CHANNEL` fails loudly rather than routing
  somewhere surprising.
- **Handle map** (GitHub login → Slack `U…`) — `slack-handles.default.json` (shipped) merged under
  `slack-handles.json` (override); manage with `scripts/handles.sh` (`get`/`list` read merged,
  `set`/`remove` edit the override, `bootstrap-template` pre-keys from CODEOWNERS).
  `resolve-reviewers.sh` maps a PR's requested reviewers (or CODEOWNERS) to mentions.
- Per-SHA dedup + thread continuity live in `scripts/review-thread.sh` (`.git/request-review/`).

## Delivery semantics
At-least-once, not exactly-once: stamp immediately after the send returns OK. If the process dies between
send and stamp, the next pass may re-ping the same SHA (tolerable; stamping is idempotent). Never
stamp-before-send. Full detail in `references/reviewer-ping.md`.

## Independence
Runs standalone: feed any verdict-shaped JSON. With `/zeus:address-pr` installed, address-pr pipes its verdict
at `settled` and on watch passes. With no repo opted into the ping policy, every entry point no-ops
(`should_send:false`) — installing this skill changes nothing until a repo opts in.

The boundary runs both ways: arbiters never read this skill's state, and they never call this skill's
scripts by path — they invoke the **skill by name** with the verdict (see Invocation contract above), and
the returned envelope answers "is a ping still owed?" (`should_send` / `skip_reason`). This keeps an
arbiter's verdict a pure function of GitHub state whether or not this skill is installed.
(`scripts/ping-gap.sh <pr> <owner/repo> <head_sha>` → `{enabled, gap, reason}` still exists as a
standalone human-runnable probe.)

## Scripts & resources
| Path | Purpose |
|---|---|
| `scripts/lib.sh` | per-worktree thread state dir + `with_lock` |
| `scripts/ready-slack-message.sh` | initial-ping envelope from a verdict (`--from`/`--from-stdin`) |
| `scripts/re-review-message.sh` | threaded re-review envelope from a verdict (re-resolves the code owners for the current head) |
| `scripts/slack-envelope.sh` | shared gate + mention helpers |
| `scripts/resolve-reviewers.sh` | PR reviewers / CODEOWNERS → Slack mentions |
| `scripts/handles.sh` + `slack-handles.default.json` | GitHub→Slack handle map (shipped defaults; user override in `~/.config/request-review/slack-handles.json`) |
| `scripts/auto-ping.sh` + `auto-ping.json` | per-repo ping policy (shipped template; user override in `~/.config/request-review/auto-ping.json` — `enable`/`disable` write there) |
| `scripts/review-thread.sh` | per-SHA dedup + Slack thread state |
| `scripts/ping-gap.sh` | "is a ping still owed for this head SHA?" — the notification-gap probe arbiters call at their report stage (keeps their verdicts pure) |
| `scripts/thread-restore.sh` | re-seed thread state from a persisted record (e.g. a PR-body marker) — fills gaps only |
| `references/reviewer-ping.md` | full contract: policy, scoping, re-review, delivery semantics |
