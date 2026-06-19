# The improvement contract

The rules that keep `zeus:improve` from making zeus worse. Read this before grading or landing anything.

## The two tiers (the core discipline)

Every learning is **exactly one** of:

- **skill-level** — true and useful on *any* repo, regardless of language, framework, CI provider, or repo conventions. Lands in the **zeus source**. Example: *"don't ping a reviewer while a gating check is still pending"* — universal.
- **repo-level** — depends on *this* repo's tools, config, conventions, or quirks. Lands in **that repo's own guidance** (closest `AGENTS.md`/`CLAUDE.md`, or `.zeus/notes.md`), committed via the repo's normal PR flow. Example: *"SonarQube is the de-facto merge gate here even though the branch ruleset requires no status check"* — only true for this repo.

Why the split matters: zeus is one body of skills reused across every repo. If a repo/tech specific leaks into it, every other repo inherits a wrong assumption. Keeping zeus agnostic is what lets it be trusted everywhere; repo facts belong with the repo so the next session there starts already knowing them.

### The agnostic test (apply to every candidate)

Ask: *"Would this be true and useful on a Rust repo with GitLab CI and no SonarQube?"*
- **Yes** → skill-level.
- **No** → repo-level.
- **Reclassify, don't force.** If a candidate you called "skill" smuggles in a tool/language/repo specific, it is repo-level — or **split** it: the *generic mechanism* is skill-level, the *specific value* is repo-level. (E.g. "teach address-pr to treat configured checks as required" is skill-level; "SonarQube is one of those checks here" is the repo-level value.) A skill-tier fix that can't be expressed agnostically does not enter zeus.

## Real over imaginary

Only land fixes for friction with **real evidence** in the ledger. A friction the user explicitly flagged, or one the durable signals show recurring, is real. A failure mode you can imagine but haven't observed is not — do not build for it. Evidence lives in each ledger entry's `evidence[]`; the conversation (the *why*) is the strongest evidence, the signals (counts) corroborate.

## Ripe = worth landing now

An entry is **ripe** when `count >= 2` (it recurred across sessions) **OR** `severity == "high"` (one occurrence is enough when the cost is large — e.g. a wrong action toward a human). Until ripe, a learning just accumulates; landing premature one-offs is how tooling rots.

## Validate before shipping

A fix lands only after a **concrete** check shows it works — and the check must itself be agnostic for a skill-tier fix:
- a logic unit-test (e.g. feed sample inputs to a guard and assert the decision), or
- a tool probe (e.g. `mcp__sonarqube__analyze_code_snippet` to confirm a rule reproduces).

If validation fails or is only partial, `mark deferred` with the evidence rather than shipping half-working. (Real case: the Sonar diff-sweep was deferred because `analyze_code_snippet` reproduced structural rules but was blind to the React-context rule that motivated it.)

## Durable destination, human confirms

- skill-tier → the resolved zeus **source** (`pwd -P`, not the symlinked install) + `~/.claude/hooks/` for hooks; bump the target skill's `metadata.version`.
- repo-tier → the repo's working tree, via its own PR.
- Neither is silently committed, and **every landing is confirmed by the user first** — `zeus:improve` edits the user's own tooling, so it asks before each change.
