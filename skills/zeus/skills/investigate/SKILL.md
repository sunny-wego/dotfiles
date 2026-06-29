---
name: investigate
description: >-
  Run a structured, evidence-driven investigation end to end as a GitHub issue — open and maintain
  an investigation issue (a dashboard whose progress block re-renders itself) plus an OPTIONAL
  reproducible evidence report, capture findings as numbered evidence items, tie the issues/PRs you
  create into it and the team board, and check where it stands. For production incidents,
  regressions, data anomalies, perf digs — any inquiry that should be captured durably (incidents
  are one kind, not the only kind). Triggers on: "investigate X", "open an investigation / postmortem
  for X", "we have an incident", "track this under the investigation", "was PR #N / the fix
  effective", "did X hold up in prod", "record this finding", "where does the investigation stand".
argument-hint: "[new | hypothesis | evidence | conclude | remediate | status | link | report | close]"
license: MIT
compatibility: Requires git and gh (GitHub CLI) installed and authenticated; jq. Project-board attach needs gh `project` scope (degrades gracefully without it).
metadata:
  author: sunnywong
  version: "0.2"
allowed-tools: Bash(gh:*) Bash(git:*) Bash(bash:*) Bash(jq:*) Read Write Edit AskUserQuestion Task Agent
---

# Investigate — structured investigation & evidence report

One skill for the whole life of an investigation — incident or otherwise. It maintains a few linked
surfaces and lets GitHub do the progress-tracking, with **one block the skill re-renders for you**:

- **Investigation issue = the front door / dashboard.** A **human-owned zone** (health links,
  closing criteria, narrative) plus ONE **managed progress block** the skill regenerates on demand
  (`status --write`) — see "The managed status block". Replaces hand-maintaining the work-items list.
- **Evidence report (optional) = the durable record.** `docs/investigations/<date>-<slug>.md`,
  governed by the **reproducibility contract** (`references/reproducibility-contract.md`) — every
  claim is a re-runnable query or a labelled *recorded* snapshot. **Opt-in:** graduate to it when the
  investigation warrants a durable writeup (an incident post-mortem is the canonical case).
- **Project board (optional) = what's next.** A saved *view* filtered to the investigation.

Per-investigation state (issue number, report path, project, view) lives in a per-worktree file via
`scripts/investigate-state.sh`. `/zeus:investigate` is **general** — it does *not* auto-label sibling PRs
or publish to the cross-skill store; fix PRs link in precisely via the work items you attach (and, in
a later phase, via `remediate`). It works standalone.

## Preflight

Verify dependencies before the first mutation:

```bash
PF=$(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh) || true
printf '%s\n' "$PF" | jq -r .report   # printf, NOT echo (echo corrupts the JSON under zsh)
```

On `.ok == false`, present the `.remediation[]` fixes and re-check with `preflight.sh --fix`; proceed at
`ok: true`. Full flow: **`zeus/lib/PREFLIGHT.md`**. Skill-specific: a `gh-scope-project` warning is
**non-blocking** — it's the "degrade to issues-only" case below; surface the `gh auth refresh -s project`
remediation once and continue.

## Routing — decide the mode, don't make the user state it

When invoked without an explicit mode, read the active investigation first, then the user's intent.
Confirm only when the two disagree. **An explicit mode always wins** (`new` / `hypothesis` / `evidence`
/ `conclude` / `remediate` / `status` / `link` / `report` / `close`).

```
active = ${CLAUDE_SKILL_DIR}/scripts/investigate-state.sh get   # the investigation open in THIS worktree, or empty

if no active investigation:
   • user is describing a problem / "track this" / "investigate X"        → new
   • user reports a finding but nothing is open to attach it to           → offer: open one now
     (capture as E1), OR search open `investigation`-labelled issues and ask which one
if an investigation #N is active:
   • user proposes a theory / "maybe it's X" / "could be Y"               → hypothesis
   • user reports a result / "did the fix work" / "I found …"             → evidence (tag the hypothesis)
   • user settles a theory / "so it WAS the timeout" / "ruled that out"   → conclude <Hk> <verdict>
   • a hypothesis is confirmed and needs a fix                            → remediate <Hk>
   • user clearly describes a DIFFERENT problem                           → confirm: part of #N, or new?
```

Triggering (does the skill fire at all) is the description's job; routing (which mode) is the
procedure above. They are separate — a finding-shaped message with an open investigation is the common
path and routes to `evidence` cleanly.

## Mode: new

Stand up the structure once.

