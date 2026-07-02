# Changelog

All notable changes to the Zeus plugin are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.2.0]

### Added
- **First-class sub-agents.** Three reusable, tool-scoped agent definitions in
  `agents/`, invoked by name — `zeus:cold-reader` (text-only critic, no tool access),
  `zeus:diagnostician` (read-only diagnosis, returns findings), and `zeus:scout` (cheap
  triage router). Replaces the previous inline "spawn a fresh subagent" prose across
  `review-pr`, `address-pr`, `propose`, and `investigate`.
- `check-arg-conventions.sh` rule `[7]`: every `zeus:<name>` sub-agent reference must
  resolve, and the archetype invariants must hold (`cold-reader` ships `tools: ""`,
  `diagnostician` stays read-only).
- Recommended `plugin.json` manifest metadata: `displayName`, `author.email`,
  `homepage`, `repository`, `license`.
- `LICENSE` (MIT), matching the `license` declared in every skill's frontmatter.
- `README.md` (user-facing) and this `CHANGELOG.md`, rounding out the standard
  plugin layout.
- CI: a path-scoped GitHub Actions workflow (`.github/workflows/zeus-plugin.yml`)
  that runs `check-arg-conventions.sh` and `claude plugin validate` (non-strict —
  fails on errors, tolerates the accepted plugin-root `CLAUDE.md` warning).

### Changed
- The read-only diagnosis contract is now **structural, not prose**: `zeus:diagnostician`
  carries no `Bash`/`Edit`/`Write`, so it returns findings and the orchestrator is the
  sole writer. This removes `review-pr`'s per-lens findings-file lock and the fan-out
  worktree-isolation requirement (single writer, no contention). `review-contract.md`
  and `handler-contract.md` updated accordingly.

## [0.1.1]

- Initial published version of the Zeus issue → code → PR → review skill family
  (`propose`, `investigate`, `review-pr`, `create-pr`, `address-pr`, `request-review`,
  `improve`) with the shared `lib/` and per-worktree `journey.json` bus.
