# Supabase Setup

## Local development

1. Start local stack:
   - `supabase start`
2. Apply migrations (demo data is in the migrations):
   - `supabase db reset`
3. Serve edge functions:
   - `supabase functions serve --env-file ../.env`

## Deploy to hosted Supabase

1. Link project:
   - `supabase link --project-ref <project-ref>`
2. Push schema:
   - `supabase db push`
3. Set function secrets (the service role key is injected automatically):
   - `supabase secrets set STRIPE_SECRET_KEY=... STRIPE_WEBHOOK_SECRET=...`
4. Deploy functions:
   - `supabase functions deploy create-order create-checkout-session stripe-webhook checkout-return delete-account`
