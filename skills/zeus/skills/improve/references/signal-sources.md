# Harvest map — where session friction comes from

Two sources, in priority order. (a) is the richest; (b) quantifies it.

## (a) The live conversation — PRIMARY, qualitative (the *why*)

When `zeus:improve` runs in or near the session, the full dialogue is already in the agent's context. Reflect on it directly — this is where the highest-signal learnings live, because it carries intent, not just mechanics:

- **User corrections and the principle behind each** — the most valuable signal. ("language-agnostic", "skill-vs-repo split", "real-vs-imaginary", "validate-before-ship" were all corrections in the session that designed this skill.)
- **Approaches proposed and then rejected** — and why (a rejected approach is a learning about what *not* to do).
- **Friction the user expressed** — confusion, repeated re-steering, "no, I meant…", scope changes.
- **Decisions made** — so they don't get re-litigated next time.

Optionally invoke `/reflect` for a structured pass, then layer the zeus-specific grading/tiering/landing on top.

**Cold-start caveat:** if run in a *fresh* session about a past one, the conversation isn't in context. Degrade to (b) below + a best-effort `/reflect` over the transcript JSONL (brittle — see SKILL.md). This is why the skill is best run while the session's context is still live.

## (b) Durable signals — SECONDARY, quantitative (the recurrence/severity)

`scripts/harvest.sh` reads these (no transcript parsing). They span the whole
issue→code→PR→review family, not just the PR pair. All per-worktree under
`$(git rev-parse --absolute-git-dir)`:

| Source skill | Signal | Path | What it tells you |
|---|---|---|---|
| `propose` | Issue pointer | `journey/issue.json` (`.number`, `.url`, `.title`) | an issue was opened; query `gh` for revision/amend churn |
| `investigate` | Active epic + report | `journey/investigation/epic` (+ `…/report`) | an investigation/postmortem was maintained |
| *(the branch)* | Spec-commit count | `git log --grep "#<issue>"` | how many commits referenced the spec issue (code-effort proxy) |
| `create-pr` | PR pointer | `journey/pr.json` | the PR number/url to query `gh` for full history |
| `address-pr` | Iteration depth + handler outcomes | `address-pr/state.json` (`.iteration`, `.outcomes[]`) | how many fix cycles the PR took |
| `address-pr` | Last check snapshot | `address-pr/status.json` (`.failed[]`, `.pending`, `.all_passed`) | which checks blocked, how often |
| `address-pr` | Fix-cycle markers | `git log --grep "address-pr iteration"` + `git log --merges` | cycle count and merge/reset churn |
| `request-review` | Reviewer-ping markers | `request-review/stop-nudged-<sha>` (one file per nudged head) + `review-thread.json` | premature pings / re-pings: multiple distinct SHAs = the head moved under the reviewer; a nudge on a SHA that later failed = a premature-ping signal |
| `review-pr` | Findings raised | `review-pr/findings.json` (count + `confirmed`/`high_severity`/`by_status` breakdown) | how much the last review surfaced — an authoring-side proxy: many confirmed-high findings = the diff let a lot through (a signal *about* `create-pr`/`address-pr`, cross-checked against the conversation) |
| `review-pr` | Re-review carryover | `review-pr/prior.json` (unresolved threads from earlier rounds; `still_confirmed`) | non-empty = the PR took another review round — reviewer-side churn, the analog of `address-pr`'s iteration depth; still-confirmed carryover is the sharper signal |
| `review-pr` | Scout coverage | `review-pr/scout.json` (`.difficulty`, `.recommend`, `.skipped[].lens`) | which floor lenses the Stage-0 scout dropped (each with a reason): a lens repeatedly skipped across sessions is a coverage-gap signal; repeated high difficulty is a spend signal |

The agent cross-references these against the conversation: e.g. "3 distinct nudge SHAs (signal) + the user said the ping fired too early (conversation) → premature-ping, real, high-severity."

**Coverage caveat:** the issue-side skills leave thinner durable trails than the PR
pair (a pointer, not an iteration log), so a `propose`/`investigate`
candidate often rests mostly on conversation evidence (source a) plus a `gh` query
off the pointer. That's still *real* — it just reaches "ripe" via `severity:high`
or repeated logging across sessions rather than a rich per-run signal count.
