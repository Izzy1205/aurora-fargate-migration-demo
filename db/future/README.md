# Contract steps (not applied)

Flyway only reads `db/migrations/`. These files show what the next releases
would look like once every running app version understands `priority`. Move
one at a time into `db/migrations/`, a release apart, never in the same
release as V12.

1. `V13__backfill_order_priority.sql` fills old rows in small batches.
2. `V14__enforce_order_priority.sql` validates the check, adds the default and
   sets NOT NULL.
