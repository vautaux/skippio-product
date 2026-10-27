-- Fields the fan app's Home screen needs: category (café / venue / private),
-- live open/closed state, a one-line subtitle, a logo and map coordinates.

alter table public.venues
  add column if not exists kind text not null default 'venue',
  add column if not exists is_open boolean not null default true,
  add column if not exists subtitle text,
  add column if not exists logo_url text,
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

alter table public.venues
  drop constraint if exists venues_kind_check;
alter table public.venues
  add constraint venues_kind_check check (kind in ('cafe', 'venue', 'private'));

-- Demo catalogue. Coordinates are approximate (good enough for "x km away").
-- Cover images are Wikimedia Commons:
--   Aviva Stadium: public domain.
--   Fairyhouse:    CC BY 2.0, photo by Dan Heap (https://commons.wikimedia.org).
-- Cafés and Laya Arena have no image; the app renders an initials tile.
insert into public.venues
  (id, name, address, city, country, cover_image_url, logo_url, subtitle, kind, is_open, is_active, latitude, longitude)
values
  (
    'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11',
    'Aviva Stadium',
    'Lansdowne Rd, Dublin 4',
    'Dublin',
    'Ireland',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/f/f8/Aviva_Stadium%28Dublin_Arena%29.JPG/1280px-Aviva_Stadium%28Dublin_Arena%29.JPG',
    null,
    'Skip the queue at the bar',
    'venue', true, true, 53.3352, -6.2285
  ),
  (
    '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c01',
    'Fairyhouse Racecourse',
    'Ratoath, Co. Meath',
    'Ratoath',
    'Ireland',
    'https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Horse_Racing_at_Fairyhouse.jpg/1280px-Horse_Racing_at_Fairyhouse.jpg',
    null,
    'Race days',
    'venue', false, true, 53.5214, -6.5465
  ),
  (
    '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c02',
    'Laya Arena (RDS)',
    'Ballsbridge, Dublin 4',
    'Dublin',
    'Ireland',
    null,
    null,
    'Concerts and events',
    'venue', false, true, 53.3263, -6.2290
  ),
  (
    '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c11',
    'Hypergoat Coffee - Swords',
    'Swords, Co. Dublin',
    'Swords',
    'Ireland',
    null, null,
    'Specialty coffee',
    'cafe', false, true, 53.4597, -6.2181
  ),
  (
    '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c12',
    'Hypergoat Coffee - The Liberties',
    'The Liberties, Dublin 8',
    'Dublin',
    'Ireland',
    null, null,
    'Specialty coffee',
    'cafe', false, true, 53.3425, -6.2790
  ),
  (
    '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c13',
    'Morton''s - Collection',
    'Dublin 6',
    'Dublin',
    'Ireland',
    null, null,
    'Click and collect',
    'cafe', false, true, 53.3260, -6.2560
  ),
  (
    '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c14',
    'Guys - Guys Blackrock',
    'Blackrock, Co. Dublin',
    'Blackrock',
    'Ireland',
    null, null,
    'Coffee and bakes',
    'cafe', false, true, 53.3015, -6.1780
  )
on conflict (id) do update set
  name = excluded.name,
  address = excluded.address,
  city = excluded.city,
  country = excluded.country,
  cover_image_url = excluded.cover_image_url,
  logo_url = excluded.logo_url,
  subtitle = excluded.subtitle,
  kind = excluded.kind,
  is_open = excluded.is_open,
  is_active = excluded.is_active,
  latitude = excluded.latitude,
  longitude = excluded.longitude;
