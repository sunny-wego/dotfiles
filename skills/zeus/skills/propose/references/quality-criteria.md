# Quality criteria (decision docs)

Seven criteria a design/decision issue should pass before it's posted or declared ready. They are scored **by the Stage-1 reviewer-simulation reader, from the outside** (see `rfc-mode.md` → Stage 1, the discussability output) — a cold reader judging "is the decision clear?" beats the author judging it, which is why the old author-run self-check step was folded into the reader test. They're adapted for the GitHub-issue venue from the RFC tradition — an issue that fails one is weak by definition.

Note the boundary: these criteria (and the whole Stage-1 reader) verify the document agrees *with itself* and is discussable. Whether its claims agree *with the world* is Stage 2's job (`rfc-mode.md` → Targeted Grounding) — a perfectly self-consistent RFC proposing from false premises passes all seven.

## The 7 criteria

### 1. Decision clarity
A reader knows within ~60 seconds: what's changing, who needs to agree, and what happens if the answer is yes — **including the rough scope of work it commits to** (which components change, the upstream/cross-team dependencies, relative size), so a reviewer can judge effort and sequencing, not just direction. *Fail smells:* "we propose to explore a potential approach…" (exploration dressed as a decision is procrastination); a clear *direction* with no discoverable *shape of work*.

### 2. Problem concreteness
The problem is observable and, where possible, measured — pain in units (latency, error rate, engineer-hours, cost, % of cases). It is stated **first and independently of the chosen solution**: a reader who disagrees with the *approach* must still see the *need*, expressed as the explicit **requirements any solution must meet** (the bar an alternative is judged against). This is the anti-XY guard — lead with the solution and reviewers can only argue *how*, never *whether*, so they can never offer a better *what*. *Fail smells:* the doc opens with "we'll build X as a Y" and the problem is only inferable from it; no requirements list, so no alternative can be weighed against anything; "the system isn't scalable" / "this feels complex" with no number or concrete example.

### 3. Goals & non-goals
Goals are specific; **non-goals are explicit** (this maps to the issue's **What's Excluded** section — guardrails, not weakness). *Rule:* if everything is in scope, nothing is.

### 4. Tradeoffs stated
What gets *worse*, and why that's acceptable. Every real change loses somewhere. *Rule:* if the proposal has no downside, you haven't looked hard enough — surface it before a reviewer does.

### 5. Alternatives reasoned
At least: the status quo, one simpler option, one more radical. Each rejected **with a reason**, not vibes — and per house style, each rejected alternative is stated once (in What's Excluded or its decision row). When alternatives are load-bearing for buy-in, score them in that one place against the criterion-2 **requirements** (option × requirement), so the rejection is *demonstrated*, not asserted. *Fail smell:* "we considered X but decided not to" with no why.

### 6. Migration credible
For anything shipping as code: incremental rollout (not big-bang), a rollback path, and a kill switch / flag where the blast radius warrants it. *Rule:* a proposal with no believable rollout is architecture fanfic.

### 7. Agent-ready
For issues that an implementing agent will execute against:

| Requirement | Why |
|---|---|
| Invariants explicit (`MUST` / `MUST NOT`) | If you don't write them, the agent invents them |
| Constraints binary (allowed/forbidden) | An agent can't act on "prefer" or "ideally" |
| Acceptance signals defined | Bridges issue → tests → agent verification (the Verification section) |
| Coexistence/partial-state model explicit | Agents handle partial states badly — say what the in-between looks like |

## Pass test
If a fresh reader can state **the problem and the requirements an alternative would have to meet**, the decision, the main tradeoff, **the rough scope of work**, and what's out of scope in under a minute — and an implementing agent could act on the invariants without guessing — the issue passes. Otherwise, return to the relevant section (don't ship around the gap).
