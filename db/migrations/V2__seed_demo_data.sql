-- V2: fake demo data. 200 customers, 600 orders.
-- Every name is "Customer NNNN" and every email is on example.com
-- (reserved for documentation by RFC 2606). No real people, no real PII.
-- Values are derived from the row number, so every rebuild gets the same data.

INSERT INTO customers (full_name, email, created_at)
SELECT
    format('Customer %s', lpad(g::text, 4, '0')),
    format('customer%s@example.com', lpad(g::text, 4, '0')),
    now() - make_interval(days => g)
FROM generate_series(1, 200) AS g;

WITH c AS (
    SELECT id, row_number() OVER (ORDER BY id) - 1 AS n
    FROM customers
)
INSERT INTO orders (customer_id, status, total_cents, created_at)
SELECT
    c.id,
    (ARRAY['pending', 'shipped', 'delivered', 'cancelled'])[1 + (g % 4)],
    500 + (g * 1379) % 50000,
    now() - make_interval(hours => g * 3)
FROM generate_series(1, 600) AS g
JOIN c ON c.n = g % 200;
