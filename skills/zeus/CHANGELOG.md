# Changelog

All notable changes to the Zeus plugin are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.2.1]

A cohesion / CLI-consistency / reuse audit of the family. No behavioral redesign — these
are correctness, consistency, and reuse fixes.

### Fixed
- **request-review no longer calls another skill's script by path.** Its Initial-ping /
  Re-review examples invoked address-pr's `ready-for-review.sh` directly, contradicting
  the house "skills call skills by name" rule and its own verdict-agnostic contract; the
  verdict is now shown as an input (piped in, or fetched via `/zeus:address-pr ready`).
- **AGENTS.md Slack ownership** reworded from the self-contradicting "no skill posts
  Slack itself" to "one outbound notifier / Slack owned per-direction" (request-review
  broadcast; review-pr threaded reply).
- **Doc drift:** dropped the phantom `select-mode.py` reference; documented the
  previously-undocumented `run-changed-tests.sh`.
- Disambiguated the overloaded **"re-review"** trigger between review-pr (re-run the
  code review) and request-review (re-notify reviewers).

### Added
- `argument-hint` on the three arg-taking skills (address-pr, review-pr, request-review).
- propose declares the **Atlassian MCP** it uses in `allowed-tools` + `deps.json`;
  review-pr/improve `deps.json` note their optional Slack MCP / `/reflect` dependency.
- `lib/worktree.sh` — the shared git-worktree engine, extracted from address-pr's
  `ensure-worktree.sh` and review-pr's `ensure-checkout.sh` (which had duplicated it).
- `lib/dispatch.sh` — shared `usage_exit` / `need` / `unknown_verb` helpers so usage
  errors exit 2 (the house contract) instead of the `${N:?}` idiom's forced 1.
- propose gains a `scripts/lib.sh` shim (the only skill that lacked one), so it uses
  `state_root`/`atomic_write` from `lib/state.sh` instead of re-implementing them.
- `check-arg-conventions.sh` rule `[8]`: no skill invokes another skill's script by bare
  basename; split-form rules `[1]`/`[2]` widened from the PR-workflow pair to all skills.

### Changed
- Standardized usage-error and unknown-verb exit codes to 2 across the verb-dispatch and
  identifier scripts; added missing `Usage:` headers.
- Deduped the `${XDG_CONFIG_HOME:-…}/zeus` config-home derivation (4 copies) onto
  `lib/config.sh`; aligned investigate's state dir onto `state_root` and added its git guard.
- create-pr's `refresh.sh apply` takes canonical `--pr` (via `resolve_pr`) instead of a
  bespoke `--pr-number` flag.

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
  fails on errors, tolerates the accepted plugin-root `CLAUDE.md` warning) for both
  the plugin and the marketplace manifest.
- Marketplace distribution: the dotfiles repo doubles as a marketplace via
  `.claude-plugin/marketplace.json` (lists `zeus` at `./skills/zeus`), so the plugin
  installs with `claude plugin marketplace add sunny-wego/dotfiles` +
  `claude plugin install zeus@sunny-wego`.

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
