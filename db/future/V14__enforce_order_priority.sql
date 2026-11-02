-- Release N+2: contract. Only after the backfill has finished and every
-- running app version writes priority.
SET LOCAL lock_timeout = '5s';

-- Scans the table but takes only a SHARE UPDATE EXCLUSIVE lock, so reads and
-- writes keep flowing.
ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_check;

ALTER TABLE orders ALTER COLUMN priority SET DEFAULT 'standard';

-- SET NOT NULL normally scans the whole table under an ACCESS EXCLUSIVE lock.
-- Postgres 12+ skips that scan when a validated CHECK (priority IS NOT NULL)
-- already proves there are no NULLs, so add and validate that first.
-- (The IN (...) check above does not count: NULL passes it.)
ALTER TABLE orders ADD CONSTRAINT orders_priority_not_null CHECK (priority IS NOT NULL) NOT VALID;
ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_not_null;
ALTER TABLE orders ALTER COLUMN priority SET NOT NULL;
ALTER TABLE orders DROP CONSTRAINT orders_priority_not_null;
