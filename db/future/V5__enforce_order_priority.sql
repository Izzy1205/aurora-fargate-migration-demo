-- Release N+2: only after the backfill is done and every app version writes priority.
SET LOCAL lock_timeout = '5s';

-- Only a SHARE UPDATE EXCLUSIVE lock, so reads and writes keep flowing.
ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_check;

ALTER TABLE orders ALTER COLUMN priority SET DEFAULT 'standard';

-- A validated NOT NULL check lets SET NOT NULL skip its full table scan.
ALTER TABLE orders ADD CONSTRAINT orders_priority_not_null CHECK (priority IS NOT NULL) NOT VALID;
ALTER TABLE orders VALIDATE CONSTRAINT orders_priority_not_null;
ALTER TABLE orders ALTER COLUMN priority SET NOT NULL;
ALTER TABLE orders DROP CONSTRAINT orders_priority_not_null;
