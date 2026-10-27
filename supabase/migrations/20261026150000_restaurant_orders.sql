-- Restaurants (dine-in / takeout) + allow kind=restaurant on venues.

alter table public.venues drop constraint if exists venues_kind_check;
alter table public.venues
  add constraint venues_kind_check check (kind in ('cafe', 'venue', 'restaurant', 'private'));

alter table public.orders
  add column if not exists fulfillment_type text not null default 'collection',
  add column if not exists payment_mode text not null default 'stripe',
  add column if not exists party_size integer;

alter table public.orders drop constraint if exists orders_fulfillment_type_check;
alter table public.orders
  add constraint orders_fulfillment_type_check
  check (fulfillment_type in ('collection', 'takeout', 'dine_in'));

alter table public.orders drop constraint if exists orders_payment_mode_check;
alter table public.orders
  add constraint orders_payment_mode_check
  check (payment_mode in ('stripe', 'at_venue'));

alter table public.orders drop constraint if exists orders_party_size_check;
alter table public.orders
  add constraint orders_party_size_check
  check (party_size is null or (party_size >= 1 and party_size <= 20));
