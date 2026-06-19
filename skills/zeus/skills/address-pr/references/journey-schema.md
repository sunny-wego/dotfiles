# `journey.json` — the cross-skill shared state contract

`journey.json` is the per-worktree handoff store shared across **propose → create-pr → address-pr**,
with **investigate** publishing an optional `investigation` namespace. It holds only the durable facts one
skill needs to pass to another. Run-internals (queues, status snapshots, the reviewer-ping thread) stay in
each skill's own `.git/<skill>/` dir and are never written here. `scripts/journey.sh` is the only accessor,
vendored identically by all four skills.

## Location
`$(git rev-parse --absolute-git-dir)/journey.json` — i.e. `.git/journey.json` in the working repo, or
`.git/worktrees/<name>/journey.json` for a linked worktree. **Per-worktree isolated**; never committed.

## Schema
```json
{
  "branch": "feat/foo",
  "issue":    { "number": 123, "url": "https://github.com/o/r/issues/123", "title": "..." },
  "pr":       { "number": 456, "url": "https://github.com/o/r/pull/456" },
  "investigation": { "epic": 789, "report": "docs/reports/2026-06-09-x.md" }
}
```

| Field | Owner (only writer) | Read by | Notes |
|---|---|---|---|
| `branch` | any writer | — | last branch that wrote; advisory |
| `issue.*` | **propose** | create-pr (seeds `Closes #N`, Original Intent) | |
| `pr.*` | **create-pr** | address-pr / investigate hook (best-effort) | |
| `investigation.*` | **investigate** | create-pr (apply `investigation` label when active) | **optional** namespace; absent unless an investigation is open |

## Invariants that keep it shared *and* skills independent
1. **Namespace ownership** — a skill writes only its own namespace; `write-pr` never touches `.issue`.
2. **Tolerant reads** — missing file/key → `""` / `{}`, never an error. A skill runs the same whether or
   not the others ever wrote. This is the independence guarantee.
3. **Merge writes** — writers merge into their namespace, never replace the whole file.
4. **Atomic + locked** — every read-modify-write goes `tmp` → `mv` under a `mkdir`-based advisory lock
   (`journey.json.lock`, steals a dead holder's lock, ~5 s timeout), so concurrent skills can't lose
   each other's updates.
5. **Handoff facts only** — a field belongs here *iff* it crosses a skill boundary. Everything else is
   private to `.git/<skill>/`.

## Evolving the schema
The schema is intentionally unversioned and additive — tolerant reads (missing key → `""`/`{}`) are what
keep old and new copies compatible, not a version field:
- Adding a field to an existing namespace, or a new namespace: safe — readers ignore keys they don't read,
  and gate on presence (e.g. `investigation-epic` returns empty when absent).
- Renaming/removing/retyping a field is the only breaking change — coordinate it across all vendored copies
  (`journey.sh` is copied byte-identical into each skill; keep the copies in sync by hand when editing).

## Picking a PR up from scratch (the body marker)

`journey.json` is per-worktree and never committed, so a **fresh session** — a new clone or worktree that
only knows the PR number — starts with an empty store. Most of the journey rehydrates from GitHub for free
(it's a level-triggered reconciler: checks/reviews/mergeable are re-probed every pass; the linked issue
comes from `closingIssuesReferences`; an investigation from the `investigation` label). The one fact GitHub can't
give back is the **Slack review thread** (channel / `thread_ts` / target) — it's external.

To make a PR self-describing, `create-pr` embeds a hidden, machine-only marker at the end of the PR body
(invisible in rendered Markdown, outside the managed block so `refresh` preserves it):

```html
<!-- journey:v1 {"issue":456,"investigation":789,"slack":{"channel":"C..","thread_ts":"..","target":".."}} -->
```

- **Accessor:** `scripts/journey-marker.sh` (`emit`/`parse`/`splice`/`read`/`write`), vendored identically by
  create-pr and address-pr. Writes MERGE — a `slack` write never clobbers `.issue`.
- **Written:** `create-pr` (via `post-pr.sh`) seeds `issue`/`investigation` at create time; `address-pr` writes
  `slack` once, right after the initial reviewer ping is stamped.
- **Read:** `address-pr/scripts/rehydrate.sh` (run automatically by `setup.sh`) reconstructs `journey.json`
  and the Slack thread (`request-review`'s `review-thread.sh`) from the marker — **filling gaps only**, never
  overwriting local state, so a worktree that drove the PR from the start is unaffected. The reviewed SHA is
  recovered from the target reviewer's latest review commit (the marker deliberately omits volatile state).
- **Scope:** only write-once / stable facts live in the marker. Iteration, reviewed SHA, and queues are
  re-derived from GitHub every run and never embedded.
