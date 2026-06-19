# CI Check Handler

Fix a failed CI check — **any provider** (GitHub Actions, CircleCI, GitLab CI, Buildkite, Jenkins, …) and
**any language**. This is the catch-all for failed checks that aren't merge conflicts, SonarQube, or Vercel.

See `references/handler-contract.md` for shared rules.

## Fix

Get the failing logs. If the check is a **GitHub Actions** run, fetch them directly:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-failed-logs.sh <BRANCH>
```

Returns an array of `{run_id, name, failed_jobs, log}` (last 200 lines per run). For a **non-GitHub-Actions**
provider, that script won't have the logs — open the check's details URL (`gh pr checks <PR>` lists each
check's link) or ask the user to paste the failing output.

For each error:

1. Read the reported file:line.
2. Apply an Edit.

Common categories — the examples span ecosystems; match your project's actual toolchain, don't assume JS:

- **Type / compile errors** (`tsc`, `mypy`, `go build`, `cargo check`, `javac`) — fix the issue at the reported site.
- **Lint / format** (`eslint`/`biome`/`prettier`, `ruff`/`black`, `gofmt`/`golangci-lint`, `rubocop`, `clippy`) — apply the suggested fix or run the project's formatter.
- **Lockfile mismatch** (`package-lock.json`/`yarn.lock`/`pnpm-lock.yaml`/`bun.lock`, `poetry.lock`/`uv.lock`, `Cargo.lock`, `go.sum`, `Gemfile.lock`) — regenerate via the project's package manager.
- **Tests** (`jest`/`vitest`/`playwright`, `pytest`, `go test`, `cargo test`, `rspec`) — fix the source, not the test, unless the test is wrong.
- **Build** — missing imports, invalid config, incompatible dependencies.

**SKIP** infrastructure failures (runner OOM, network timeout), flaky tests, permission/secrets — flag in outcome.

Append outcome:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/state.sh append ci-check \
  '{"fixed":N,"declined":0,"skipped":N,"unresolved":[…]}'
```

## Standalone mode

`/zeus:address-pr ci-check`: exit when all required checks pass.
