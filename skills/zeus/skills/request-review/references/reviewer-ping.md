# Reviewer ping (optional)

Read this when the user wants to notify a PR's code owners that a settled PR is ready, or when you need the
GitHub→Slack handle map. None of this is on the happy path — `address-pr` never pings unless asked.

The skill has exactly **two states per repo**: ping the PR's **code owners** (enabled) or ping **no-one**
(disabled). There is no single primary reviewer.

## Contract

The script formats a send-ready envelope; the **agent** sends via the Slack MCP; the agent stamps the SHA
after a successful send. This split keeps the formatter independently testable and never silently posts to
Slack as a side effect of running tests or smoke checks.

```bash
export SLACK_REVIEW_CHANNEL=$(bash ${CLAUDE_SKILL_DIR}/scripts/auto-ping.sh "$OWNER/$REPO" | jq -r '.channel // empty')
ENVELOPE=$(echo "$READY" | bash ${CLAUDE_SKILL_DIR}/scripts/ready-slack-message.sh --from-stdin --repo "$OWNER/$REPO")
```

The recipients are the PR's **individual code owners**, resolved by `resolve-reviewers.sh`: it uses the
PR's pending review requests if any, else falls back to CODEOWNERS-by-changed-path. `@org/team` usergroups
(subteams) are **excluded** — the skill pings the people who own the code, not org groups — so a path owned
solely by a team resolves to no one. Each owner login is mapped to a Slack ID through the handle map and
renders as `<@U…>`; unmapped owners degrade to `<https://github.com/<login>|@<login>>` links (named, but no
actual ping). The owners lead the message; the envelope also exposes `.reviewers[]`. There is no
`--reviewer` flag and no thread `target`: every thread is owner-directed.

Dedup is per-SHA via `review-thread.sh`; channel resolution is the `SLACK_REVIEW_CHANNEL` env var (a Slack
channel **ID**, set by the caller from the repo's `auto-ping.json` policy). No channel ⇒ the formatter
exits 3 with a configuration hint — there is no baked-in default destination.

Read `ENVELOPE.should_send`:

- `false` with `skip_reason: "not_ready"` — the PR isn't actually ready; refuse to send.
- `false` with `skip_reason: "already_pinged_at_<sha>"` — owners were already notified at this head SHA.
  Don't re-ping. The stamp resets automatically on the next commit.
- `true` — call the Slack MCP tool with `ENVELOPE.channel` and `ENVELOPE.text`:
  ```
  slack_send_message(channel=ENVELOPE.channel, text=ENVELOPE.text)
  ```
  **Send `ENVELOPE.text` verbatim.** It is the whole message — a deliberately terse one-liner. Do not add
  CI/check status, SonarQube or CodeRabbit notes, "heads-up" caveats, or any narration of the verdict's
  `blockers`/`warnings`; those fields gate `should_send` only, never the body. The message's job is "this
  PR is ready, here's the link" — not "here's why a red check is fine." Prefer `slack_send_message_draft`
  when the user wants to review the wording in Slack first. **After** the
  send returns OK, stamp the SHA (and the thread id/ts so a re-review can thread under it) so the next
  probe knows to skip:
  ```bash
  bash ${CLAUDE_SKILL_DIR}/scripts/review-thread.sh set "$PR_NUMBER" "$(echo "$ENVELOPE" | jq -r .head_sha)" \
    [--thread-ts "$TS" --channel "$CHANNEL_ID"]
  ```

## Delivery semantics (send-then-stamp)

The Slack send is agent-side (MCP) and the dedup stamp is a separate step, so the two aren't one
transaction. The contract is **at-least-once, not exactly-once**: stamp *immediately* after the send
returns OK. If the process dies between send and stamp, the next probe — seeing no advanced stamp — may
re-ping the same SHA. That's a tolerable failure mode (a duplicate "ready for review" beats a missed one),
and the stamp is idempotent (re-stamping the same SHA is a no-op), so recovery is just "stamp again". Do
not invert the order (stamp-before-send) — a failed send would then silently suppress the ping forever.

## Auto-ping policy (per repo)

By default the ping is manual — it only happens when the user asks. To make a specific repo ping its code
owners automatically the moment a PR reaches `settled`, enable it:

```bash
scripts/auto-ping.sh enable <owner/repo> --channel <C…> [--mode send|draft|ask] [--re-review]
```

```json
{
  "repos": {
    "wego/agent-factory-lab": { "enabled": true, "mode": "send", "channel": "C0B365795HU", "re_review": false }
  }
}
```

- `enabled` — when `true`, the Report step pings the repo's **code owners** automatically. `false`/absent ⇒ no-one.
- `mode` — `send` (post immediately), `draft` (post a Slack draft for the human to send), or `ask`
  (AskUserQuestion, pre-selected to send).
- `channel` — a Slack channel **ID** (`C…`, not a `#name`): the send MCP wants an ID, and storing it
  avoids a `slack_search_channels` round-trip on every ping.
- `re_review` — see below.

`scripts/auto-ping.sh <owner/repo>` reads this and prints `{enabled, mode, channel, re_review}`; a repo
absent from the file reads as `{enabled:false}`. Auto-ping still goes through the **same gates** as a
manual ping — `should_send` skips a not-ready PR, and per-SHA dedup means it fires at most once per head
SHA. So "auto-send" means "automatically attempt once the PR is genuinely ready and not already pinged,"
not "post on every run." Because code owners are humans, enabling a repo means an unattended run *will*
ping them — that is the explicit, per-repo opt-in.

## Re-review

When `re_review: true`, the skill re-pings the code owners after the first review without a manual re-ping.
On a new head SHA it **re-resolves** the owners (the changed-path set may have moved them) and posts a
threaded reply under the original ping. It is deliberately narrow: it fires only when a prior ping thread
exists and the head advanced, so it never spams.

`scripts/re-review-message.sh <pr> <owner/repo>` returns `should_send: true` only when: the repo has
`re_review:true`, a prior ping thread exists, the PR is ready again, **and** the head SHA advanced past the
last reviewed SHA. The agent then posts a **threaded** reply (`slack_send_message` with `thread_ts` from
the stored thread) naming the delta since the last review, and re-stamps the reviewed SHA (thread
preserved) so the next push re-arms exactly once. Entry points: automatically each Watch pass, or on demand
via `/zeus:address-pr re-review`.

The stored `channel` is the channel **ID** captured from the initial send's response (the `C…` id, not the
`#name`). `thread_ts` is only valid against the channel the parent message lives in, so threading off the
resolved id — rather than re-resolving a name that could be ambiguous or renamed — keeps the reply in the
exact same place.