1. Confirm scope and a short slug with the user (e.g. `expedite-timeouts`). Pick a date from
   `git log -1 --format=%cd` or ask — never fabricate a date.
2. Create the investigation issue from `assets/epic-dashboard.md` (substitute title, slug, the
   health-dashboard links you know about). Label it `investigation`. The template ships with the
   **managed progress block** delimiters and a human-owned health/criteria/narrative zone:
   `${CLAUDE_SKILL_DIR}/scripts/ensure-epic.sh --slug <slug> [--report <path>] [--title "…"]`
   It creates the issue, adds it to the board, writes `investigate-state.sh` state, and **prints the
   `parent-issue:#N` view URL to save once** (view creation is UI-only — don't pretend to automate it).
3. **Report is opt-in.** Scaffold a durable report from `assets/report-template.md` →
   `docs/investigations/<date>-<slug>.md` and pass `--report <path>` only when the investigation
   warrants a written record (an incident post-mortem, anything that'll be reviewed). A quick
   investigation skips it — the issue + evidence comments suffice.
4. Offer to install the auto-link Stop hook (see "Mode: link"). It edits `settings.json`, so confirm
   first or hand them `hooks/INSTALL.md`.

Body zones: **health** is *links* to live dashboards + last-known values (human-owned — the skill
can't run those queries), **criteria** and **narrative** are human-owned, and **progress** is the one
managed block the skill re-renders (`status --write`). See "The managed status block".

## Mode: hypothesis

Open a candidate explanation as a **sub-issue** of the investigation — first-class, so it rides the
progress bar and can be concluded and linked independently.

`${CLAUDE_SKILL_DIR}/scripts/hypothesis.sh "<claim>"` → creates `H<k>: <claim>` (next free `k`, derived
from GitHub — no local map, no drift), labels it `hypothesis`, attaches it as a sub-issue. Seed several
up front ("here are the 5 things it could be"), or let `evidence` offer to open one when a finding
references a hypothesis that doesn't exist yet. Resolve later with `conclude`.

## Mode: evidence

Turn a finding ("was PR #783 effective?", "the timeout bucket is now the top failure reason") into a
numbered evidence item in the report, **tagged to the hypothesis it bears on**, under the contract.

1. Read `references/reproducibility-contract.md` first — it is the why, not a checklist to skim.
2. Compose the evidence: a one-line claim, a **bounded** query (UTC on both ends, append-only store)
   or a verbatim block labelled **recorded**, the captured result, and a short reading. SHA-pin any
   code references; never link `/blob/main/…`.
3. Append it, tagged to its hypothesis:
   `${CLAUDE_SKILL_DIR}/scripts/evidence-add.sh [--hypothesis H<k> --stance for|against] <report-path> <evidence-draft.md>`.
   It renders `### E<n> (H<k>, supports|refutes) — …`, **anchor-checks** the `H<k>` ref (warns if it's
   not a sub-issue of the investigation), assigns the next `E<n>`, **lints the contract** (rejects a
   claim with no bounded query and no `recorded` label; rejects `/blob/main/` refs), appends, and bumps the
   `[E1]…[En]` range. If it rejects, fix the draft — the lint is the contract enforcing itself.
4. If the finding changes an earlier claim, **correct in place with a dated amendment** — append,
   don't silently rewrite history. An amendment is the highest-risk-of-contradiction edit, so consider
   a quick **coherence-reader** pass (`references/coherence-reader.md`) over the affected items before
   moving on — it catches an amendment that contradicts rather than reconciles.

When measuring whether a fix worked, default to a **baseline → effect** comparison over bounded
windows, and **rate-normalise** (don't compare a 13-day window to a 19-hour one on raw counts). When
a finding concerns whether code actually shipped, run `${CLAUDE_SKILL_DIR}/scripts/verify-shipped.sh <sha>` — "merged"
is not "in production" (a force-push can orphan a merge; the check uses the compare API so it works
in a fresh clone).

## Mode: link (and the auto-link Stop hook)

Tie a work item into the active investigation. **Sub-issues are issue→issue**; a PR is the implementation
of a sub-issue and rides the board.

- `${CLAUDE_SKILL_DIR}/scripts/link-to-epic.sh <issue-number>` → attaches the issue as a native **sub-issue** of the
  Epic (so it counts on the progress bar) and adds it to the board with the investigation's Status/Priority
  defaults. Idempotent: a no-op if already linked.
- `${CLAUDE_SKILL_DIR}/scripts/link-to-epic.sh --pr <pr-number>` → adds the PR to the board (PRs aren't sub-issues) and,
  if it `Closes #<work-item>`, ensures that work-item is a sub-issue. Closing the PR then closes the
  item and the bar moves on its own.

**The Stop hook** (`hooks/stop-autolink.sh`, opt-in via `hooks/INSTALL.md`) makes this automatic:
after any turn, if an investigation is active and the current branch has a PR not yet on the board, it
links it — and no-ops instantly when no investigation is active. So during an investigation you just run
`/zeus:create-pr` as usual and the work files itself under the Epic. Closing the investigation clears the
`investigate-state.sh` state, which makes the hook dormant again until the next `new`.

## Mode: status

Two shapes, same data (live GitHub state — computes nothing GitHub doesn't already show):

- `${CLAUDE_SKILL_DIR}/scripts/status.sh` — **read-only** bird's-eye to the terminal: the issue's
  Sub-issues bar, board view link, report path, and the open/closed work items.
- `${CLAUDE_SKILL_DIR}/scripts/status.sh --write` — **also re-renders the managed progress block** in
  the issue body in place. This is the labor-saver: the work-items rollup that used to be
  hand-maintained is regenerated from the live sub-issue states. It only touches the region between
  the `<!-- investigate:managed:start -->` / `…:end -->` markers — the human-owned health/criteria/
  narrative zone is never touched — and refuses to write if the markers are absent. Run it at each
  check-in (or wire the Stop hook to fire it).

## Mode: conclude

Settle a hypothesis with a verdict — the *epistemic* close (distinct from shipping a fix). A hypothesis
closes when it's **answered**; a fix closes when it's **shipped** (that's `remediate` + `verify-shipped`).

`${CLAUDE_SKILL_DIR}/scripts/conclude.sh <Hk|#num> confirmed|refuted|inconclusive` → labels the verdict
(for the rollup) and closes the sub-issue (`completed` for confirmed, `not_planned` for ruled-out). A
**refuted/inconclusive** hypothesis is valuable — it records what you ruled out, and spawns no fix. On
**confirmed** it prints the `remediate` hand-off.

## Mode: remediate

Turn a *confirmed* root cause into a fix. One confirmed cause may need several (hot-fix, proper fix,
guardrail, test) — run it once per fix.

`${CLAUDE_SKILL_DIR}/scripts/remediate.sh <Hk|#num> "<fix title>"` → opens a `remediation`-labelled
issue pre-referenced to the hypothesis + the investigation, attaches it as a sub-issue, cross-refs the
hypothesis. Then `/zeus:create-pr` (body `Closes #<this>`) → `/zeus:address-pr`; the bug closes only when the fix
is **in prod** (`verify-shipped.sh`, not merge). The link chain (PR → bug → hypothesis → investigation)
is structural, and `status --write` rolls up `Remediation: open · shipped` from it.

## Mode: report (opt-in)

Graduate to a durable, reproducible report when the investigation warrants one (an incident post-mortem,
anything reviewed). Scaffold `assets/report-template.md` → `docs/investigations/<date>-<slug>.md`, then
record it: `${CLAUDE_SKILL_DIR}/scripts/investigate-state.sh set report <path>`. After that, `evidence`
appends `E<n>` items to it under the contract. A quick investigation skips this entirely — the issue +
evidence comments suffice.

## Mode: close

Deciding the investigation is over is human judgment (see "The managed status block") — but it's also the
one moment the report stops growing and becomes the durable record, so it earns a single
**coherence-reader** pass before you call it done.

1. **Run the coherence reader** (`references/coherence-reader.md`): spawn a fresh subagent with *only*
   the rendered report — no conversation context — and have it check that each evidence item's
   *reading* follows from its captured result, that no two evidence items (or an item and the Summary /
   root cause) contradict, and that the `Summary` / `Root cause` / `Done` claims don't overstate what
   shipped. This is the **meaning** layer the `evidence-add.sh` lint can't judge — it gates the *form*
   of each append (bounded query, SHA-pin, `recorded` label); the reader gates coherence across the
   whole record (contract rules 4–7). Wrong/uncertain answers or "can't tell from the body" are gaps:
   fix the evidence item or section and re-run.
2. Flip the report **Status** to `✅ Resolved` with a one-line outcome, scoped to what shipped.
3. Tick the Epic's closing-criteria checkboxes you've actually met, and close the Epic only if its
   **outcome** gate is reached — task progress is not outcome progress (rule 5); a green sub-issue bar
   is not a resolved investigation.

This is a **recommended step, not a hard gate**. Unlike propose's RFC reader test (which
`post-issue.sh` enforces because an external reviewer must sign off), a report is a record with no
gate-keeper, so nothing refuses to let you close. Run it because a fresh reader catches an overstated
win or a self-contradictory claim that survived incremental review — not because a script makes you.

## The managed status block

The body has **two zones**, and only one is the skill's to write:

- **Managed (the skill re-renders it):** the `🗂️ Progress` block between the
  `<!-- investigate:managed:start -->` / `…:end -->` markers — the Sub-issues bar + work-items-by-state.
  It's fully derivable from GitHub, so `status --write` regenerates it on demand (idempotent; touches
  nothing outside the markers). This is the one thing that used to be hand-maintained prose (the #717
  pain) and is now generated.
- **Human-owned (never auto-touched):** **health** (live dashboard links + last-known values — the
  skill can't run those external queries, so you update them), **closing criteria** (judgment
  checkboxes), and the **narrative** ("is it improving / what changed").

What stays manual is **judgment, not bookkeeping** — updating a health figure, ticking a
closing-criterion, deciding the investigation is resolved. The progress rollup, the link chain, and
sub-issue state are derived. There is deliberately no full-body "sync": the skill re-renders *only*
the managed block, so a hand-edit to your narrative is safe and a re-render can't clobber it.

## Graceful degradation & safety

- **`--dry-run`** is honoured by every mutating script (prints the plan instead of acting). Use it to
  preview, and it is how the skill is tested against a sandbox repo without touching prod.
- **Missing `project` scope** → detect (`gh auth status`) and degrade to issues-only: Epic +
  sub-issues still work; the board step is skipped with a one-line note and `verify`/`status` still
  read fine. Tell the user to `gh auth refresh -s project` if they want the board.
- **Project *views* are UI-only** — always print the exact `parent-issue:#N` filter URL for the user
  to save; never claim to have created a view.
- Outward-facing writes (creating the Epic, editing it, linking) follow the usual rule: confirm
  before the first mutation unless the user clearly authorised it, and prefer `--dry-run` when unsure.

## Scripts & references

| Path | Purpose |
|---|---|
| `scripts/preflight.sh` + `deps.json` | dependency check + remediation (engine vendored identically across the family; `deps.json` declares this skill's extras — here, the `project` scope) |
| `scripts/lib.sh` | shared helpers: repo/owner resolution, per-worktree state, `--dry-run` `run()` wrapper, scope check |
| `scripts/investigate-state.sh` | this skill's own per-worktree state (`epic`, `report`, `project`, `view`, `linked_prs`) — one file per field under `.git/investigate/`, written by atomic rename (no lock) |
| `scripts/journey.sh` | the **shared** cross-skill store (vendored, identical across the family). `/zeus:investigate` is general and **does not publish to it** (no sibling auto-attach); kept only for the vendored read helpers other skills share |
| `scripts/ensure-epic.sh` | create-or-locate the investigation issue, add to board, write state, print the view URL |
| `scripts/hypothesis.sh` | open a hypothesis sub-issue `H<k>: <claim>` (auto-numbered from GitHub), attach it |
| `scripts/conclude.sh` | conclude a hypothesis `<Hk> confirmed\|refuted\|inconclusive` (label + close) |
| `scripts/remediate.sh` | spawn a `remediation` bug from a confirmed hypothesis, linked both ways |
| `scripts/link-to-epic.sh` | attach an issue as a sub-issue + board item (idempotent); `--pr` for PRs |
| `scripts/evidence-add.sh` | assign next `E<n>` (tag `(Hk, supports\|refutes)`), lint the contract, append to the report |
| `scripts/verify-shipped.sh` | "merged ≠ in prod" — `compare/<base>...<sha>` ancestor check (fresh-clone safe) |
| `scripts/status.sh` | print the bird's-eye (hypotheses/remediation rollup); `--write` re-renders the managed progress block in the issue body |
| `hooks/stop-autolink.sh` + `hooks/INSTALL.md` | the opt-in auto-link Stop hook + how to wire it |
| `references/reproducibility-contract.md` | the evidence rules as reasons — read before `evidence` |
| `references/coherence-reader.md` | the fresh-reader coherence pass run at `close` (and on amendments) — the *meaning* backstop to the contract lint's *form* checks |
| `references/github-model.md` | exact `gh`/`gh api`/`gh project` commands the scripts wrap |
| `assets/epic-dashboard.md` | the investigation-issue body template (managed-block markers + human zone) |
| `assets/report-template.md` | the report skeleton (contract header + evidence appendix) |
