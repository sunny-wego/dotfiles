# Test-evidence contract

How the **Test Plan** section's verification evidence is shaped, rendered, and (optionally) produced by a
sibling skill. Read this when filling `test_plan` in the state JSON, or when wiring a `verify`-style skill
to feed create-pr.

The guiding principle: **evidence must be independently checkable, not merely asserted.** "The log rendered
as expected" is a claim; the real command and its captured output is proof. Prefer verbatim artifacts.

## The artifact shape

`test_plan` in the state JSON (`init-state.sh` skeleton) carries two verification slots — `manually_verified`
and `not_tested` (the separate `acceptance` checklist is issue-seeded, not part of this evidence contract). A
producer skill emits — or the agent fills — exactly this shape; importing is a merge, not a translation:

```json
{
  "head_sha": "<sha the evidence was gathered against>",
  "summary": "Traced multi-GDS PNR 5359155 end to end; the comma-split yields two refs.",
  "evidence": [
    "Input: `EF.pnr = \"TRAVELPORT:H24S4R,H24S60\"`",
    "```text\n$ python -m repro 5359155\n[identify] gds=TRAVELPORT refs=H24S4R,H24S60\n[executor] split -> ['H24S4R','H24S60']\n[log] ref=H24S4R ok\n[log] ref=H24S60 ok\n```",
    "```mermaid\nflowchart LR\n  ID[identify] --> G[gate] --> X[executor]\n  X --> R1[H24S4R]\n  X --> R2[H24S60]\n```"
  ],
  "not_tested": [{"gap": "3+ ref PNRs", "why_not": "no sample available", "mitigation": "len-agnostic loop"}],
  "bugs_surfaced": []
}
```

Mapping into create-pr state:

| Artifact field   | create-pr state field            | Rendered as |
|------------------|----------------------------------|-------------|
| `summary`        | `test_plan.manually_verified.summary`  | inline after `**Manually verified** —` |
| `evidence[]`     | `test_plan.manually_verified.evidence` | verbatim blocks inside `<details>` |
| `not_tested[]`   | `test_plan.not_tested`           | table |
| `bugs_surfaced`  | (fold into `evidence` or an Outcome bullet) | — |
| `head_sha`       | freshness gate only (not rendered) | — |

## Field rules

- **`summary`** — one line, the checkable claim. Not the proof. Renders inline; a reviewer reads it at a glance.
- **`evidence[]`** — a list of **verbatim markdown blocks**, each emitted as-is and separated by a blank line.
  A block may be:
  - a fenced code block holding a **real command and its captured output** (the highest-value kind),
  - a ` ```mermaid ` diagram of the path exercised,
  - a before/after table or diff,
  - or a plain prose / bullet line (write the bullets as one block, e.g. `"- a\n- b"`).
  Do **not** pre-bullet the array — the renderer joins blocks verbatim so code fences and diagrams survive.
- **`not_tested[]`** — `{gap, why_not, mitigation}`; stays honest, gaps are not omissions.

> Automated test results are reported by GitHub Actions status checks and are intentionally **not** duplicated
> in the PR body (per create-pr's No-GitHub-duplication constraint). The Test Plan's reviewer checklist is
> `test_plan.acceptance` — issue-seeded acceptance criteria filled via `seed-from-issue.sh`, outside this contract.
- **`head_sha`** — the commit the evidence was gathered against. Used only by the freshness gate below.

## Rendering (what create-pr does)

`render-body.sh` emits, inside `## Test Plan`:

```markdown
**Manually verified** — <summary>
<details>
<summary>Evidence & steps</summary>

<evidence[0]>

<evidence[1]>
…
</details>
```

The blank line after `</summary>` is required for GitHub to render fenced code, mermaid, and tables inside
the `<details>`. With no `evidence`, only the summary line renders (no empty `<details>`). A legacy plain
string in `manually_verified` renders inline unchanged.

## Optional producer handoff (`if present`)

create-pr never depends on a producer — it degrades to manual fill / placeholder when none exists (same rule
as the `journey.sh` issue/investigation handoff). When a producer **is** present:

- **Producer** (e.g. the `verify` skill): actually runs/traces the change, **captures real output verbatim**
  into `evidence[]`, stamps `head_sha`, and writes the artifact — preferably into a `test_evidence` namespace
  in the shared `.git/journey.json` (reuses the store create-pr already reads; no new file convention).
- **Consumer** (create-pr, in the Generate step between `init-state.sh` and `render-body.sh`): if an artifact
  exists **and** its `head_sha` equals the branch HEAD, seed `test_plan` from it; otherwise ignore it and
  fall back to manual fill.

Discovery is "if present": no artifact and no `verify` skill ⇒ create-pr behaves exactly as today.

## Guards

- **Freshness (SHA-stamp gate).** Import evidence only when `head_sha` == current branch HEAD. Verbatim
  output captured against an older commit is *more* misleading than a vague claim — stale evidence is dropped
  with a note to re-verify, never silently imported. (Mirrors request-review's per-SHA dedup discipline.)
- **Redact secrets.** Pasting real output risks leaking tokens / PII / connection strings into a public PR
  body. The producer (or agent) must scrub before it lands. Fits the family's `safe-stage` / telemetry-opt-out
  posture.
- **Decisive, not dumps.** Keep evidence to the artifacts that prove the claim — the failing→passing line, the
  key trace — not entire logs. A reviewer should be able to scan it.
- **Never fabricate.** If the change couldn't actually be exercised, `evidence` stays empty and the placeholder
  shows — do not invent steps or output.
