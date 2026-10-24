-- V3: EXPAND step. Adds orders.priority as a nullable column.
--
-- Why this is safe to ship before the new app code:
--   * Nullable with no default, so Postgres only changes the catalog. No table
--     rewrite, and the ACCESS EXCLUSIVE lock is held for milliseconds.
--   * Old app code never selects the column, so it keeps working.
--   * Every existing row reads as NULL. New app code treats NULL as "standard".
--   * lock_timeout makes the migration fail fast instead of queueing behind a
--     long transaction and blocking live traffic.
--
-- The CHECK is added NOT VALID: it applies to new writes right away without
-- scanning existing rows. NULL passes a CHECK, so old rows are fine.
--
-- Contract steps (backfill, NOT NULL, default) come in later releases. See
-- db/future/.

SET LOCAL lock_timeout = '5s';

ALTER TABLE orders ADD COLUMN priority text;

ALTER TABLE orders
    ADD CONSTRAINT orders_priority_check
    CHECK (priority IN ('standard', 'expedited', 'overnight')) NOT VALID;

COMMENT ON COLUMN orders.priority IS
    'Shipping priority. NULL means not set yet; the app shows it as standard.';
