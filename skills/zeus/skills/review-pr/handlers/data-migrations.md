# Handler: data-migrations

Schema changes and the data they touch. Runs when the diff includes
`migrations/`, schema/model changes, or new tables/columns/indexes.

**Owns:** migration up/down reversibility, backfill correctness, data loss,
retention/growth, missing indexes for the query patterns added, constraints &
nullability, default backfill on large tables, ORM-model ↔ migration drift.
**Not this:** the app logic that consumes the data (→ correctness / api-contract).

## What to look for
- **Reversibility:** does `downgrade` actually reverse `upgrade`? Does it round-
  trip cleanly, or drop data / fail on re-apply?
- **Unbounded growth:** a new table/log that only ever gets INSERTs with no
  prune/TTL — does anything bound it? (PR-223's `webhook_deliveries` grows with
  total webhook volume, including ignored events, with no prune job and no
  `received_at` index for one.) Check whether rows are written for things you
  don't even act on.
- **Index coverage:** a new query pattern (filter/sort/join column) with no
  supporting index; or a prune/retention query with nothing to scan efficiently.
- **Locking / big-table hazards:** adding a NOT NULL column with a default,
  rewriting a large table, or a backfill that locks — fine on an empty dev DB,
  painful in prod.
- **Constraints & nullability:** a new NOT NULL/UNIQUE/CHECK that existing rows
  would violate; nullable where the code assumes present.
- **Model drift:** the ORM model and the migration disagree (column type,
  nullability, index present in one but not the other).

## How to verify (Tier 1)
- Apply the migration to a **throwaway** DB via the repo's own migration tool
  (alembic / Flyway / Liquibase / Prisma / Knex / sqlx / goose / …) to `head`,
  confirm it lands; then reverse one step and re-apply — show the round-trip.
  Capture steps + output → `confirmed`. (PR-223's alembic 0010 up/down was
  confirmed this way; the shape is identical for any tool.)
- Inspect the resulting columns/PK/indexes via the catalog and compare to the
  model.
- **Fence:** throwaway DB you created this run only — never run a migration
  against a shared/long-lived database. No throwaway DB available → `hypothesis`.

## Emit
`concern` = the data hazard (growth, irreversibility, lock, drift); `question`
asks the retention/reversibility intent. For growth, ask the bounding story —
don't lead with "add a prune job".
