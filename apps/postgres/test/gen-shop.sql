-- Shop dataset for the postgres test harness.
-- usage: psql "host=... user=app dbname=app sslmode=require" -v scale=0.25 -f gen-shop.sql
-- scale 1 = 1M customers, 50k products, 4M orders, 12M order lines, 3M events
-- (~4.3 GB on disk); scale 0.25 is ~1.1 GB. Deterministic: the same scale gives
-- the same rows, so shop-checksum.sql output can be compared across runs.
\set ON_ERROR_STOP on
\timing on
\if :{?scale}
\else
\set scale 0.25
\endif
SET synchronous_commit = off;
SELECT greatest(1, (1000000 * :scale)::bigint) AS ncust,
       greatest(100, (50000 * :scale)::bigint) AS nprod,
       greatest(1, (4000000 * :scale)::bigint) AS nord,
       greatest(1, (3000000 * :scale)::bigint) AS nev \gset
CREATE TABLE IF NOT EXISTS customers (
  id bigserial PRIMARY KEY, name text NOT NULL, email text NOT NULL UNIQUE, country char(2) NOT NULL,
  address text, profile jsonb NOT NULL, created_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS products (
  id bigserial PRIMARY KEY, sku text NOT NULL UNIQUE, title text NOT NULL, description text,
  price_cents int NOT NULL, tags text[]);
CREATE TABLE IF NOT EXISTS orders (
  id bigserial PRIMARY KEY, customer_id bigint NOT NULL REFERENCES customers(id), status text NOT NULL,
  total_cents bigint NOT NULL DEFAULT 0, note text, placed_at timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS order_items (
  order_id bigint NOT NULL REFERENCES orders(id), line int NOT NULL, product_id bigint NOT NULL REFERENCES products(id),
  qty int NOT NULL, price_cents int NOT NULL, PRIMARY KEY(order_id, line));
CREATE TABLE IF NOT EXISTS events (
  id bigserial PRIMARY KEY, at timestamptz NOT NULL, customer_id bigint, kind text NOT NULL, payload jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS ledger (id bigint PRIMARY KEY, writer text NOT NULL, pad text, at timestamptz NOT NULL DEFAULT now());
INSERT INTO customers(name,email,country,address,profile,created_at)
SELECT 'Customer '||g, 'user'||g||'@example'||(g%97)||'.com', (ARRAY['US','DE','FR','GB','JP','BR','IN','CA','AU','NL'])[1+g%10],
  g||' '||md5(g::text)||' Main St, '||md5((g*7)::text),
  jsonb_build_object('plan',(ARRAY['free','pro','team','enterprise'])[1+g%4],'tags',jsonb_build_array(md5(g::text),md5((g+1)::text)),'prefs',jsonb_build_object('email',g%2=0,'sms',g%3=0)),
  timestamptz '2026-01-01' - (g||' seconds')::interval*37 FROM generate_series(1,:ncust) g;
INSERT INTO products(sku,title,description,price_cents,tags)
SELECT 'SKU-'||lpad(g::text,7,'0'), 'Product '||g, repeat(md5(g::text),8), 100+(g*37)%99900, ARRAY[md5((g%50)::text),md5((g%7)::text)]
FROM generate_series(1,:nprod) g;
INSERT INTO orders(customer_id,status,total_cents,note,placed_at)
SELECT 1+(g::bigint*7919)%:ncust, (ARRAY['new','paid','shipped','delivered','returned'])[1+g%5], 0, repeat(md5(g::text),3),
  timestamptz '2026-01-01' - (g||' seconds')::interval*5 FROM generate_series(1,:nord) g;
INSERT INTO order_items(order_id,line,product_id,qty,price_cents)
SELECT o, l, 1+((o*31+l*17)%:nprod), 1+(o+l)%5, 100+((o*31+l*17)%:nprod*37)%99900
FROM generate_series(1,:nord) o, generate_series(1,3) l;
UPDATE orders o SET total_cents = s.t
FROM (SELECT order_id, sum(qty::bigint*price_cents) t FROM order_items GROUP BY order_id) s WHERE s.order_id=o.id;
INSERT INTO events(at,customer_id,kind,payload)
SELECT timestamptz '2026-01-01'-(g||' seconds')::interval, 1+g%:ncust, (ARRAY['view','click','cart','purchase','login'])[1+g%5],
 jsonb_build_object('ua',md5((g%1000)::text),'path','/p/'||(g%:nprod),'ms',g%900,'blob',repeat(md5(g::text),4))
FROM generate_series(1,:nev) g;
CREATE INDEX IF NOT EXISTS orders_customer ON orders(customer_id);
CREATE INDEX IF NOT EXISTS orders_placed ON orders(placed_at);
CREATE INDEX IF NOT EXISTS events_customer ON events(customer_id);
CREATE INDEX IF NOT EXISTS events_at ON events(at);
ANALYZE;
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;
