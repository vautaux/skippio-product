import { adminClient, authenticate, json, preflight } from "../_shared/http.ts";
import { sendDineInConfirmation } from "../_shared/mail.ts";

type OrderLineRequest = {
  menu_item_id?: string;
  quantity?: number;
  option_ids?: string[];
};

type CreateOrderRequest = {
  venue_id?: string;
  collection_point_id?: string;
  ordered_for_halftime?: boolean;
  /** ISO timestamp for pickup / dine-in reservation; omit for ASAP takeout. */
  pickup_at?: string | null;
  promo_code?: string | null;
  fulfillment_type?: "collection" | "takeout" | "dine_in" | "seat_delivery";
  payment_mode?: "stripe" | "at_venue";
  party_size?: number | null;
  seat_row?: string | null;
  seat_number?: string | null;
  /** Price the basket (promo included) without creating an order. */
  preview?: boolean;
  items?: OrderLineRequest[];
};

const SERVICE_FEE_BPS = 750; // 7.5%
const MAX_QTY_PER_ITEM = 20;
const MAX_DISTINCT_LINES = 40;
const MIN_PICKUP_LEAD_MS = 5 * 60 * 1000;
const MAX_PICKUP_LEAD_MS = 24 * 60 * 60 * 1000;
const MIN_RESERVATION_LEAD_MS = 30 * 60 * 1000;
const MAX_RESERVATION_LEAD_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_AT_VENUE_ORDERS_PER_DAY = 5;

const ORDER_COLUMNS =
  "id, status, subtotal_cents, discount_cents, service_fee_cents, total_cents, currency, venue_id, collection_point_id, pickup_at, fulfillment_type, payment_mode, party_size, seat_row, seat_number";

class Rejection extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

type Admin = ReturnType<typeof adminClient>;

type PricedLine = {
  menu_item_id: string;
  title_snapshot: string;
  unit_price_cents: number;
  quantity: number;
  options_snapshot: { group: string; title: string; price_delta_cents: number }[];
};

type Pricing = {
  lines: PricedLine[];
  currency: string;
  subtotal: number;
  discount: number;
  serviceFee: number;
  total: number;
  promoId: string | null;
  promoCode: string | null;
};

