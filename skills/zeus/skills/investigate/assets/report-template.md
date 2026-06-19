# Report — {{TITLE}}

| | |
|---|---|
| **Investigation** | <one line: the symptom, where> |
| **Severity** | <Low/Med/High> (<impact, fail-open vs fail-closed>) |
| **Status** | 🔶 Open / ✅ Resolved (<one line>) |
| **Surface since** | <date> |
| **Tracking Epic** | #<epic> |
| **Related PRs** | <#… (merged), #… (closed unmerged), …> |

> **Reproducibility contract.** Every claim is tagged with an evidence ID (`[E1]`…`[En]`) resolved in
> the [Evidence appendix](#evidence-appendix). Appendix queries are bounded with **explicit UTC
> timestamps on both ends** against append-only stores, so re-running them later returns the same rows.
> Evidence from expiring/mutable sources is embedded **verbatim** and labelled *recorded* — it can be
> audited, not re-derived. Code references are **SHA-pinned** so line numbers never rot.

## Summary
<2–4 sentences: what failed, the headline finding, current state. Scope claims to what shipped.>

## Timeline (UTC)
| Time | Event |
|---|---|
| <ts> | <event> [E?] |

## Impact
<who/what is affected; fail-open vs fail-closed; scope boundaries>

## Failure taxonomy / root cause
<the buckets or the root cause, each attributed to an evidence item>

## Candidates ruled out
| Candidate | Verdict |
|---|---|
| <hypothesis> | ❌/⚠️ <why, with [E?]> |

## Prevention & fixes
### Done
- <PR #… — what it did; verified via [E?]>
### Pending (tracked in #<epic>)
| Action | Why it's the right shape |
|---|---|
| <fix> | <reasoning> |

## Lessons
1. <lesson as a transferable principle, not a scolding>

---

## Evidence appendix
<!-- Evidence items are appended here by scripts/evidence-add.sh as ### E1, E2, … -->
<!-- Each: one-line claim heading · bounded query (or labelled recorded) · captured result + as-of · reading -->

## References
- Tracking Epic: #<epic>
- Dashboards / data sources: <links>
- Code (pinned to <sha>): <permalinks>
