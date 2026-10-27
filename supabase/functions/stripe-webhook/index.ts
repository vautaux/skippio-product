import { adminClient } from "../_shared/http.ts";
import { sendDineInConfirmation } from "../_shared/mail.ts";

// Stripe retries for up to 3 days, so reject anything outside this window to stop replays.
const TOLERANCE_SECONDS = 5 * 60;

const encoder = new TextEncoder();

function toHex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Implements Stripe's documented scheme: HMAC-SHA256 over `${timestamp}.${rawBody}`. */
async function verifySignature(payload: string, header: string, secret: string): Promise<boolean> {
  let timestamp = "";
  const signatures: string[] = [];
  for (const part of header.split(",")) {
    const [key, value] = part.split("=");
    if (key === "t") timestamp = value;
    if (key === "v1" && value) signatures.push(value);
  }
  if (!timestamp || !signatures.length) return false;

  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(age) || age > TOLERANCE_SECONDS) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`)));
  return signatures.some((candidate) => safeEqual(candidate, expected));
}

// deno-lint-ignore no-explicit-any
type StripeObject = Record<string, any>;

async function markPaid(
  admin: ReturnType<typeof adminClient>,
  orderId: string,
  paymentIntentId: string | null,
  amountPaid: number | null,
  note: string,
) {
  const { data: order, error } = await admin
    .from("orders")
    .select(
      "id, status, total_cents, currency, fulfillment_type, payment_mode, party_size, pickup_at, user_id, venues(name)",
    )
    .eq("id", orderId)
    .maybeSingle();
  if (error) throw error;
  if (!order) {
    console.warn("Webhook for unknown order", orderId);
    return;
  }
  if (order.status !== "pending_payment") return; // already handled; Stripe delivers more than once

  // Never trust a payment that doesn't match what we asked for.
  if (amountPaid !== null && amountPaid !== order.total_cents) {
    console.error("Amount mismatch", { orderId, amountPaid, expected: order.total_cents });
    await admin.from("order_status_events").insert({
      order_id: order.id,
      status: "pending_payment",
      note: `Payment of ${amountPaid} did not match order total ${order.total_cents}; needs review`,
    });
    return;
  }

  // The status guard makes this a no-op if another delivery got here first.
  const { data: updated, error: updateError } = await admin
    .from("orders")
    .update({ status: "paid", payment_intent_id: paymentIntentId })
    .eq("id", order.id)
    .eq("status", "pending_payment")
    .select("id");
  if (updateError) throw updateError;

  if (updated?.length) {
    await admin.from("order_status_events").insert({ order_id: order.id, status: "paid", note });

    // Dine-in + Pay now: confirmation email only after Stripe settles.
    if (order.fulfillment_type === "dine_in") {
      try {
        const { data: authUser } = await admin.auth.admin.getUserById(order.user_id);
        const email = authUser.user?.email;
        const venueName = (order.venues as { name?: string } | null)?.name ?? "the restaurant";
        if (email) {
          await sendDineInConfirmation({
            to: email,
            venueName,
            partySize: order.party_size,
            pickupAt: order.pickup_at,
            totalCents: order.total_cents,
            currency: order.currency ?? "EUR",
            payAtVenue: false,
          });
        }
      } catch (mailErr) {
        console.error("dine-in confirmation email after payment failed", mailErr);
      }
    }
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) {
    console.error("STRIPE_WEBHOOK_SECRET is not set");
    return new Response("Server misconfigured", { status: 500 });
  }

  const signature = req.headers.get("stripe-signature");
  const payload = await req.text(); // must be the raw body for the signature to match
  if (!signature || !(await verifySignature(payload, signature, secret))) {
    return new Response("Invalid signature", { status: 400 });
  }

  let event: { type: string; data: { object: StripeObject } };
  try {
    event = JSON.parse(payload);
  } catch {
    return new Response("Invalid payload", { status: 400 });
  }

  const object = event.data.object;
  const admin = adminClient();

  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        const orderId = object.metadata?.order_id ?? object.client_reference_id;
        if (orderId && object.payment_status === "paid") {
          await markPaid(
            admin,
            orderId,
            typeof object.payment_intent === "string" ? object.payment_intent : null,
            object.amount_total ?? null,
            "Payment successful",
          );
        }
        break;
      }
      case "payment_intent.succeeded": {
        const orderId = object.metadata?.order_id;
        if (orderId) {
          await markPaid(admin, orderId, object.id, object.amount_received ?? null, "Payment successful");
        }
        break;
      }
      case "checkout.session.expired": {
        const orderId = object.metadata?.order_id ?? object.client_reference_id;
        if (orderId) {
          // Only cancel if this is still the session attached to the order.
          const { data: cancelled } = await admin
            .from("orders")
            .update({ status: "cancelled" })
            .eq("id", orderId)
            .eq("status", "pending_payment")
            .eq("checkout_session_id", object.id)
            .select("id");
          if (cancelled?.length) {
            await admin.from("order_status_events").insert({
              order_id: orderId,
              status: "cancelled",
              note: "Checkout expired before payment",
            });
          }
        }
        break;
      }
      case "payment_intent.payment_failed": {
        const orderId = object.metadata?.order_id;
        if (orderId) {
          await admin.from("order_status_events").insert({
            order_id: orderId,
            status: "pending_payment",
            note: `Payment failed: ${object.last_payment_error?.message ?? "unknown reason"}`,
          });
        }
        break;
      }
      default:
        break; // Acknowledge events we don't act on so Stripe stops retrying them.
    }
  } catch (error) {
    // A non-2xx makes Stripe retry later, which is what we want for transient DB errors.
    console.error("Webhook handling failed", event.type, error);
    return new Response("Handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
