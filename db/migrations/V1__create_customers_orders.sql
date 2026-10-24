-- V1: base schema for the demo.
CREATE TABLE customers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   text        NOT NULL,
    email       text        NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint      NOT NULL REFERENCES customers (id),
    status       text        NOT NULL CHECK (status IN ('pending', 'shipped', 'delivered', 'cancelled')),
    total_cents  integer     NOT NULL CHECK (total_cents >= 0),
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX orders_customer_id_idx ON orders (customer_id);
