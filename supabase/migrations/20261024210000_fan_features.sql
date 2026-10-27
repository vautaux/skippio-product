-- Fan app features: profiles access, favourites, Stripe Checkout tracking and the
-- Aviva Stadium demo menu (real rows the app reads, replacing hard-coded samples).

-- ---------------------------------------------------------------------------
-- Profiles: users can read and edit their own row (RLS was on with no policy).
-- ---------------------------------------------------------------------------
drop policy if exists "Users can read own profile" on public.profiles;
create policy "Users can read own profile"
on public.profiles for select
to authenticated
using (auth.uid() = id);

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
on public.profiles for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- Favourites
-- ---------------------------------------------------------------------------
create table if not exists public.favourite_venues (
  user_id uuid not null references auth.users(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now()),
  primary key (user_id, venue_id)
);

alter table public.favourite_venues enable row level security;

drop policy if exists "Users can read own favourites" on public.favourite_venues;
create policy "Users can read own favourites"
on public.favourite_venues for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users can add own favourites" on public.favourite_venues;
create policy "Users can add own favourites"
on public.favourite_venues for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Users can remove own favourites" on public.favourite_venues;
create policy "Users can remove own favourites"
on public.favourite_venues for delete
to authenticated
using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Orders: remember which Stripe Checkout Session is paying for the order.
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists checkout_session_id text unique;

-- ---------------------------------------------------------------------------
-- Aviva Stadium demo menu. Fixed ids keep this migration idempotent.
-- Prices are demo prices in cents. No product photos: the app shows an icon.
-- ---------------------------------------------------------------------------
insert into public.collection_points
  (id, venue_id, name, floor_label, block_label, average_wait_seconds, is_open)
values
  (
    '19c565c1-cfaf-4348-88c5-592706f7fd7a',
    'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11',
    'Fast Track Bar', 'Floor 1', 'Block 120', 90, true
  )
on conflict (id) do update set
  name = excluded.name,
  floor_label = excluded.floor_label,
  block_label = excluded.block_label,
  average_wait_seconds = excluded.average_wait_seconds,
  is_open = excluded.is_open;

insert into public.menu_categories (id, venue_id, title, sort_order)
values
  ('95b32e8e-b29e-4c99-a508-289e06af7645', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', 'Pints', 1),
  ('9a8f057f-abec-4f9b-a95a-2f0f86ee1835', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', 'Wine', 2),
  ('0c3d2050-f0fa-4f45-a444-14efb60afec1', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', 'Cans', 3),
  ('7a1c0000-0000-4000-8000-000000000004', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', 'Pre-mixed cans', 4),
  ('7a1c0000-0000-4000-8000-000000000005', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', 'Soft Drinks', 5)
on conflict (id) do update set
  title = excluded.title,
  sort_order = excluded.sort_order;

insert into public.menu_items
  (id, venue_id, category_id, title, subtitle, volume_label, price_cents, currency, is_available, sort_order)
values
  -- Pints
  ('5ff1e3da-2d0d-4fdd-8e42-bf8a353157f8', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '95b32e8e-b29e-4c99-a508-289e06af7645', 'Guinness', 'Classic stout', '568ml', 770, 'EUR', true, 1),
  ('2cedde80-b602-43a7-b8d0-d4ecf15f6368', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '95b32e8e-b29e-4c99-a508-289e06af7645', 'Guinness 0.0', 'Alcohol free stout', '568ml', 710, 'EUR', true, 2),
  ('ab4e725b-76cc-4f90-95cb-884b95ac4f82', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '95b32e8e-b29e-4c99-a508-289e06af7645', 'Carlsberg', 'Lager', '568ml', 810, 'EUR', true, 3),
  ('7a1c0000-0000-4000-8000-000000000101', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '95b32e8e-b29e-4c99-a508-289e06af7645', 'Rockshore Lager', 'Lager', '568ml', 810, 'EUR', true, 4),
  -- Wine
  ('7a1c0000-0000-4000-8000-000000000201', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '9a8f057f-abec-4f9b-a95a-2f0f86ee1835', 'Red Wine', 'Merlot', '187ml', 880, 'EUR', true, 1),
  ('7a1c0000-0000-4000-8000-000000000202', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '9a8f057f-abec-4f9b-a95a-2f0f86ee1835', 'White Wine', 'Pinot Grigio', '187ml', 880, 'EUR', true, 2),
  ('7a1c0000-0000-4000-8000-000000000203', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '9a8f057f-abec-4f9b-a95a-2f0f86ee1835', 'Prosecco', 'Sparkling', '200ml', 950, 'EUR', true, 3),
  -- Cans
  ('7a1c0000-0000-4000-8000-000000000301', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '0c3d2050-f0fa-4f45-a444-14efb60afec1', 'Heineken', 'Lager', '440ml', 790, 'EUR', true, 1),
  ('7a1c0000-0000-4000-8000-000000000302', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '0c3d2050-f0fa-4f45-a444-14efb60afec1', 'Corona', 'Lager', '330ml', 750, 'EUR', true, 2),
  ('7a1c0000-0000-4000-8000-000000000303', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '0c3d2050-f0fa-4f45-a444-14efb60afec1', 'Bulmers', 'Irish cider', '500ml', 800, 'EUR', true, 3),
  -- Pre-mixed cans
  ('7a1c0000-0000-4000-8000-000000000401', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '7a1c0000-0000-4000-8000-000000000004', 'Gin & Tonic', 'Pre-mixed', '250ml', 850, 'EUR', true, 1),
  ('7a1c0000-0000-4000-8000-000000000402', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '7a1c0000-0000-4000-8000-000000000004', 'Vodka & Cola', 'Pre-mixed', '250ml', 850, 'EUR', true, 2),
  -- Soft drinks
  ('7a1c0000-0000-4000-8000-000000000501', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '7a1c0000-0000-4000-8000-000000000005', 'Coca-Cola', 'Soft drink', '500ml', 350, 'EUR', true, 1),
  ('7a1c0000-0000-4000-8000-000000000502', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '7a1c0000-0000-4000-8000-000000000005', 'Sprite', 'Soft drink', '500ml', 350, 'EUR', true, 2),
  ('7a1c0000-0000-4000-8000-000000000503', 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11', '7a1c0000-0000-4000-8000-000000000005', 'Still Water', 'Water', '500ml', 300, 'EUR', true, 3)
on conflict (id) do update set
  category_id = excluded.category_id,
  title = excluded.title,
  subtitle = excluded.subtitle,
  volume_label = excluded.volume_label,
  price_cents = excluded.price_cents,
  is_available = excluded.is_available,
  sort_order = excluded.sort_order;

insert into public.menu_item_allergens (menu_item_id, allergen)
values
  ('5ff1e3da-2d0d-4fdd-8e42-bf8a353157f8', 'Barley'),
  ('2cedde80-b602-43a7-b8d0-d4ecf15f6368', 'Barley'),
  ('ab4e725b-76cc-4f90-95cb-884b95ac4f82', 'Barley'),
  ('7a1c0000-0000-4000-8000-000000000101', 'Barley'),
  ('7a1c0000-0000-4000-8000-000000000201', 'Sulphites'),
  ('7a1c0000-0000-4000-8000-000000000202', 'Sulphites'),
  ('7a1c0000-0000-4000-8000-000000000203', 'Sulphites'),
  ('7a1c0000-0000-4000-8000-000000000301', 'Barley'),
  ('7a1c0000-0000-4000-8000-000000000302', 'Barley'),
  ('7a1c0000-0000-4000-8000-000000000303', 'Sulphites')
on conflict (menu_item_id, allergen) do nothing;
