-- Stadium seat delivery: fulfill to a row + seat instead of collection.

alter table public.orders
  add column if not exists seat_row text,
  add column if not exists seat_number text;

alter table public.orders drop constraint if exists orders_fulfillment_type_check;
alter table public.orders
  add constraint orders_fulfillment_type_check
  check (fulfillment_type in ('collection', 'takeout', 'dine_in', 'seat_delivery'));

alter table public.orders drop constraint if exists orders_seat_delivery_check;
alter table public.orders
  add constraint orders_seat_delivery_check
  check (
    (fulfillment_type = 'seat_delivery'
      and seat_row is not null and length(btrim(seat_row)) > 0
      and seat_number is not null and length(btrim(seat_number)) > 0)
    or
    (fulfillment_type <> 'seat_delivery'
      and seat_row is null
      and seat_number is null)
  );
