import { adminClient, authenticate, json, preflight } from "../_shared/http.ts";
import { sendDineInConfirmation } from "../_shared/mail.ts";

const MIN_RESERVATION_LEAD_MS = 30 * 60 * 1000;
const MAX_RESERVATION_LEAD_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_RESERVATION_EDITS_PER_HOUR = 5;

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  let admin;
  try {
    admin = adminClient();
  } catch {
    return json(500, { error: "Server misconfigured" });
  }

  const user = await authenticate(req, admin);
  if (!user) return json(401, { error: "Please sign in again." });

  let body: { order_id?: string; party_size?: number; pickup_at?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "Invalid JSON" });
  }

  if (!body.order_id) return json(400, { error: "Missing order_id" });
  const partySize = body.party_size;
  if (!Number.isInteger(partySize) || (partySize as number) < 1 || (partySize as number) > 20) {
    return json(400, { error: "Please choose a party size between 1 and 20." });
  }
  if (!body.pickup_at) return json(400, { error: "Please choose a reservation time." });

  const when = new Date(body.pickup_at).getTime();
  const now = Date.now();
  if (Number.isNaN(when)) return json(400, { error: "Invalid time." });
  if (when < now + MIN_RESERVATION_LEAD_MS || when > now + MAX_RESERVATION_LEAD_MS) {
    return json(400, { error: "Please pick a reservation between 30 minutes and 7 days from now." });
  }
  const pickupAt = new Date(when).toISOString();

  const { data: order, error } = await admin
    .from("orders")
    .select(
      "id, user_id, status, fulfillment_type, payment_mode, party_size, pickup_at, total_cents, currency, venues(name)",
    )
    .eq("id", body.order_id)
    .maybeSingle();

  if (error || !order) return json(404, { error: "Order not found." });
  if (order.user_id !== user.id) return json(403, { error: "That isn't your order." });
  if (order.fulfillment_type !== "dine_in") {
    return json(400, { error: "Only dine-in reservations can be modified." });
  }
  if (!["paid", "preparing", "ready"].includes(order.status)) {
    return json(400, { error: "This reservation can no longer be changed." });
  }

  const sameParty = order.party_size === partySize;
  const sameTime = order.pickup_at != null && new Date(order.pickup_at).getTime() === when;
  if (sameParty && sameTime) {
    return json(200, {
      id: order.id,
      party_size: order.party_size,
      pickup_at: order.pickup_at,
      status: order.status,
    });
  }

  const since = new Date(now - 60 * 60 * 1000).toISOString();
  const { count, error: capError } = await admin
    .from("order_status_events")
    .select("id, orders!inner(user_id)", { count: "exact", head: true })
    .eq("orders.user_id", user.id)
    .gte("created_at", since)
    .like("note", "Reservation updated%");
  if (capError) {
    console.error("reservation edit cap check failed", capError);
    return json(500, { error: "Could not update the reservation." });
  }
  if ((count ?? 0) >= MAX_RESERVATION_EDITS_PER_HOUR) {
    return json(429, { error: "You can change a reservation 5 times per hour." });
  }

  const { data: updated, error: upErr } = await admin
    .from("orders")
    .update({ party_size: partySize, pickup_at: pickupAt })
    .eq("id", order.id)
    .eq("user_id", user.id)
    .select("id, party_size, pickup_at, status")
    .single();

  if (upErr || !updated) {
    console.error("modify-reservation failed", upErr);
    return json(500, { error: "Could not update the reservation." });
  }

  await admin.from("order_status_events").insert({
    order_id: order.id,
    status: order.status,
    note: `Reservation updated — ${partySize} guests at ${pickupAt}`,
  });

  if (user.email) {
    try {
      const venueName = (order.venues as { name?: string } | null)?.name ?? "the restaurant";
      await sendDineInConfirmation({
        to: user.email,
        venueName,
        partySize: partySize as number,
        pickupAt,
        totalCents: order.total_cents,
        currency: order.currency ?? "EUR",
        payAtVenue: order.payment_mode === "at_venue",
        updated: true,
      });
    } catch (mailErr) {
      console.error("modify-reservation email failed", mailErr);
    }
  }

  return json(200, updated);
});
