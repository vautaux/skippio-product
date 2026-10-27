# Skippio Fan App (Supabase)

Production-focused foundation for a Skippio-style fan ordering app:
- Native iOS app shell in SwiftUI
- Supabase as backend (Postgres, Auth, Realtime, Edge Functions)
- Real payment-ready flow scaffolding via Stripe

## Repository Structure

- `ios/SkippioFan`: Native iOS project scaffold (SwiftUI + supabase-swift)
- `supabase/migrations`: SQL schema and RLS policies
- `supabase/functions`: Edge Functions for order and payment flow

## Prerequisites

- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate `.xcodeproj`)
- [Supabase CLI](https://supabase.com/docs/guides/cli)
- Stripe account (live/sandbox keys)

## Setup

1. Copy env values:
   - `cp .env.example .env`
   - Fill all Supabase and Stripe keys.
2. Link Supabase project (or start local stack):
   - `supabase login`
   - `supabase link --project-ref <your-project-ref>`
3. Apply DB schema:
   - `supabase db push`
4. Set function secrets (names can't start with `SUPABASE_`; the service role key is injected automatically):
   - `supabase secrets set STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=...`
5. Deploy edge functions:
   - `supabase functions deploy create-order create-checkout-session stripe-webhook checkout-return delete-account`
   - `stripe-webhook` and `checkout-return` are public (`verify_jwt = false` in `supabase/config.toml`).
6. In Stripe (sandbox), add a webhook destination pointing at
   `https://<project-ref>.supabase.co/functions/v1/stripe-webhook` listening for
   `checkout.session.completed` (and ideally `checkout.session.expired`, `payment_intent.succeeded`).
   Its signing secret is `STRIPE_WEBHOOK_SECRET`.
7. Generate iOS project:
   - `cd ios/SkippioFan && xcodegen generate`
8. Copy the iOS config templates and fill in the project URL and anon key:
   - `cp Config/Debug.xcconfig.example Config/Debug.xcconfig`
   - `cp Config/Release.xcconfig.example Config/Release.xcconfig`
   - Run both commands from `ios/SkippioFan`. The filled files are gitignored.

## How payment works

1. The app calls `create-order` (idempotent). The server prices the basket from the database
   and returns the order.
2. The app calls `create-checkout-session`, which returns a Stripe Checkout URL. The app opens it
   in a secure browser sheet; card details never touch the app or our servers.
3. Stripe redirects to `checkout-return`, which bounces back into the app (`skippiodemo://`).
4. **Only the `stripe-webhook` function marks an order paid**, after verifying Stripe's signature
   and that the amount matches. The app polls the order until it flips.

## Testing

Both scripts need `.env` and talk to the real project (Stripe in test mode). They create a
throwaway user and delete it afterwards.

- `set -a; source .env; set +a; python3 scripts/e2e_backend.py`: catalog, orders at two venues,
  item options, unavailable items, pickup time, promo codes through Stripe, webhook, favourites,
  RLS and account deletion.
- `scripts/run-ui-tests.sh`: signs in and walks the app on a simulator: a café basket and a venue
  basket kept separate, promo code, payment settled with a signed test webhook, screenshots in
  `/tmp/shots`.

## Notes

- `.env` is git-ignored intentionally; never commit secrets.
- Sign-up is email + password. Confirmation is a 6-digit code emailed through Gmail SMTP
  (`scripts/configure_auth_email.py`, uses `GMAIL_ADDRESS` and `GOOGLE_APP_PASSWORD` from `.env`).
  Gmail allows roughly 500 emails a day and shows your own address as the sender; use a
  transactional provider (Resend, Postmark, SES) on your own domain before launch.
- Demo venues, cafés and menus are generated: `supabase/catalog/catalog.json` is the source of
  truth and `scripts/build_catalog.py` turns it into `supabase/migrations/20261026140000_catalog.sql`.
  Invented demo content: all café names, every menu item that was not visible in the reference
  screenshots (other coffees, iced drinks, sandwiches, the sixth pastry), prices, options and
  the promo codes `SKIP10` (10% off) and `WELCOME2` (2.00 off).
- Photos come from Wikimedia Commons (CC0, public domain, CC BY, CC BY-SA only). They are copied
  to the public Storage bucket `catalog`, and author and licence are in the `image_credits` table,
  shown in the app under Profile > Image credits. Many are generic stand-ins rather than the exact
  product. Refresh with `scripts/commons_search.py`, `scripts/contact_sheet.py` (review) and
  `scripts/build_catalog.py --images --upload --sql`.
- Each café or venue has its own basket (kept per user on the device). Paying clears only that one.
- Typeface: Source Sans 3 (SIL OFL), bundled in `ios/SkippioFan/SkippioFan/Resources/Fonts`.