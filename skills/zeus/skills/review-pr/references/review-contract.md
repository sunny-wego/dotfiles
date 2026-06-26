# Review Contract

Shared contract for every handler in `handlers/*.md`. Read this once before the
first handler. It governs how a handler diagnoses and grades — not what it looks
for (the handler's own body) or how findings render (`comment-format.md`).

## What a handler does (and does not) do

- **Diagnose only. Never mutate.** A review handler reads the diff + checkout and
  emits findings. It does not edit files, commit, push, or comment. The
  orchestrator owns posting.
- **Append findings** to `$FINDINGS_FILE`, each matching `findings-schema.md`.
  Use the shared lock for the read-modify-write so fan-out handlers don't clobber
  each other:
  ```bash
  source "${CLAUDE_SKILL_DIR}/scripts/lib.sh"
  with_lock "$STATE_DIR/findings.lock"
  # ... append your finding objects to $FINDINGS_FILE ...
  ```
- **Side-effect-free by construction.** Because a handler only reads and appends,
  the same handler runs identically whether invoked in the single-context pass or
  as one of N parallel subagents (`--deep`). This is the property that makes
  fan-out a dispatch choice, not a rewrite — do not break it.

## Severity rubric

| Severity | Use for |
|---|---|
| `high` | Correctness/security/data-loss; a wrong result, lost event, or breach. |
| `medium` | Real but bounded: degraded behavior, a brittle assumption, a gap that bites under load or a specific input. |
| `low` | Minor robustness, clarity, or maintainability with no functional impact. |

Severity is independent of status. A reproduced typo is `confirmed/low`; an
unproven data-loss race is `hypothesis/high`. Do not let "I couldn't reproduce
it" deflate severity — uncertainty lives in `status`, impact lives in `severity`.

## Status: confirmed vs hypothesis (the verification protocol)

Default every finding to `hypothesis`. Promote to `confirmed` only by running a
check that actually reproduces the mechanism, within the safety fence below.

**Tier 0 — static (always; result stays `hypothesis`).**
1. Find the definition — LSP "go to definition" (Grep fallback).
2. Trace wrappers — bugs hide in wrappers that conflate failure modes.
3. Verify data flow — follow the value end-to-end; correct in isolation ≠
   correct in context.
A Tier-0 finding records, in `verify`, the exact check that *would* confirm it.

**Tier 1 — execution (promote to `confirmed` on success).**
Run the cheapest check that reproduces the claim. **Detect the repo's stack first**
(lockfile / manifest / config) and use its *native* tooling — this skill is
language- and stack-agnostic, so never assume Python. The shapes of a Tier-1
check are universal; only the command changes:

| Check shape | Python | JS/TS | Go | Rust | JVM |
|---|---|---|---|---|---|
| run a unit slice | `pytest path::test` | `npm test`/`jest path` | `go test ./pkg -run X` | `cargo test name` | `./gradlew test --tests X` / `mvn -Dtest=X test` |
| drive an endpoint in-process | ASGI/`TestClient` | `supertest`/`app.inject` | `httptest` | `actix`/`axum` test | `MockMvc`/`WebTestClient` |
| migration up/down round-trip | alembic | Prisma/Knex/TypeORM | `migrate`/`goose` | `sqlx migrate`/`refinery` | Flyway/Liquibase |
| one-off probe | `python3 -c` | `node -e` | `go run` | small `cargo` bin | `jshell`/scratch main |

Detection hints: `pyproject.toml`/`requirements*.txt`→Python; `package.json`→JS/TS;
`go.mod`→Go; `Cargo.toml`→Rust; `pom.xml`/`build.gradle`→JVM. Honor the repo's
runner (`Makefile`, `justfile`, `mise`, `package.json` scripts, CI workflow) over
guessing a command.

Always do all four of:
1. set up the stack's deps in the **throwaway** checkout (its native install);
2. exercise the exact failure path the finding claims;
3. capture the **literal output** observed; and
4. record the **ordered commands** you ran — both go into `evidence` so the author
   can rerun it verbatim (see findings-schema.md: evidence = steps + observed output).

If the check disproves the claim, drop the finding (or record it as resolved) —
do not post a refuted concern as a hypothesis.

## Safety fence (Tier 1)

Tier 1 runs code. It is allowed **only** when ALL hold:
- **Throwaway, self-created resources only.** A scratch DB/clone you made this
  run. Never mutate shared, long-lived, or pre-existing infrastructure (no
  `DROP`/writes against a DB you didn't create, no shared containers, no remote
  state). If a step is denied or would touch shared state, **stop and leave the
  finding as `hypothesis`** — do not work around the denial.
- **Bounded.** A short time budget per check; no long-running builds/deploys.
- **No network side effects.** No posting, no external calls beyond reading the
  code under review.
- **Graceful absence.** Missing runtime / test runner / local DB → the check is
  simply skipped and the finding stays `hypothesis`. Never an error, never a
  blocker.

When in doubt, stay `hypothesis`. A clearly-labeled unproven concern is honest;
a `confirmed` badge earned by an unsafe or sloppy check is a lie that erodes the
whole review.

## Verification under fan-out (`--deep`)

Default and safest: **verification is central and serial.** In parallel mode the
subagents do **diagnosis only** — they read the diff and append findings, they
never run the stack. The order is: parallel diagnosis → merge/dedup barrier →
**synthesis pass** (cross-dimension findings, severity upgrades, fragment merges)
→ then Tier-1 verification, once, in the orchestrator. Verification never runs
inside the parallel agents. This is deliberate: it avoids N agents each spinning up
a database / dev server / build, and avoids them fighting over shared resources.
So during fan-out the parallel agents are read-only and cannot collide on
anything but the findings file (which `with_lock` already serializes).

If you ever do parallelize Tier-1 (don't, unless a slow suite forces it), every
concurrent check MUST be fully isolated — the reviewer must not reproduce the very
concurrency bugs it reviews for:
- **Unique resources per check.** Throwaway DB/schema names, temp dirs, and any
  scratch files suffixed with the finding id (e.g. `rp_<id>` not a shared
  `rp_dogfood`). Never share one DB across parallel checks.
- **No fixed ports.** A check that binds a fixed port (dev server, test DB on a
  pinned port) cannot run concurrently with another that does — bind `:0` /
  ephemeral, or serialize those.
- **Filesystem isolation.** Use a separate git worktree per check (the Agent
  tool's `isolation: worktree`) so parallel builds/installs don't clobber each
  other's artifacts.
- **Serialize the unisolable.** Anything touching a single shared service (one
  local Postgres instance's global state, a singleton container) runs serially
  even if everything else fans out.

When the cost of isolating a check exceeds its value, run it serially or leave the
finding as `hypothesis`. Reviewer correctness beats reviewer speed.

## Evaluation verbs (what to do with a candidate)

- **RAISE** — a correctness/security/stability/data concern. Always surface it;
  verify per the protocol and label honestly.
- **RAISE AS NIT** — minor clarity/robustness with no functional impact →
  `status:nit`. Surface, but don't dramatize.
- **NOTE-ONLY** — a question with no concrete downside; fold into the summary
  body, not an inline comment, if at all.
- **DROP** — pre-existing (not introduced by this PR), out of scope, style-only
  preference, or a candidate Tier 1 refuted. Do not post.

Pre-existing-issue test: if the concern is equally true on the base branch, it's
not this PR's finding — DROP (or mention once in the summary, never inline).

## Reporting

Every handler, on finishing, leaves its findings in `$FINDINGS_FILE`. The run
report tallies per `handler` and per `status`; the renderer turns the array into
one review. A handler that finds nothing appends nothing — that's a clean pass,
not an omission.
