import { adminClient, authenticate, json, preflight } from "../_shared/http.ts";

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

  let body: { order_id?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "Invalid JSON" });
  }
  if (!body.order_id) return json(400, { error: "Missing order_id" });

  const { data: order, error } = await admin
    .from("orders")
    .select("id, user_id, status")
    .eq("id", body.order_id)
    .maybeSingle();

  if (error || !order) return json(404, { error: "Order not found." });
  if (order.user_id !== user.id) return json(403, { error: "That isn't your order." });
  if (!["paid", "preparing", "ready"].includes(order.status)) {
    return json(400, { error: "Only active orders can be marked collected." });
  }

  const { data: updated, error: upErr } = await admin
    .from("orders")
    .update({ status: "collected" })
    .eq("id", order.id)
    .eq("user_id", user.id)
    .select("id, status")
    .single();

  if (upErr || !updated) {
    console.error("mark-collected failed", upErr);
    return json(500, { error: "Could not update the order." });
  }

  await admin.from("order_status_events").insert({
    order_id: order.id,
    status: "collected",
    note: "Collected by customer",
  });

  return json(200, updated);
});
