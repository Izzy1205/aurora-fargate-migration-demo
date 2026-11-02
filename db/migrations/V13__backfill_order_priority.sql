-- V13: CONTRACT step 1 of 2. Fills orders.priority on rows from before V12.
--
-- Runs outside a transaction (see the .sql.conf next to this file), so each
-- batch commits on its own and holds its row locks only briefly. A big table
-- never sits behind one long UPDATE.
--
-- Safe to rerun. Every statement only touches rows that are still NULL, and
-- SET DEFAULT to the same value is a no-op. If it fails part way (say a
-- batch hits the 5 s lock_timeout behind a busy row), batches already
-- committed stay done and a plain rerun of the deploy picks up the rest.
-- Tested: Flyway on Postgres records no failed row here, so no repair step.
--
-- Order matters:
--   1. SET DEFAULT first. It is a catalog change only (no rewrite, no scan),
--      so the ACCESS EXCLUSIVE lock lasts milliseconds. From then on an
--      INSERT that leaves priority out gets 'standard', so no new NULLs show
--      up while the backfill runs or before V14. The app does not insert
--      orders today, so this is a guard, not a fix.
--   2. Backfill by primary key range, 5000 ids per batch, up to the highest
--      id that existed when the loop started. Rows added after that already
--      have the default.
--
-- 'standard' matches what the app shows for NULL (presenters.display_priority)
-- and passes the NOT VALID check from V12.
--
-- V14 (NOT NULL) stays in db/future/ until this has run in testing.

SET lock_timeout = '5s';

ALTER TABLE orders ALTER COLUMN priority SET DEFAULT 'standard';

DO $$
DECLARE
    batch_size constant bigint := 5000;
    lo bigint;
    hi bigint;
    done bigint := 0;
    n bigint;
BEGIN
    SELECT min(id), max(id) INTO lo, hi FROM orders WHERE priority IS NULL;
    IF lo IS NULL THEN
        RAISE NOTICE 'V13: no orders with NULL priority, nothing to backfill';
        RETURN;
    END IF;
    WHILE lo <= hi LOOP
        UPDATE orders
        SET priority = 'standard'
        WHERE id >= lo AND id < lo + batch_size
          AND priority IS NULL;
        GET DIAGNOSTICS n = ROW_COUNT;
        done := done + n;
        COMMIT;
        lo := lo + batch_size;
    END LOOP;
    RAISE NOTICE 'V13: set priority = standard on % orders', done;
END $$;

RESET lock_timeout;

COMMENT ON COLUMN orders.priority IS
    'Shipping priority. Defaults to standard. NULL only on rows V13 has not reached yet.';
