-- Schema for the bigger catalog and the richer basket:
--   * venues.group_name       small brand label shown above the venue title
--   * orders.pickup_at        null = as soon as possible, otherwise the chosen time slot
--   * image_credits           attribution for every licensed photo (CC BY / CC BY-SA need it)
--   * menu options            size / milk / syrup style choices that change the price
--   * unavailable items       visible (shown as "Temporarily Unavailable"), still not orderable

alter table public.venues
  add column if not exists group_name text;

alter table public.orders
  add column if not exists pickup_at timestamptz;

-- ---------------------------------------------------------------------------
-- Unavailable items are now readable so the app can grey them out.
-- create-order still refuses to sell them.
-- ---------------------------------------------------------------------------
drop policy if exists "Public can read available menu items" on public.menu_items;
drop policy if exists "Public can read menu items" on public.menu_items;
create policy "Public can read menu items"
on public.menu_items for select
to authenticated
using (true);

drop policy if exists "Anon can read available menu items" on public.menu_items;
drop policy if exists "Anon can read menu items" on public.menu_items;
create policy "Anon can read menu items"
on public.menu_items for select
to anon
using (true);

-- ---------------------------------------------------------------------------
-- Photo credits
-- ---------------------------------------------------------------------------
create table if not exists public.image_credits (
  image_key text primary key,
  title text not null,
  author text not null,
  license text not null,
  license_url text,
  source_url text not null,
  created_at timestamptz not null default timezone('utc', now())
);

alter table public.image_credits enable row level security;

drop policy if exists "Anyone can read image credits" on public.image_credits;
create policy "Anyone can read image credits"
on public.image_credits for select
to anon, authenticated
using (true);

-- ---------------------------------------------------------------------------
-- Item options (size, milk, syrups). Prices are deltas on top of the item price and
-- are always recalculated by create-order.
-- ---------------------------------------------------------------------------
create table if not exists public.menu_option_groups (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  title text not null,
  is_required boolean not null default false,
  allows_multiple boolean not null default false,
  sort_order integer not null default 0
);

create table if not exists public.menu_options (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.menu_option_groups(id) on delete cascade,
  title text not null,
  price_delta_cents integer not null default 0 check (price_delta_cents >= 0),
  sort_order integer not null default 0
);

create table if not exists public.menu_item_option_groups (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  group_id uuid not null references public.menu_option_groups(id) on delete cascade,
  primary key (menu_item_id, group_id)
);

alter table public.menu_option_groups enable row level security;
alter table public.menu_options enable row level security;
alter table public.menu_item_option_groups enable row level security;

drop policy if exists "Anyone can read option groups" on public.menu_option_groups;
create policy "Anyone can read option groups"
on public.menu_option_groups for select to anon, authenticated using (true);

drop policy if exists "Anyone can read options" on public.menu_options;
create policy "Anyone can read options"
on public.menu_options for select to anon, authenticated using (true);

drop policy if exists "Anyone can read item option links" on public.menu_item_option_groups;
create policy "Anyone can read item option links"
on public.menu_item_option_groups for select to anon, authenticated using (true);

-- What the customer picked, frozen at order time (title and price delta).
alter table public.order_items
  add column if not exists options_snapshot jsonb not null default '[]'::jsonb;

-- ---------------------------------------------------------------------------
-- Demo promo codes (10% off, and 2.00 off).
-- ---------------------------------------------------------------------------
insert into public.promo_codes (code, discount_type, discount_value, is_active)
values
  ('SKIP10', 'percentage', 10, true),
  ('WELCOME2', 'fixed', 2.00, true)
on conflict (code) do update set
  discount_type = excluded.discount_type,
  discount_value = excluded.discount_value,
  is_active = excluded.is_active;

-- Codes are checked by create-order only; signed-in users must not be able to list them.
drop policy if exists "Users can read active promo codes" on public.promo_codes;

-- Public bucket for catalog photos (uploaded by scripts/build_catalog.py --upload).
insert into storage.buckets (id, name, public)
values ('catalog', 'catalog', true)
on conflict (id) do update set public = true;
