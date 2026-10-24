-- Release N+1: backfill old rows. Small batches keep row locks short.
-- On a big table run this from a job that loops until 0 rows update.
UPDATE orders
SET priority = 'standard'
WHERE id IN (
    SELECT id FROM orders WHERE priority IS NULL ORDER BY id LIMIT 1000
);