`skip_reason` values (all no-ops): `re_review_disabled`, `no_initial_ping`, `no_head_sha`, `not_ready`,
`already_requested_at_<sha>`.

## Handle map

One file: `<skill-dir>/slack-handles.default.json`. Lives alongside the skill so anyone installing it
picks up the mappings for free; updates land in the same file and travel with the skill repo. Keys are
GitHub logins (`alice-wego`); values are Slack `U…` user IDs. (Team/usergroup owners aren't pinged, so
`@org/team` handles don't need a mapping.)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/handles.sh list                  # print the map
bash ${CLAUDE_SKILL_DIR}/scripts/handles.sh get <gh-login>        # read one
bash ${CLAUDE_SKILL_DIR}/scripts/handles.sh set <login> <Uxxx>    # upsert (validates id shape)
bash ${CLAUDE_SKILL_DIR}/scripts/handles.sh remove <login>        # drop one
bash ${CLAUDE_SKILL_DIR}/scripts/handles.sh missing-from-codeowners
bash ${CLAUDE_SKILL_DIR}/scripts/handles.sh bootstrap-template
```

The agent never writes JSON directly — every mutation goes through `handles.sh set`, which validates the
Slack ID shape (`U…/W…/S…/T…` + 7-19 alphanumerics) so a typo can't silently produce a broken
`<@U99FAKE>` mention.

### Bootstrap recipe (agent-driven)

When `resolve-reviewers.sh` surfaces entries with `slack_id: null`, or for a new owner:

1. `handles.sh missing-from-codeowners` lists GitHub logins from `.github/CODEOWNERS` that aren't mapped yet.
2. For each missing login, query Slack via `mcp__plugin_slack_slack__slack_search_users` (searching by
   `<login>@<org>.com` is the highest-precision starting point; fall back to display-name search if the
   email is private), confirm ambiguous matches with the user, then run `handles.sh set <login> <Uxxx>`.
   (Team owners are not pinged, so `@org/team` entries don't need mapping.)
3. Re-run `resolve-reviewers.sh`; the next render uses the new entries.

## GraphQL stale-fetch detail

When a run's final `fetch-review-comments.sh` reports `consistency.ok == false`, GraphQL's `reviewThreads`
index lagged REST during the run. This is why the report adds the caveat
`"review fetch may have been stale; monitor will re-verify within 60s"`: monitor mode's first probe covers
the full run window (`last_seen = .started_at`), so anything the stale fetch missed surfaces there.
