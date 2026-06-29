# Verify the code satisfies the issue's contract (create-pr gate)

This proves the diff delivers what the **linked issue** promised — not just that "the agent coded
something." It runs in `/zeus:create-pr` whenever a PR has a linked issue, **no matter who wrote the code**
(`/goal`, a manual session, etc.). It's the mirror of `/zeus:propose`'s reader test — propose checks a
*document* is sound from the outside; here you check the *code* delivers what the issue promised, and you
capture proof a reviewer can re-run.

## Why it earns its place

An issue from `/zeus:propose` is written as an agent-ready contract on purpose: acceptance criteria, binary
MUST / MUST NOT invariants, and a `## Verification` block. Without this step the contract is decorative —
the value is in *consuming* it: running the verification, demonstrating each invariant, and confirming the
acceptance condition. Verifying with captured evidence **before the PR opens** is what makes the downstream
`/zeus:create-pr → /zeus:address-pr → /zeus:request-review` chain trustworthy; skip it and you've opened a PR
of unverified code into a pipeline that assumes it was verified.

## The loop

1. **Run the `## Verification` steps verbatim.** Don't paraphrase them into something easier. Use
   `/verify` or `/run` for app-level behavior (a real request, a rendered page, a CLI invocation) rather
   than hand-rolling a launch. Capture stdout/stderr, exit codes, and any rendered artifact.
2. **Demonstrate each invariant.** For every MUST, point to the line of code or the test that enforces it.
   For every MUST NOT, show the path is closed (a guard, a type, a test that would fail if it regressed). A
   MUST with nothing behind it is an *unmet* contract — treat it as a failure, not a pass.
3. **Confirm acceptance / Closes-when.** The literal condition the issue says will close it must hold now.
4. **On failure, fix and re-run** — a few rounds. The one thing you must not do is weaken a verification
   step to make it green. If a step is *wrong* (a contradictory requirement, an impossible assertion, a
   command that can't apply), that's a major decision: stop, surface it with the evidence, and let the
   human decide whether to amend the issue (`/zeus:propose` amend) or proceed.

## Packaging evidence for the PR

`/zeus:create-pr` renders a Test Plan with a `manually_verified` slot shaped `{summary, evidence: [...]}` where
each evidence item is a **verbatim** markdown block (a fenced command + its real output, a before/after
table, a mermaid trace). Hand your captured output over in that shape so the reviewer can independently
confirm the claim instead of trusting a paraphrase. Redact secrets; keep the decisive artifacts, not full
logs.

## When the issue has no contract (`has_contract:false`)

Thin tickets exist. If there's no `## Verification`, no invariants, and no acceptance list, infer the
acceptance bar from the prose, **state it back in one line before implementing**, and verify against that
inferred bar (build passes, the described behavior works, existing tests stay green). Say in the handoff
that the bar was inferred — so a reviewer knows it wasn't a written contract.
