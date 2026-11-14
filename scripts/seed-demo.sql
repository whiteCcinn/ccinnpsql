-- CcinnPsql demo schema (PostgreSQL 9.6+). Used by the integration tests and screenshots.
-- Run with: docker exec -i ccinnpsql-it-pg17 psql -U ccinn -d ccinn -v ON_ERROR_STOP=1 < scripts/seed-demo.sql
DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
COMMENT ON SCHEMA shop IS 'Demo storefront';
SET search_path TO shop, public;

CREATE TYPE order_status AS ENUM ('new', 'paid', 'shipped', 'cancelled');
CREATE DOMAIN email AS text CHECK (VALUE ~ '^[^@]+@[^@]+$');
CREATE TYPE money_amount AS (amount numeric(12,2), currency char(3));

CREATE TABLE customers (
    id bigserial PRIMARY KEY,
    email email NOT NULL UNIQUE,
    name text NOT NULL,
    country char(2) NOT NULL DEFAULT 'MY',
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE customers IS 'People who buy things';
COMMENT ON COLUMN customers.email IS 'Login e-mail';

CREATE TABLE products (
    id serial PRIMARY KEY,
    sku text NOT NULL,
    title text NOT NULL,
    price numeric(10,2) NOT NULL CHECK (price >= 0),
    tags text[] NOT NULL DEFAULT '{}',
    attributes jsonb
);
CREATE UNIQUE INDEX products_sku_key ON products (lower(sku));
CREATE INDEX products_title_idx ON products (title);
CREATE INDEX products_unused_idx ON products (price);

CREATE TABLE orders (
    id bigserial PRIMARY KEY,
    customer_id bigint NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
    status order_status NOT NULL DEFAULT 'new',
    total money_amount,
    placed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON orders (customer_id);

CREATE TABLE order_items (
    order_id bigint NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    product_id int NOT NULL REFERENCES products (id),
    quantity int NOT NULL CHECK (quantity > 0),
    unit_price numeric(10,2) NOT NULL,
    PRIMARY KEY (order_id, product_id)
);

-- Classic inheritance.
CREATE TABLE events (id bigserial, happened_at timestamptz NOT NULL DEFAULT now(), payload text);
CREATE TABLE events_archive (archived_by text) INHERITS (events);

CREATE FUNCTION touch_customer() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.name := trim(NEW.name);
    RETURN NEW;
END $$;
CREATE TRIGGER customers_touch BEFORE INSERT OR UPDATE ON customers FOR EACH ROW EXECUTE PROCEDURE touch_customer();

CREATE FUNCTION order_total(p_order bigint) RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT coalesce(sum(quantity * unit_price), 0) FROM shop.order_items WHERE order_id = p_order
$$;
COMMENT ON FUNCTION order_total(bigint) IS 'Sum of the order lines';

CREATE VIEW paid_orders AS
    SELECT o.id, c.name, o.placed_at FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.status = 'paid';

CREATE MATERIALIZED VIEW daily_revenue AS
    SELECT date_trunc('day', o.placed_at) AS day, count(*) AS orders, sum(order_total(o.id)) AS revenue
    FROM orders o GROUP BY 1;
CREATE UNIQUE INDEX daily_revenue_day ON daily_revenue (day);

CREATE MATERIALIZED VIEW top_products AS SELECT product_id, sum(quantity) AS sold FROM order_items GROUP BY 1;

CREATE SEQUENCE invoice_numbers START 1000 INCREMENT 10 MAXVALUE 2000;
SELECT setval('invoice_numbers', 1900);
CREATE SEQUENCE ticket_numbers MAXVALUE 32767;

INSERT INTO customers (email, name, country)
SELECT 'user' || g || '@example.com', 'Customer ' || g, (ARRAY['MY','SG','JP','DE'])[1 + g % 4] FROM generate_series(1, 200) g;
INSERT INTO products (sku, title, price, tags, attributes)
SELECT 'SKU-' || g, 'Product ' || g, (g * 3.5)::numeric(10,2), ARRAY['tag' || (g % 5)], jsonb_build_object('color', (ARRAY['red','blue'])[1 + g % 2])
FROM generate_series(1, 50) g;
INSERT INTO orders (customer_id, status, total, placed_at)
SELECT 1 + g % 200, (ARRAY['new','paid','shipped','cancelled']::order_status[])[1 + g % 4], ROW(g * 2.5, 'MYR')::money_amount,
       now() - (g || ' hours')::interval
FROM generate_series(1, 2000) g;
INSERT INTO order_items SELECT o.id, 1 + o.id % 50, 1 + o.id % 3, 9.99 FROM orders o;
INSERT INTO events (payload) SELECT 'event ' || g FROM generate_series(1, 100) g;
INSERT INTO events_archive (payload, archived_by) SELECT 'old ' || g, 'job' FROM generate_series(1, 10) g;
-- Dead tuples for the maintenance views.
UPDATE products SET title = title || ' ' WHERE id % 2 = 0;
REFRESH MATERIALIZED VIEW daily_revenue;
REFRESH MATERIALIZED VIEW top_products;
ANALYZE;
