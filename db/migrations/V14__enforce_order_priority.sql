-- V14: CONTRACT step 2 of 2. Makes orders.priority NOT NULL.
--
-- Ship only after V13 has run and
-- SELECT count(*) FROM orders WHERE priority IS NULL returns 0.
--
-- Runs outside a transaction (see the .sql.conf next to this file), so each
-- statement commits on its own. In one transaction the first ACCESS
-- EXCLUSIVE lock (ADD CONSTRAINT) would be held until the end, including
-- through the VALIDATE scans, and block every read and write on orders.
--
-- Locks, in order:
--   1. Pre-check: plain SELECT, no blocking lock. Fails with a clear error,
--      before any change, if a NULL or unknown priority is left.
--   2. VALIDATE the V12 check: scans the table under SHARE UPDATE
--      EXCLUSIVE, so reads and writes keep flowing.
--   3. ADD CHECK (priority IS NOT NULL) NOT VALID: catalog only, ACCESS
--      EXCLUSIVE for milliseconds. New writes are checked from here on.
--   4. VALIDATE it: scan under SHARE UPDATE EXCLUSIVE again.
--   5. SET NOT NULL: ACCESS EXCLUSIVE, but Postgres 12+ skips its own full
--      scan because the validated check from step 4 already proves no NULLs.
--      (The V12 IN (...) check does not count, NULL passes it.)
--   6. DROP the helper check. NOT NULL now covers it. Milliseconds.
--
-- lock_timeout makes any step that would queue behind a long transaction
-- fail fast instead of blocking traffic behind it.
--
-- Safe to rerun. If a step fails (lock_timeout, or a NULL written between
-- the pre-check and step 4), the steps already committed are harmless on
-- their own and a plain rerun of the deploy finishes the job: the helper
-- check is only added if missing, VALIDATE on a valid constraint and SET
-- NOT NULL on a NOT NULL column are no-ops, and the drop uses IF EXISTS.
--
-- No SET DEFAULT here: V13 already set it to 'standard'.

SET lock_timeout = '5s';

DO $$
DECLARE
    nulls bigint;
    bad bigint;
BEGIN
    SELECT count(*) FILTER (WHERE priority IS NULL),
           count(*) FILTER (WHERE priority NOT IN ('standard', 'expedited', 'overnight'))
      INTO nulls, bad
      FROM orders;
    IF nulls > 0 OR bad > 0 THEN
        RAISE EXCEPTION 'V14: orders.priority has % NULL and % unknown values. Nothing was changed. Fix those rows, then deploy again.', nulls, bad
            USING HINT = 'SELECT id, priority FROM orders WHERE priority IS NULL OR priority NOT IN (''standard'', ''expedited'', ''overnight'')';
    END IF;
END $$;

ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_check;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'orders'::regclass
                     AND conname = 'orders_priority_not_null') THEN
        ALTER TABLE orders
            ADD CONSTRAINT orders_priority_not_null CHECK (priority IS NOT NULL) NOT VALID;
    END IF;
END $$;

ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_not_null;

ALTER TABLE orders ALTER COLUMN priority SET NOT NULL;

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_priority_not_null;

COMMENT ON COLUMN orders.priority IS
    'Shipping priority. NOT NULL, defaults to standard.';

RESET lock_timeout;
