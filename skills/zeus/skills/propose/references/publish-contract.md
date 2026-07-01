# Publish Contract

Shared contract for every **publish backend** — a script that posts a proposal to
one destination (`post-issue.sh` → GitHub, `confluence.sh` → Confluence, and any
future Notion/Jira/…). Read this once before writing or changing a backend.

A backend is an *implementation* of this contract; it is **not** reached through a
router. The orchestrator (`SKILL.md`) calls backends **by name** and composes them
— one destination (`confluence`) or several (`both` = GitHub canonical + a Confluence
page that backlinks it). The contract is what lets the orchestrator treat any
destination uniformly from above while each talks to its own API below. There is no
`publish.sh` dispatcher and there should not be: a router selects *one* backend, but
`both` posts to *two*, and the family composes by-name everywhere else.

## The three verbs

Every backend exposes exactly these, with this signature (mirrors `gh issue`):

| Verb | Invocation | Maps to |
|---|---|---|
| **create** | `<backend> --title <t> --body-file <path> --repo <owner/repo> [--state <f>]` | new artifact |
| **update** | `<backend> --update <id> --title <t> --body-file <path> [--state <f>] [--force-amend]` | amend the artifact **in place** (full re-render from state) |
| **comment** | `<backend> --comment <id> --body-file <path> --repo <owner/repo>` | append a comment (the *not-mine* path) — never touches the artifact body |

- `--state <file>` is the proposal's state JSON (the source of truth a later amend
  reloads).
- `--repo <owner/repo>` is how a backend resolves *where* to post (GitHub: the repo
  itself; Confluence: `confluence-target.sh <owner/repo>` → cloud/space/parent).
- A backend that cannot satisfy a required argument exits `2` (usage), loudly.

## I/O contract

- **stdout = the canonical artifact URL**, and nothing else. Callers do
  `URL=$(<backend> …)`. Human-readable logs (`updated #N: …`, `created page …`) go
  to **stderr**.
- **Exit `0` ok / `1` runtime / `2` usage.** A failed network call is `1` with the
  cause on stderr — never a silent success.
- Identifiers route through the house parser where the backend takes a PR/repo/SHA;
  sub-commands stay positional; bulk payloads via stdin or `--from`. (See AGENTS.md.)

## Mandatory semantics — every backend MUST honor these

These are the *policy* the orchestrator relies on regardless of destination. Most
are shared helpers; a backend wires them, it does not re-implement them.

1. **Ownership gate before `update`.** Refuse to overwrite an artifact you don't own
   unless `--force-amend`; **fail safe** — refuse when ownership can't be determined.
   The backend fetches the artifact's author + the current user, then delegates the
   *decision* to `ownership.sh` (compare mode: `--author <id> --viewer <id>`). The
   *not-mine* path is `comment`, not a silent skip.
