-- Release N+1: backfill in small batches to keep row locks short.
UPDATE orders
SET priority = 'standard'
WHERE id IN (
    SELECT id FROM orders WHERE priority IS NULL ORDER BY id LIMIT 1000
);