/** Validates the basket against the database and works out every amount server-side. */
async function priceBasket(admin: Admin, body: CreateOrderRequest, venueId: string): Promise<Pricing> {
  if (!Array.isArray(body.items) || !body.items.length) throw new Rejection(400, "Your basket is empty.");

  // Merge identical lines (same item and same options) and validate quantities.
  const wanted = new Map<string, { itemId: string; optionIds: string[]; quantity: number }>();
  for (const line of body.items) {
    if (!line.menu_item_id) throw new Rejection(400, "Invalid item");
    const qty = line.quantity;
    if (!Number.isInteger(qty) || (qty as number) < 1) throw new Rejection(400, "Invalid quantity");
    // iOS sends upper-case UUIDs; the database returns lower-case ones. Compare in one form.
    const itemId = line.menu_item_id.toLowerCase();
    const optionIds = [...new Set((line.option_ids ?? []).map((id) => String(id).toLowerCase()))].sort();
    const key = `${itemId}|${optionIds.join(",")}`;
    const existing = wanted.get(key);
    if (existing) existing.quantity += qty as number;
    else wanted.set(key, { itemId, optionIds, quantity: qty as number });
  }
  if (wanted.size > MAX_DISTINCT_LINES) throw new Rejection(400, "Too many different items.");

  const perItem = new Map<string, number>();
  for (const line of wanted.values()) {
    perItem.set(line.itemId, (perItem.get(line.itemId) ?? 0) + line.quantity);
  }
  for (const qty of perItem.values()) {
    if (qty > MAX_QTY_PER_ITEM) throw new Rejection(400, `You can order at most ${MAX_QTY_PER_ITEM} of one item.`);
  }

  // Prices always come from the database, never from the client.
  const itemIds = [...perItem.keys()];
  const { data: menuItems, error: menuError } = await admin
    .from("menu_items")
    .select("id, venue_id, title, price_cents, currency, is_available")
    .in("id", itemIds);

  if (menuError || !menuItems || menuItems.length !== itemIds.length) {
    throw new Rejection(400, "Some items in your basket no longer exist.");
  }
  if (menuItems.some((item) => item.venue_id !== venueId)) {
    throw new Rejection(400, "Items must all come from the same venue.");
  }
  const unavailable = menuItems.filter((item) => !item.is_available);
  if (unavailable.length) {
    throw new Rejection(409, `${unavailable.map((item) => item.title).join(", ")} is no longer available.`);
  }
  if (new Set(menuItems.map((item) => item.currency)).size !== 1) {
    throw new Rejection(400, "Mixed currencies are not supported.");
  }
  const itemById = new Map(menuItems.map((item) => [item.id, item]));

  // Options: each must belong to a group linked to its item.
  const allOptionIds = [...new Set([...wanted.values()].flatMap((line) => line.optionIds))];
  const { data: links } = await admin
    .from("menu_item_option_groups")
    .select("menu_item_id, group_id")
    .in("menu_item_id", itemIds);
  const groupIds = [...new Set((links ?? []).map((link) => link.group_id))];

  const groups = new Map<string, { id: string; title: string; is_required: boolean; allows_multiple: boolean }>();
  if (groupIds.length) {
    const { data: groupRows } = await admin
      .from("menu_option_groups")
      .select("id, title, is_required, allows_multiple")
      .in("id", groupIds);
    for (const group of groupRows ?? []) groups.set(group.id, group);
  }

  const options = new Map<string, { id: string; group_id: string; title: string; price_delta_cents: number }>();
  if (allOptionIds.length) {
    const { data: optionRows } = await admin
      .from("menu_options")
      .select("id, group_id, title, price_delta_cents")
      .in("id", allOptionIds);
    for (const option of optionRows ?? []) options.set(option.id, option);
    if (options.size !== allOptionIds.length) throw new Rejection(400, "Some options are no longer available.");
  }

  let subtotal = 0;
  const lines: PricedLine[] = [];
  for (const line of wanted.values()) {
    const item = itemById.get(line.itemId)!;
    const itemGroups = (links ?? []).filter((link) => link.menu_item_id === item.id).map((link) => link.group_id);

    const picked = new Map<string, number>(); // group id -> selections
    let delta = 0;
    const snapshot: PricedLine["options_snapshot"] = [];
    for (const optionId of line.optionIds) {
      const option = options.get(optionId)!;
      if (!itemGroups.includes(option.group_id)) {
        throw new Rejection(400, `${option.title} is not available for ${item.title}.`);
      }
      const group = groups.get(option.group_id)!;
      picked.set(group.id, (picked.get(group.id) ?? 0) + 1);
      delta += option.price_delta_cents;
      snapshot.push({ group: group.title, title: option.title, price_delta_cents: option.price_delta_cents });
    }
    for (const groupId of itemGroups) {
      const group = groups.get(groupId);
      if (!group) continue;
      const count = picked.get(groupId) ?? 0;
      if (group.is_required && count < 1) throw new Rejection(400, `Please choose a ${group.title.toLowerCase()} for ${item.title}.`);
      if (!group.allows_multiple && count > 1) throw new Rejection(400, `Choose only one ${group.title.toLowerCase()} for ${item.title}.`);
    }

    const unit = item.price_cents + delta;
    subtotal += unit * line.quantity;
    lines.push({
      menu_item_id: item.id,
      title_snapshot: item.title,
      unit_price_cents: unit,
      quantity: line.quantity,
      options_snapshot: snapshot,
    });
  }

  // Promo code.
  let discount = 0;
  let promoId: string | null = null;
  let promoCode: string | null = null;
  const code = body.promo_code?.trim().toUpperCase();
  if (code) {
    const { data: promo } = await admin
      .from("promo_codes")
      .select("id, code, discount_type, discount_value, max_redemptions, starts_at, ends_at, is_active")
      .eq("code", code)
      .maybeSingle();
    const now = Date.now();
    const valid = promo && promo.is_active &&
      (!promo.starts_at || new Date(promo.starts_at).getTime() <= now) &&
      (!promo.ends_at || new Date(promo.ends_at).getTime() >= now);
    if (!valid) throw new Rejection(400, "That promo code isn't valid.");

    if (promo.max_redemptions != null) {
      const { count } = await admin
        .from("orders")
        .select("id", { count: "exact", head: true })
        .eq("promo_code_id", promo.id)
        .neq("status", "cancelled");
      if ((count ?? 0) >= promo.max_redemptions) throw new Rejection(400, "That promo code has been fully used.");
    }

    const raw = promo.discount_type === "percentage"
      ? Math.round((subtotal * Number(promo.discount_value)) / 100)
      : Math.round(Number(promo.discount_value) * 100);
    discount = Math.min(raw, subtotal);
    promoId = promo.id;
    promoCode = promo.code;
  }

  // The service fee is charged on what the customer actually pays for the food and drink.
  const net = subtotal - discount;
  const serviceFee = Math.round((net * SERVICE_FEE_BPS) / 10000);
  return {
    lines,
    currency: menuItems[0].currency || "EUR",
    subtotal,
    discount,
    serviceFee,
    total: net + serviceFee,
    promoId,
    promoCode,
  };
}

