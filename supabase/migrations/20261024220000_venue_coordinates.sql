-- Coordinates refined from OpenStreetMap (Nominatim) lookups.
--   Exact:       Aviva Stadium, Fairyhouse Racecourse, RDS (Laya Arena), Morton's (Ranelagh match)
--   Town centre: Hypergoat Swords (café itself not in OSM)
--   Unchanged:   Hypergoat The Liberties, Guys Blackrock (not found in OSM; approximate)
update public.venues set latitude = 53.3352254, longitude = -6.2281851
  where id = 'd9d44e67-c936-4f45-8ec5-cfc0fd22cd11'; -- Aviva Stadium
update public.venues set latitude = 53.4845356, longitude = -6.4736322
  where id = '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c01'; -- Fairyhouse
update public.venues set latitude = 53.3266541, longitude = -6.2288627
  where id = '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c02'; -- Laya Arena (RDS)
update public.venues set latitude = 53.4558215, longitude = -6.2217846
  where id = '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c11'; -- Hypergoat Swords (town centre)
update public.venues set latitude = 53.3210685, longitude = -6.2562581
  where id = '6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c13'; -- Morton's
