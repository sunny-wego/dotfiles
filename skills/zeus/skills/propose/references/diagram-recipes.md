# Diagram recipes

When to use which, and copy-pasteable templates.

## Pick a diagram type

| Source describes | Use |
|---|---|
| Pipeline / fan-out / many-step flow | Mermaid `flowchart TD` or `LR` |
| Small state machine, ≤ 3 nodes | ASCII boxes |
| Sequence of events between systems | Mermaid `sequenceDiagram` (only when the order is the point) |
| Before / after of a single graph | Two ASCII columns side by side (per #683 Flip A) |

**Default lean:** Mermaid for anything ≥ 4 nodes; ASCII when the diagram fits in 4 lines.

Don't invent topology. If the source doesn't name nodes and edges (or arrows), skip the diagram and use a table instead.

## Recipe 1 — pipeline with side branches (Mermaid)

For shadow / parallel / fan-out architectures. Style classes mark live vs shadow vs shared.

```mermaid
flowchart TD
    WH[Webhook intake] --> PRE["pre-triage<br/>sets webhook_events.eligible"]
    PRE -- "eligible === true" --> ID["identify(caseId)<br/>+ fetchTicket(caseId)<br/><i>runs ONCE — owns Sprinklr write-back</i>"]
    ID --> PA["Promise.all([liveStep, shadowStep])"]
    PA --> LIVE["liveStep<br/>triage → execute → record"]
    PA --> SHADOW["shadowStep<br/>try/catch — never throws"]
    LIVE --> WE[(webhook_events)]
    LIVE --> ROW1[(cs_brain_analyses<br/>engine_version='v4.5')]
    SHADOW --> ROW2[(cs_brain_analyses<br/>engine_version='cs-agent-v1')]

    classDef live fill:#dff,stroke:#06c
    classDef shadowCls fill:#fed,stroke:#c60
    classDef shared fill:#efe,stroke:#080
    class WH,PRE,LIVE,WE,ROW1 live
    class SHADOW,ROW2 shadowCls
    class ID,PA shared
```

Substitute the node names, keep the classDef colour vocabulary (`live`/`shadow`/`shared`).

## Recipe 2 — redact / clone path (Mermaid `flowchart LR`)

For privacy / data-handling diagrams where the point is "which path mutates, which doesn't".

```mermaid
flowchart LR
    A[Webhook intake] --> B[triageStep]
    B --> C{{"triage in-memory<br/>full WF, full name, full phone"}}
    C -->|"Path A — dispatch (unredacted)"| D[dispatchAction]
    D --> E[Sprinklr]
    E --> G((Customer))
    C -->|"Path B — persist (clone, then redact)"| H[upsertAnalysis]
    H --> I["redactBlob"]
    I --> J[(Postgres)]

    classDef wire fill:#dff5dd,stroke:#1a7a1a,color:#000
    classDef redact fill:#fff3bf,stroke:#a17500,color:#000
    classDef store fill:#e3e8ff,stroke:#3b4ec0,color:#000
    class D,E,G wire
    class I redact
    class J store
```

## Recipe 3 — before / after flip (ASCII, side-by-side)

For small state changes — feature flag flips, engine swaps, ≤ 3 nodes.

```
         FLAG = false (today)                             FLAG = true (after flip)
         ===================                             ========================
  webhook                                          webhook
    │                                                │
    ├─► engine A ─► dispatch ─► customer ✉           ├─► engine A ─► (persist only)   ◄ shadow
    │                                                │
    └─► engine B (persist only)        ◄ shadow      └─► engine B ─► dispatch ─► customer ✉
```

## Recipe 4 — decision tree (ASCII)

For gating / matching logic with named branches. Keep it ≤ 6 lines.

```
  gate.evaluateGate(output)
        │
        ├─ no structural match           ─► gate=no_go:<reason>
        ├─ match, enabled === false      ─► gate=ready:<ruleId>   ◄ "would have fired"
        └─ match, enabled === true       ─► gate=go:<ruleId>      ◄ executes
```

## Recipe 5 — sequence (Mermaid, sparingly)

Only when the *order* of events between systems is the discussion point. Otherwise prefer a flowchart.

```mermaid
sequenceDiagram
    participant W as Webhook
    participant LT as liveTriage
    participant V4 as v4.5 step
    participant V1 as v1 shadow
    participant DB as cs_brain_analyses
    W->>LT: intake
    LT->>V4: start
    LT->>V1: start (parallel)
    V4-->>DB: insert engine_version=v4.5
    V1-->>DB: insert engine_version=cs-agent-v1
    V4-->>LT: result
    LT-->>W: 200 OK
```

## Style rules

- **Quote labels that contain punctuation** in Mermaid — `["text with (parens)"]`, not `[text with (parens)]`.
- **Use `<br/>` for line breaks** inside Mermaid nodes, not `\n`.
- **One Mermaid block per issue.** A second diagram usually means the first is doing too much; split into two issues.
- **Don't paste auto-generated diagrams from tools** without checking that every node name appears in the surrounding prose. If a node doesn't earn a mention in the body, it doesn't belong in the diagram.
- **No colour for ASCII.** Use box characters and arrows only.

## When *not* to include a diagram

- A 1-step or 2-step change. Sentence + table is shorter.
- A list of files modified. That's a table, not a graph.
- Anything where the diagram is only "X → Y". Use prose.
