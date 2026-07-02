# Zeus

The **issue → code → PR → review** workflow as one Claude Code skill family. Align on
work as GitHub issues, write the code on a branch, surface it as a reviewer-friendly PR,
drive it to mergeable, and hand it to a reviewer — each step a skill that composes with
the others through JSON contracts and a shared per-worktree `journey.json`.

```
propose / investigate → ⟨code: /goal or by hand⟩ → create-pr → address-pr → request-review
                              review-pr (local) + verify the issue contract    settle     ping reviewer
review-pr ── one engine, auto-detected: local (pre-PR) | remote (open PR)       improve ── retro on the family
```

Any skill is a valid entry point; the spine above is just the common path.

## Skills

| Skill | Trigger (examples) | What it does |
|---|---|---|
| `propose` | "propose X", "open an issue", "write an RFC" | Put a proposal/decision doc up for alignment as a GitHub issue. |
| `investigate` | "investigate X", "open a postmortem", "record this finding" | Evidence-driven investigation maintained as a GitHub issue. |
| `review-pr` | "review pr", "review my changes before PR", a PR URL | Read-only review across 7 dimensions; auto-detects local (pre-PR diff) vs remote (open PR). Diagnoses and hands findings back — never fixes. |
| `create-pr` | "create pr", "open a pr", "update pr body" | Author/refresh the human-facing PR title + body; reviews the diff and verifies the linked issue's contract before opening. |
| `address-pr` | "fix pr", "address feedback", "resolve merge conflicts" | Drive a PR to settled (mergeable, checks green, reviews resolved), then watch. |
| `request-review` | "ping reviewers", "request review", "re-review" | Notify a PR's code owners it's ready; re-ping in-thread when the head advances. |
| `improve` | "/zeus:improve", "retro this session" | Harvest a session's workflow friction and land durable fixes in Zeus or the repo's guidance. |

## Sub-agents

The skills fan work out to three reusable, tool-scoped sub-agents (in `agents/`,
invoked by name):

| Agent | Tools | Role |
|---|---|---|
| `zeus:cold-reader` | none (`tools: ""`) | Text-only critic — judges a rendered doc from the body alone (reader test, coherence check, objector steelman). No repo access by construction. |
| `zeus:diagnostician` | read-only (Read/Grep/Glob/LSP) | Read-only diagnosis — returns findings, never mutates. Powers review-pr's per-lens fan-out, address-pr's check/thread diagnosis, and propose's grounding + implementer persona. |
| `zeus:scout` | read-only (Read/Grep/Glob) | Cheap triage router — sizes an expensive fan-out and picks per-unit model tiers. |

## Requirements

- **git** and **gh** (GitHub CLI), authenticated — the source of truth is GitHub.
- Optional, MCP-gated integrations that degrade gracefully when absent:
  - **Slack** (`request-review` outbound pings; `review-pr` threaded replies)
  - **SonarQube** / **Vercel** (`address-pr` CI handlers)
  - **Atlassian / Confluence** (`propose` optional publish target)

## Install

Zeus lives at `skills/zeus/` in these dotfiles. The repo's `install.sh` symlinks it
into `~/.agents/skills/zeus`, so the source of truth stays in git.

As a standalone Claude Code plugin it is a self-contained plugin directory
(`.claude-plugin/plugin.json` + `skills/` + `agents/` + `hooks/`). To use it that way,
add it through a plugin marketplace or symlink it into your plugins directory. Validate
any changes with:

```sh
claude plugin validate ./
```

(One expected warning: the plugin-root `CLAUDE.md` — kept on purpose to feed
`@AGENTS.md` to the dotfiles' own tooling — isn't loaded as plugin context.)

## Configuration

Config is merged, most-specific first — `env ZEUS_<KEY>` > repo `.git/zeus/config.json`
> user `$ZEUS_CONFIG_DIR/config.json` (default `~/.config/zeus/`) > shipped
`lib/config.defaults.json`. Per-concern blobs (Slack handles, ping policy, Confluence)
live under `$ZEUS_CONFIG_DIR/<concern>/`. Nothing user- or repo-specific is committed.

## Development

See [`AGENTS.md`](./AGENTS.md) for the internals: the shared CLI argument convention,
the per-skill script reference, composition rules, and the `lib/`/`agents/` "define
once, reference by name" structure. Run the house lints before pushing:

```sh
bash lib/check-arg-conventions.sh   # CLI + sub-agent conventions
claude plugin validate ./           # manifest + frontmatter schema
```

## License

MIT — see [`LICENSE`](./LICENSE).