2. **Drift gate before `update`.** Refuse if the live artifact advanced past what
   `state` recorded (someone edited out-of-band; a full re-render would clobber
   them). The gate is **required**; both its *mechanism* and its *location* follow
   the destination (one of the divergent five):
   - **Version-based** drift (Confluence) reads a number persisted at the last write,
     independent of the body — so it runs **in-backend** at write time, an
     un-skippable chokepoint like ownership. `confluence.sh` does this.
   - **Text-diff** drift (GitHub) compares `render(state)` against the live body,
     which only works on the **pre-edit** state — at write time `render(state)`
     differs from the live body *by design* (that's the amend). So it MUST run in the
     **orchestrator before the state is edited** (SKILL.md step 2, `drift-check.sh`),
     not in the backend; moving it in-backend would compare post-edit state to live
     and false-positive on every legitimate amend.

   Either way the gate runs before the write lands; `--force-amend` overrides.
3. **Reader-test gate before `create`/`update`** (skipped on `comment`). If
   `requires-review.sh` says this state warrants review, refuse unless the
   reader-test stamp is present **and** matches the current state hash
   (`state-hash.sh`) — i.e. the artifact that ships is the artifact that was tested.
   This is destination-neutral and lives in the shared **`review-gate.sh`**; every
   backend calls it. *(Today `post-issue.sh` inlines this block; extracting it into
   `review-gate.sh` and routing both backends through it is the alignment step that
   makes this clause literally true rather than duplicated.)*
4. **Watermark.** The published body carries the `_via `zeus:propose`_` origin tag
   (idempotent). *Where* it is stamped is the backend's choice: `post-issue.sh`
   stamps the markdown body-file directly; `render.sh --format confluence` bakes it into the
   markdown upstream (because by the time `confluence.sh` has the body it is storage
   XHTML and can't take a markdown append). The invariant is *the artifact is
   signed*, not *which script signs it*.
5. **State tail on success** — best-effort, **never blocks the post**. Persist the
   state and **pin** the artifact as the worktree's active proposal, keyed on the
   backend's identity (`state.sh save <key>` / `pin <key>`: `<number>` for GitHub,
   `confluence:<id>` for Confluence). A handoff write (`journey.sh`) where the
   destination is journey-anchored.

### Gate order (normative)

The gate SET always precedes the write. For an in-backend-drift destination
(Confluence) the backend runs them in order, short-circuiting on first refusal:
**reader-test → ownership → drift → write**, fetching the live artifact once to feed
both ownership and drift. For a text-diff-drift destination (GitHub), **drift is
hoisted to the orchestrator pre-edit** (it needs the un-mutated state); reader-test
and ownership stay in-backend at write. The end-to-end guarantee — all three pass
before the artifact changes — holds for both.

## The divergent five — explicitly NOT unified

The contract deliberately does **not** unify these. Naming them as per-destination
is what keeps the abstraction honest instead of leaky — a new backend implements
exactly these, and nothing in the orchestrator or the other backends changes.

| Concern | GitHub (`post-issue.sh`) | Confluence (`confluence.sh`) |
|---|---|---|
| **Auth** | `gh` (its own login) | `CONFLUENCE_EMAIL` + `CONFLUENCE_API_TOKEN`, site base URL |
| **Identity** | issue `#N` | page `id` + `version.number` |
| **Body ingestion** | markdown, native | storage XHTML — markdown→storage conversion seam (`CONFLUENCE_CONVERTER`) |
| **Drift mechanism + location** | text diff of `render(state)` vs live body (`drift-check.sh`); needs pre-edit state ⇒ runs in the **orchestrator** | version-number compare (`confluence-drift.sh`); reformat-immune, body-independent ⇒ runs **in-backend**. (A text diff false-positives on Confluence's markdown round-trip.) |
| **Supersede** | new artifact + `Supersedes #N`, **close** the old | new page + `Supersedes <url>`, prepend a `⚠️ Superseded by` banner (no close/delete) |

Same *safety* across the row (e.g. both drift gates stop a clobber); different
*fidelity/mechanism*. The orchestrator never sees these — it sees three verbs and a
URL.

## How the orchestrator uses backends

- **Choose the destination set** from the proposal's `mode`: `confluence` → one
  backend; `both` → GitHub first (so the page can backlink the issue), then
  Confluence with `--issue-url <gh-url>`; GitHub-only (no Confluence config) → just
  `post-issue.sh`. Future N destinations are just more calls.
- **Dispatch by name** — a `provider → backend script` map (one `case` arm each), not
  a router. Collect each backend's stdout URL; surface them.
- **Orchestration logic stays in the orchestrator** — order, backlink wiring, and
  "one or many" are not a backend's concern.

## Adding a new destination

The contract makes this cheap — the orchestrator and existing backends don't change:

1. Write `<dest>.sh` exposing the **three verbs** with the signature above.
2. **Reuse** the shared policy verbatim: `review-gate.sh`, `ownership.sh` (compare
   mode), and the state-tail helpers. You write none of this.
3. Implement only the **divergent five** for that destination.
4. Add **one `case` arm** to the orchestrator's provider→backend map.
5. Run the conformance lint (below).

The per-destination cost collapses to "the irreducible I/O for that one API, in one
file." Nothing ripples into the other backends or the flow.

## Conformance

A backend is conformant iff: it exposes the three verbs; stdout is the URL and exit
codes follow `0/1/2`; `update` runs the shared **review-gate** and the **ownership**
gate in-backend before writing; and a **drift** gate runs before the write per its
mechanism (in-backend for version-based, orchestrator-pre-edit for text-diff).
`check-arg-conventions.sh` carries the machine-checkable subset — the three verbs
present and the two in-backend gates (`review-gate.sh`, `ownership.sh`) invoked — so
conformance is enforced, not aspirational. Run it when you add or edit a backend.
