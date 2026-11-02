# Contract steps (not applied yet)

Flyway only reads `db/migrations/`. Files here show what the next release
will look like. Move one at a time into `db/migrations/`, a release apart.

Rollout of `orders.priority`:

1. V12 (shipped, PR #41): adds the nullable column and a NOT VALID check.
2. V13 (shipped): sets the default to `standard` and backfills old rows in
   committed batches. Now in `db/migrations/`.
3. `V14__enforce_order_priority.sql` (next): validates the check and sets
   NOT NULL. Its SET DEFAULT is now a no-op, since V13 already set it.

Ship V14 only after V13 has been applied in testing and
`SELECT count(*) FROM orders WHERE priority IS NULL` returns 0 there.
V14 fails (and changes nothing) if any NULL is left.
