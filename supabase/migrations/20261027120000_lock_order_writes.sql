-- Signed-in clients could insert their own orders and set status, totals, and
-- checkout_session_id themselves. Orders are created only by create-order,
-- which uses the service role and bypasses RLS. Clients keep read access.

drop policy if exists "Users can create their own orders" on public.orders;

revoke insert, update, delete on public.orders from anon, authenticated;
revoke insert, update, delete on public.order_items from anon, authenticated;
revoke insert, update, delete on public.order_status_events from anon, authenticated;

-- Drop any session id that is not a real Stripe Checkout Session id, then
-- refuse new values that could be pasted into a Stripe URL.
update public.orders
set checkout_session_id = null
where checkout_session_id is not null
  and checkout_session_id !~ '^cs_(test|live)_[A-Za-z0-9]+$';

alter table public.orders drop constraint if exists orders_checkout_session_id_format;
alter table public.orders
  add constraint orders_checkout_session_id_format
  check (
    checkout_session_id is null
    or checkout_session_id ~ '^cs_(test|live)_[A-Za-z0-9]+$'
  );
