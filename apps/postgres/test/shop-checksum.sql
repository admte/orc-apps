-- One line per shop table: row count and a content checksum. Compare before and after
-- a scenario; any difference is lost or corrupted data outside the ledger.
\pset tuples_only on
\pset format unaligned
select 'customers',count(*),sum(hashtext(email)::bigint) from customers
union all select 'products',count(*),sum(price_cents) from products
union all select 'orders',count(*),sum(total_cents) from orders
union all select 'order_items',count(*),sum(qty::bigint*price_cents) from order_items
union all select 'events',count(*),sum(hashtext(payload::text)::bigint) from events
order by 1;
