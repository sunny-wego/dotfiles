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

`scripts/harvest.sh` reads these (no transcript parsing). All per-worktree under `$(git rev-parse --absolute-git-dir)`:

| Signal | Path | What it tells you |
|---|---|---|
| Iteration depth + handler outcomes | `address-pr/state.json` (`.iteration`, `.outcomes[]`) | how many fix cycles the PR took |
| Last check snapshot | `address-pr/status.json` (`.failed[]`, `.pending`, `.all_passed`) | which checks blocked, how often |
| Reviewer-ping markers | `request-review/stop-nudged-<sha>` (one file per nudged head) + `review-thread.json` | premature pings / re-pings: multiple distinct SHAs = the head moved under the reviewer; a nudge on a SHA that later failed = a premature-ping signal |
| PR pointer | `journey/pr.json` | the PR number/url to query `gh` for full history |
| Fix-cycle markers | `git log --grep "address-pr iteration"` + `git log --merges` | cycle count and merge/reset churn |

The agent cross-references these against the conversation: e.g. "3 distinct nudge SHAs (signal) + the user said the ping fired too early (conversation) → premature-ping, real, high-severity."
