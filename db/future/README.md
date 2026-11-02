# Contract steps waiting to ship

Flyway only reads `db/migrations/`. This folder holds migrations that are
written but must wait for an earlier release, such as a contract step that
can only run after a backfill has finished in every environment. Move one
at a time into `db/migrations/`, a release apart. It is empty when nothing
is waiting.

Rollout of `orders.priority` (complete, all steps are in `db/migrations/`):

1. V12 (PR #41): adds the nullable column and a NOT VALID check.
2. V13 (PR #45): sets the default to `standard` and backfills old rows in
   committed batches.
3. V14: validates the V12 check, then sets NOT NULL through a validated
   `CHECK (priority IS NOT NULL)` so Postgres skips the full table scan
   under an ACCESS EXCLUSIVE lock. It fails before changing anything if a
   NULL is left.