Deno.serve(async (req) => {
  const early = preflight(req);
  if (early) return early;
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  let admin: Admin;
  try {
    admin = adminClient();
  } catch {
    return json(500, { error: "Server misconfigured" });
  }

  const user = await authenticate(req, admin);
  if (!user) return json(401, { error: "Please sign in again." });

  let body: CreateOrderRequest;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "Invalid JSON" });
  }

  const idempotencyKey = req.headers.get("idempotency-key")?.trim();
  if (!body.preview && (!idempotencyKey || idempotencyKey.length > 100)) {
    return json(400, { error: "Missing idempotency-key header" });
  }

  if (!body.venue_id || !Array.isArray(body.items) || !body.items.length) {
    return json(400, { error: "Your basket is empty." });
  }
  if (!body.preview && !body.collection_point_id) {
    return json(400, { error: "Choose where to collect your order." });
  }

  // A retried request returns the original order instead of creating a duplicate.
  const findExisting = () =>
    admin.from("orders").select(ORDER_COLUMNS).eq("idempotency_key", idempotencyKey!)
      .eq("user_id", user.id).maybeSingle();

  try {
    if (!body.preview) {
      const { data: existing } = await findExisting();
      if (existing) return json(200, existing);
    }

    // The venue must be open and the collection point must belong to it.
    const { data: venue } = await admin
      .from("venues").select("id, name, is_active, is_open, kind").eq("id", body.venue_id).maybeSingle();
    if (!venue || !venue.is_active) throw new Rejection(400, "This venue is not available.");
    if (!venue.is_open && !body.preview) throw new Rejection(400, "This venue is closed right now.");

    const fulfillment = body.fulfillment_type ?? "collection";
    if (!["collection", "takeout", "dine_in", "seat_delivery"].includes(fulfillment)) {
      throw new Rejection(400, "Invalid fulfillment type.");
    }
    const paymentMode = body.payment_mode ?? "stripe";
    if (!["stripe", "at_venue"].includes(paymentMode)) {
      throw new Rejection(400, "Invalid payment mode.");
    }
    if (paymentMode === "at_venue" && fulfillment !== "dine_in") {
      throw new Rejection(400, "Pay at restaurant is only available for dine-in.");
    }
    if (fulfillment === "seat_delivery" && venue.kind !== "venue") {
      throw new Rejection(400, "Seat delivery is only available at stadiums.");
    }

    let partySize: number | null = null;
    let seatRow: string | null = null;
    let seatNumber: string | null = null;
    if (fulfillment === "dine_in") {
      const size = body.party_size;
      if (!Number.isInteger(size) || (size as number) < 1 || (size as number) > 20) {
        throw new Rejection(400, "Please choose a party size between 1 and 20.");
      }
      partySize = size as number;
      if (!body.pickup_at) {
        throw new Rejection(400, "Please choose a reservation time.");
      }
    }
    if (fulfillment === "seat_delivery") {
      const row = typeof body.seat_row === "string" ? body.seat_row.trim() : "";
      const seat = typeof body.seat_number === "string" ? body.seat_number.trim() : "";
      if (!row || !seat) {
        throw new Rejection(400, "Please enter your row and seat number.");
      }
      if (row.length > 32 || seat.length > 32) {
        throw new Rejection(400, "Row or seat is too long.");
      }
      seatRow = row;
      seatNumber = seat;
    }

    let pickupAt: string | null = null;
    if (body.pickup_at) {
      const when = new Date(body.pickup_at).getTime();
      const now = Date.now();
      if (Number.isNaN(when)) throw new Rejection(400, "Invalid time.");
      if (fulfillment === "dine_in") {
        if (when < now + MIN_RESERVATION_LEAD_MS || when > now + MAX_RESERVATION_LEAD_MS) {
          throw new Rejection(400, "Please pick a reservation between 30 minutes and 7 days from now.");
        }
      } else if (when < now + MIN_PICKUP_LEAD_MS || when > now + MAX_PICKUP_LEAD_MS) {
        throw new Rejection(400, "Please pick a collection time between 5 minutes and 24 hours from now.");
      }
      pickupAt = new Date(when).toISOString();
    }

    const pricing = await priceBasket(admin, body, venue.id);

    if (body.preview) {
      return json(200, {
        subtotal_cents: pricing.subtotal,
        discount_cents: pricing.discount,
        service_fee_cents: pricing.serviceFee,
        total_cents: pricing.total,
        currency: pricing.currency,
        promo_code: pricing.promoCode,
      });
    }

    const { data: collectionPoint } = await admin
      .from("collection_points").select("id, venue_id, is_open")
      .eq("id", body.collection_point_id!).maybeSingle();
    if (!collectionPoint || collectionPoint.venue_id !== venue.id || !collectionPoint.is_open) {
      throw new Rejection(400, "That collection point is not available.");
    }

    if (paymentMode === "at_venue") {
      const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
      const { count, error: capError } = await admin
        .from("orders")
        .select("id", { count: "exact", head: true })
        .eq("user_id", user.id)
        .eq("payment_mode", "at_venue")
        .neq("status", "cancelled")
        .gte("created_at", since);
      if (capError) {
        console.error("at_venue cap check failed", capError);
        throw new Rejection(500, "We could not create your order. Please try again.");
      }
      if ((count ?? 0) >= MAX_AT_VENUE_ORDERS_PER_DAY) {
        throw new Rejection(429, "You can reserve at most 5 pay-at-restaurant tables per day.");
      }
    }

    const initialStatus = paymentMode === "at_venue" ? "paid" : "pending_payment";

    const { data: order, error: orderError } = await admin
      .from("orders")
      .insert({
        user_id: user.id,
        venue_id: venue.id,
        collection_point_id: collectionPoint.id,
        status: initialStatus,
        ordered_for_halftime: body.ordered_for_halftime === true,
        pickup_at: pickupAt,
        fulfillment_type: fulfillment,
        payment_mode: paymentMode,
        party_size: partySize,
        seat_row: seatRow,
        seat_number: seatNumber,
        subtotal_cents: pricing.subtotal,
        service_fee_cents: pricing.serviceFee,
        discount_cents: pricing.discount,
        total_cents: pricing.total,
        currency: pricing.currency,
        promo_code_id: pricing.promoId,
        idempotency_key: idempotencyKey,
      })
      .select(ORDER_COLUMNS)
      .single();

    if (orderError || !order) {
      // Two simultaneous requests with the same key: the loser reads the winner's order.
      if (orderError?.code === "23505") {
        const { data: raced } = await findExisting();
        if (raced) return json(200, raced);
      }
      console.error("create-order insert failed", orderError);
      return json(500, { error: "We could not create your order. Please try again." });
    }

    const { error: lineError } = await admin
      .from("order_items")
      .insert(pricing.lines.map((line) => ({ ...line, order_id: order.id })));

    if (lineError) {
      console.error("create-order items failed", lineError);
      await admin.from("orders").delete().eq("id", order.id); // don't leave a half-built order
      return json(500, { error: "We could not create your order. Please try again." });
    }

    await admin.from("order_status_events").insert({
      order_id: order.id,
      status: initialStatus,
      note: paymentMode === "at_venue"
        ? "Dine-in reserved — pay at restaurant"
        : "Order created",
    });

    // Pay at restaurant: email now. Pay now (Stripe): email after webhook marks paid.
    if (fulfillment === "dine_in" && paymentMode === "at_venue" && user.email) {
      try {
        await sendDineInConfirmation({
          to: user.email,
          venueName: venue.name,
          partySize,
          pickupAt,
          totalCents: pricing.total,
          currency: pricing.currency,
          payAtVenue: true,
        });
      } catch (mailErr) {
        console.error("dine-in confirmation email failed", mailErr);
      }
    }

    return json(201, order);
  } catch (error) {
    if (error instanceof Rejection) return json(error.status, { error: error.message });
    console.error("create-order failed", error);
    return json(500, { error: "We could not create your order. Please try again." });
  }
});
