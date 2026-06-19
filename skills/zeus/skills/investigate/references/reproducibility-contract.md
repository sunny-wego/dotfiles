# The reproducibility contract

This is *why* the report is trustworthy, not a checklist to skim. A report earns trust by
letting someone with no context re-derive every claim months later. These rules came from real
mistakes — each one is here because skipping it produced a wrong conclusion that survived review.

## 1. Every claim is an evidence item with a re-runnable query
Tag each claim `[E1]`, `[E2]`, … and resolve it in an evidence appendix. The evidence is a **bounded**
query — explicit UTC timestamps on **both** ends (`>= start AND < end`) — against an **append-only**
store (e.g. Neon `webhook_events` / `cs_brain_analyses`, PostHog `events`). Bounded + append-only means
re-running it next month returns the same rows. An unbounded query, or one against a mutable table, is
not evidence — it's a screenshot in prose.

## 2. Label recorded vs reproducible
Some sources expire (Vercel runtime logs, vendor status pages) or are mutable. Paste those **verbatim**
and label them **recorded** — they can be *audited against their capture context* but not re-derived.
Everything else must be reproducible. Never blur the two: a recorded snapshot dressed up as a query
invites someone to "just re-run it" and get a different answer.

## 3. SHA-pin code references
Never link `/blob/main/…` — line numbers rot as the file changes. Pin to a commit
(`/blob/<sha>/…#L120`). When you cite "current `main`", pin to the `main` HEAD sha *at the time of
writing* and say so. (`evidence-add.sh` rejects `/blob/main/` for this reason.)

## 4. Merged is not in production
Before claiming a fix is live, verify the merge commit is an **ancestor of the base branch**, not just
that GitHub shows the PR "merged" — a force-push can orphan a merge. Use `verify-shipped.sh <sha>`
(GitHub compare API: `behind`/`identical` = shipped, `diverged`/`ahead` = orphaned). The check must work
in a **fresh clone**, so use the API, not local `git show`/`cat-file` (orphaned objects aren't fetched).
This rule exists because a shipped 15s-timeout fix was silently lost in a merge and went unnoticed for
days while the doc assumed it was live.

## 5. Task progress is not outcome progress
"All sub-issues closed" ≠ "investigation resolved". Track them separately: the sub-issue bar / board is task
progress; the investigation's health metric moving toward its gate (held-rate, failure-rate) is outcome
progress. State both, and never let closing tickets imply the outcome was reached.

## 6. Rate-normalise comparisons; don't overstate the fix
Compare baseline → effect over **commensurate** windows. A 13-day baseline vs a 19-hour post-deploy
window cannot be compared on raw counts — normalise to a rate, and say the window is short. Scope every
claim to **what actually shipped**: "bucket 3 → 0 and reads now fail fast" is true; "bucket 4 solved" was
false because the invisible-kill *rate* was unchanged and only the absolute delta looked smaller (short
window). An overstated win misdirects the next fix.

## 7. A derived field is not an observation
Before using a stored field as evidence of what happened, trace where it's *written*. If field A is
computed from field B, "A equals B" proves nothing — it's a tautology, not a measurement. Only a value
captured on the wire (or at the throw site) can falsify a hypothesis about what was sent.

## 8. The analysis gets reviewed like code
Put the report (and these edits) through a PR and `/zeus:address-pr`. Adversarial review catches errors
in the *reasoning*, not just typos — in practice it caught a false "survives in main", a self-
contradictory timeout argument, and an overstated bucket claim. The record earns trust by surviving review.

## Shape of one evidence item (what `evidence-add.sh` expects as the draft)
```
<one-line claim — the heading>

<one sentence of setup: which store, which window, what it tests>

​```sql
-- bounded both ends, append-only store
SELECT … WHERE ts >= '<start>+00' AND ts < '<end>+00' …
​```

<the captured result — a small table or the key numbers, with an as-of capture time>

Reading: <what it means, scoped to what shipped; rate-normalised if it's a comparison>
```
For a recorded item, replace the query block with the verbatim snapshot and the word **recorded**.
