-- Allow signed-out (anon) users to browse the public venue catalog.
-- Orders, rewards, profiles and promo codes remain restricted to authenticated users.

drop policy if exists "Anon can read active venues" on public.venues;
create policy "Anon can read active venues"
on public.venues for select
to anon
using (is_active = true);

drop policy if exists "Anon can read open collection points" on public.collection_points;
create policy "Anon can read open collection points"
on public.collection_points for select
to anon
using (is_open = true);

drop policy if exists "Anon can read categories" on public.menu_categories;
create policy "Anon can read categories"
on public.menu_categories for select
to anon
using (true);

drop policy if exists "Anon can read available menu items" on public.menu_items;
create policy "Anon can read available menu items"
on public.menu_items for select
to anon
using (is_available = true);

drop policy if exists "Anon can read menu allergens" on public.menu_item_allergens;
create policy "Anon can read menu allergens"
on public.menu_item_allergens for select
to anon
using (true);
