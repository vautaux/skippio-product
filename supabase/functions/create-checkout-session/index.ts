import { adminClient, authenticate, json, preflight } from "../_shared/http.ts";

const STRIPE_API = "https://api.stripe.com/v1";
// Stripe requires Checkout Sessions to live for at least 30 minutes.
const SESSION_TTL_SECONDS = 31 * 60;
// Only a real Checkout Session id may be placed on a Stripe URL.
const CHECKOUT_SESSION_ID = /^cs_(test|live)_[A-Za-z0-9]+$/;

async function stripe(
  secretKey: string,
  method: "GET" | "POST",
  path: string,
  form?: URLSearchParams,
) {
  const response = await fetch(`${STRIPE_API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${secretKey}`,
      ...(form ? { "Content-Type": "application/x-www-form-urlencoded" } : {}),
    },
    body: form,
  });
  const payload = await response.json();
  if (!response.ok) {
    console.error("Stripe error", path, JSON.stringify(payload?.error ?? payload));
    throw new Error(payload?.error?.message ?? "Stripe request failed");
  }
  return payload;
}

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  if (!stripeKey || !supabaseUrl) return json(500, { error: "Server misconfigured" });

  let admin;
  try {
    admin = adminClient();
  } catch {
    return json(500, { error: "Server misconfigured" });
  }

  const user = await authenticate(req, admin);
  if (!user) return json(401, { error: "Please sign in again." });

  let orderId: string | undefined;
  try {
    orderId = (await req.json())?.order_id;
  } catch {
    return json(400, { error: "Invalid JSON" });
  }
  if (!orderId) return json(400, { error: "order_id is required" });

  const { data: order } = await admin
    .from("orders")
    .select("id, status, total_cents, subtotal_cents, service_fee_cents, discount_cents, currency, checkout_session_id")
    .eq("id", orderId)
    .eq("user_id", user.id)
    .maybeSingle();

  if (!order) return json(404, { error: "Order not found" });
  if (order.status !== "pending_payment") {
    return json(200, { order_id: order.id, status: order.status, checkout_url: null });
  }

  try {
    // Reuse a still-open session so retries never produce a second payment page.
    // Ignore anything that is not a Checkout Session id so it cannot change the Stripe path.
    const sessionId = order.checkout_session_id;
    if (typeof sessionId === "string" && CHECKOUT_SESSION_ID.test(sessionId)) {
      const existing = await stripe(stripeKey, "GET", `/checkout/sessions/${sessionId}`);
      if (existing.status === "open" && existing.url) {
        return json(200, { order_id: order.id, status: order.status, checkout_url: existing.url });
      }
      if (existing.status === "complete") {
        // Paid; the webhook is about to flip the order. Don't open a second payment.
        return json(200, { order_id: order.id, status: "processing", checkout_url: null });
      }
    }

    const { data: items } = await admin
      .from("order_items")
      .select("title_snapshot, unit_price_cents, quantity, options_snapshot")
      .eq("order_id", order.id);
    if (!items?.length) return json(409, { error: "This order has no items." });

    const currency = String(order.currency).toLowerCase();
    const form = new URLSearchParams();
    form.set("mode", "payment");
    form.set("client_reference_id", order.id);
    form.set("metadata[order_id]", order.id);
    form.set("payment_intent_data[metadata][order_id]", order.id);
    if (user.email) form.set("customer_email", user.email);
    form.set("expires_at", String(Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS));

    const returnBase = `${supabaseUrl}/functions/v1/checkout-return?order_id=${order.id}`;
    form.set("success_url", `${returnBase}&result=success`);
    form.set("cancel_url", `${returnBase}&result=cancel`);

    let index = 0;
    const addLine = (name: string, unitAmount: number, quantity: number) => {
      form.set(`line_items[${index}][quantity]`, String(quantity));
      form.set(`line_items[${index}][price_data][currency]`, currency);
      form.set(`line_items[${index}][price_data][unit_amount]`, String(unitAmount));
      form.set(`line_items[${index}][price_data][product_data][name]`, name);
      index += 1;
    };

    for (const item of items) {
      const picked = (item.options_snapshot as { title: string }[] | null) ?? [];
      const name = picked.length
        ? `${item.title_snapshot} (${picked.map((option) => option.title).join(", ")})`
        : item.title_snapshot;
      addLine(name, item.unit_price_cents, item.quantity);
    }
    if (order.service_fee_cents > 0) addLine("Service fee", order.service_fee_cents, 1);

    // A promo code becomes a one-off Stripe coupon for exactly the discount we computed.
    if (order.discount_cents > 0) {
      const coupon = new URLSearchParams();
      coupon.set("amount_off", String(order.discount_cents));
      coupon.set("currency", currency);
      coupon.set("duration", "once");
      coupon.set("max_redemptions", "1");
      coupon.set("name", "Promo code");
      coupon.set("metadata[order_id]", order.id);
      const created = await stripe(stripeKey, "POST", "/coupons", coupon);
      form.set("discounts[0][coupon]", created.id);
    }

    const session = await stripe(stripeKey, "POST", "/checkout/sessions", form);

    if (typeof session.id !== "string" || !CHECKOUT_SESSION_ID.test(session.id)) {
      console.error("Stripe returned an unexpected session id");
      return json(500, { error: "Could not prepare payment. Please try again." });
    }

    // Stripe's total must equal ours or the customer would be charged the wrong amount.
    if (session.amount_total !== order.total_cents) {
      console.error("Amount mismatch", session.amount_total, order.total_cents);
      return json(500, { error: "Could not prepare payment. Please try again." });
    }

    const { error: updateError } = await admin
      .from("orders")
      .update({ checkout_session_id: session.id })
      .eq("id", order.id);
    if (updateError) {
      console.error("Could not store checkout session", updateError);
      return json(500, { error: "Could not prepare payment. Please try again." });
    }

    return json(200, { order_id: order.id, status: order.status, checkout_url: session.url });
  } catch (error) {
    console.error("create-checkout-session failed", error);
    return json(502, { error: "Payment provider error. Please try again." });
  }
});
