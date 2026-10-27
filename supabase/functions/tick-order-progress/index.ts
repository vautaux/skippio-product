import { adminClient, authenticate, json, preflight } from "../_shared/http.ts";

/**
 * Demo kitchen clock: advances the caller's paid/preparing orders toward "ready"
 * over 5–10 minutes (deterministic per order id). The Orders screen and Live
 * Activity call this while polling so status moves without a staff tablet.
 */

function readyAfterMs(orderId: string): number {
  // Stable 5–10 minutes from the order id so every device agrees.
  let hash = 0;
  for (let i = 0; i < orderId.length; i++) hash = (hash * 31 + orderId.charCodeAt(i)) >>> 0;
  const minutes = 5 + (hash % 6); // 5..10
  return minutes * 60 * 1000;
}

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

  const { data: orders, error } = await admin
    .from("orders")
    .select("id, status, created_at, fulfillment_type")
    .eq("user_id", user.id)
    .in("status", ["paid", "preparing"]);

  if (error) return json(500, { error: "Could not load orders." });

  const now = Date.now();
  const updates: { id: string; status: string; estimated_ready_at: string }[] = [];

  for (const order of orders ?? []) {
    const created = new Date(order.created_at).getTime();
    const readyIn = readyAfterMs(order.id);
    const readyAt = new Date(created + readyIn).toISOString();
    const age = now - created;

    let next: string | null = null;
    if (age >= readyIn && order.status !== "ready") {
      next = "ready";
    } else if (age >= 45_000 && order.status === "paid") {
      next = "preparing";
    }

    if (next) {
      const { error: upErr } = await admin
        .from("orders")
        .update({ status: next })
        .eq("id", order.id)
        .eq("user_id", user.id);
      if (!upErr) {
        const readyNote = order.fulfillment_type === "seat_delivery"
          ? "Ready for seat delivery"
          : "Ready for collection";
        await admin.from("order_status_events").insert({
          order_id: order.id,
          status: next,
          note: next === "ready" ? readyNote : "Kitchen started preparing",
        });
        updates.push({ id: order.id, status: next, estimated_ready_at: readyAt });
      }
    } else {
      updates.push({ id: order.id, status: order.status, estimated_ready_at: readyAt });
    }
  }

  return json(200, { updates });
});
