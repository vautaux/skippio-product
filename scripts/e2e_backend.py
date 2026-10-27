# Backend end-to-end test against the real Supabase project and Stripe test mode.
# Creates a throwaway user, exercises orders/checkout/webhook/favourites/delete-account,
# and removes the user. Run: set -a; source .env; set +a; python3 scripts/e2e_backend.py
import hashlib, hmac, json, os, subprocess, sys, time, uuid

BASE = os.environ["SUPABASE_PROJECT_URL"].rstrip("/")
ANON = os.environ["SUPABASE_ANON_KEY"]
SERVICE = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
WHSEC = os.environ["STRIPE_WEBHOOK_SECRET"]

AVIVA = "d9d44e67-c936-4f45-8ec5-cfc0fd22cd11"
FAIRYHOUSE = "6f0a1b52-3a4e-4b58-9d4e-0a6a5e1f2c01"
POINT = "19c565c1-cfaf-4348-88c5-592706f7fd7a"
GUINNESS = "5ff1e3da-2d0d-4fdd-8e42-bf8a353157f8"   # 770
COLA = "7a1c0000-0000-4000-8000-000000000501"       # 350

failures = []

def curl(method, url, headers=None, body=None, raw=None):
    cmd = ["curl", "-s", "-X", method, url, "-w", "\n%{http_code}"]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    data = raw if raw is not None else (json.dumps(body) if body is not None else None)
    if data is not None:
        cmd += ["-d", data]
    out = subprocess.run(cmd, capture_output=True).stdout.decode("utf-8", errors="replace")
    text, _, code = out.rpartition("\n")
    try:
        payload = json.loads(text) if text else None
    except json.JSONDecodeError:
        payload = text
    return int(code), payload

def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + (f"  [{detail}]" if not condition else ""))
    if not condition:
        failures.append(name)

admin = {"apikey": SERVICE, "Authorization": f"Bearer {SERVICE}", "Content-Type": "application/json"}
email = f"e2e-{uuid.uuid4().hex[:10]}@example.com"
password = "TestPassw0rd!" + uuid.uuid4().hex[:6]

user_id = None
try:
    code, user = curl("POST", f"{BASE}/auth/v1/admin/users", admin,
                      {"email": email, "password": password, "email_confirm": True,
                       "user_metadata": {"full_name": "E2E Tester"}})
    check("admin creates confirmed test user", code == 200, f"{code} {user}")
    user_id = user["id"]

    code, session = curl("POST", f"{BASE}/auth/v1/token?grant_type=password",
                         {"apikey": ANON, "Content-Type": "application/json"},
                         {"email": email, "password": password})
    check("password sign-in returns a session", code == 200 and "access_token" in session, f"{code}")
    token = session["access_token"]
    auth = {"apikey": ANON, "Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    code, profile = curl("GET", f"{BASE}/rest/v1/profiles?select=full_name,email", auth)
    check("signup trigger created profile (readable via RLS)",
          code == 200 and profile and profile[0]["full_name"] == "E2E Tester", f"{code} {profile}")

    code, wallet = curl("GET", f"{BASE}/rest/v1/reward_wallets?select=available_points", auth)
    check("reward wallet created", code == 200 and len(wallet) == 1, f"{code} {wallet}")

    # --- favourites ---
    code, _ = curl("POST", f"{BASE}/rest/v1/favourite_venues", {**auth, "Prefer": "return=minimal"},
                   {"user_id": user_id, "venue_id": AVIVA})
    check("add favourite", code == 201, str(code))
    code, favs = curl("GET", f"{BASE}/rest/v1/favourite_venues?select=venue_id", auth)
    check("read favourite back", code == 200 and favs == [{"venue_id": AVIVA}], f"{favs}")
    # The app adds favourites with an idempotent upsert (ignore duplicates).
    code, r = curl("POST", f"{BASE}/rest/v1/favourite_venues?on_conflict=user_id,venue_id",
                   {**auth, "Prefer": "resolution=ignore-duplicates,return=minimal"},
                   {"user_id": user_id, "venue_id": AVIVA})
    check("re-adding an existing favourite via upsert is a no-op", code in (200, 201, 204), f"{code} {r}")
    code, _ = curl("POST", f"{BASE}/rest/v1/favourite_venues", {**auth, "Prefer": "return=minimal"},
                   {"user_id": str(uuid.uuid4()), "venue_id": AVIVA})
    check("cannot add favourite for another user (RLS)", code in (401, 403), str(code))
    code, _ = curl("DELETE", f"{BASE}/rest/v1/favourite_venues?venue_id=eq.{AVIVA}", auth)
    check("remove favourite", code == 204, str(code))
    # First-time add through the upsert form the app uses.
    code, r = curl("POST", f"{BASE}/rest/v1/favourite_venues?on_conflict=user_id,venue_id",
                   {**auth, "Prefer": "resolution=ignore-duplicates,return=minimal"},
                   {"user_id": user_id, "venue_id": AVIVA})
    check("first-time add via upsert works", code in (200, 201, 204), f"{code} {r}")
    curl("DELETE", f"{BASE}/rest/v1/favourite_venues?venue_id=eq.{AVIVA}", auth)

    # --- create-order ---
    key = str(uuid.uuid4())
    body = {"venue_id": AVIVA, "collection_point_id": POINT, "ordered_for_halftime": True,
            "items": [{"menu_item_id": GUINNESS, "quantity": 2}, {"menu_item_id": COLA, "quantity": 1}]}
    fn = lambda name: f"{BASE}/functions/v1/{name}"
    code, order = curl("POST", fn("create-order"), {**auth, "idempotency-key": key}, body)
    check("create-order succeeds", code == 201, f"{code} {order}")
    # 2*770 + 350 = 1890; fee round(1890*0.075)=142 (141.75); total 2032
    check("server computes totals (subtotal 1890, fee 142, total 2032)",
          order.get("subtotal_cents") == 1890 and order.get("service_fee_cents") == 142 and order.get("total_cents") == 2032,
          str(order))
    order_id = order["id"]

    code, again = curl("POST", fn("create-order"), {**auth, "idempotency-key": key}, body)
    check("same idempotency key returns same order", code == 200 and again["id"] == order_id, f"{code} {again}")

    # tampering / validation
    code, r = curl("POST", fn("create-order"), {**auth, "idempotency-key": str(uuid.uuid4())},
                   {**body, "items": [{"menu_item_id": GUINNESS, "quantity": 0}]})
    check("rejects zero quantity", code == 400, f"{code} {r}")
    code, r = curl("POST", fn("create-order"), {**auth, "idempotency-key": str(uuid.uuid4())},
                   {**body, "items": [{"menu_item_id": GUINNESS, "quantity": 999}]})
    check("rejects absurd quantity", code == 400, f"{code} {r}")
    code, r = curl("POST", fn("create-order"), {**auth, "idempotency-key": str(uuid.uuid4())},
                   {**body, "venue_id": FAIRYHOUSE})
    check("rejects closed venue", code == 400, f"{code} {r}")
    code, r = curl("POST", fn("create-order"), {**auth, "idempotency-key": str(uuid.uuid4())},
                   {**body, "items": [{"menu_item_id": str(uuid.uuid4()), "quantity": 1}]})
    check("rejects unknown item", code == 400, f"{code} {r}")
    code, r = curl("POST", fn("create-order"), {"apikey": ANON, "Authorization": f"Bearer {ANON}",
                                                 "idempotency-key": str(uuid.uuid4()), "Content-Type": "application/json"}, body)
    check("rejects anon key as user", code == 401, f"{code} {r}")

    # --- checkout session (real Stripe test mode) ---
    code, sess = curl("POST", fn("create-checkout-session"), auth, {"order_id": order_id})
    url = (sess or {}).get("checkout_url") or ""
    check("create-checkout-session returns a Stripe URL", code == 200 and url.startswith("https://checkout.stripe.com/"), f"{code} {sess}")
    code, sess2 = curl("POST", fn("create-checkout-session"), auth, {"order_id": order_id})
    check("second call reuses the same open session", code == 200 and sess2.get("checkout_url") == url, f"{code}")

    # --- webhook ---
    def send_event(event_type, obj):
        payload = json.dumps({"id": "evt_test_" + uuid.uuid4().hex[:8], "type": event_type, "data": {"object": obj}})
        ts = str(int(time.time()))
        sig = hmac.new(WHSEC.encode(), f"{ts}.{payload}".encode(), hashlib.sha256).hexdigest()
        return curl("POST", fn("stripe-webhook"), {"stripe-signature": f"t={ts},v1={sig}", "Content-Type": "application/json"}, raw=payload)

    code, r = curl("POST", fn("stripe-webhook"), {"stripe-signature": f"t={int(time.time())},v1=deadbeef"}, raw="{}")
    check("webhook rejects wrong signature", code == 400, f"{code} {r}")
    old = str(int(time.time()) - 3600)
    payload = "{}"
    sig = hmac.new(WHSEC.encode(), f"{old}.{payload}".encode(), hashlib.sha256).hexdigest()
    code, r = curl("POST", fn("stripe-webhook"), {"stripe-signature": f"t={old},v1={sig}"}, raw=payload)
    check("webhook rejects stale (replayed) timestamp", code == 400, f"{code} {r}")

    code, r = send_event("checkout.session.completed", {
        "id": "cs_test_x", "payment_status": "paid", "amount_total": 999999,
        "payment_intent": "pi_test_wrong", "metadata": {"order_id": order_id}})
    check("signed event with wrong amount is acknowledged", code == 200, f"{code} {r}")
    code, rows = curl("GET", f"{BASE}/rest/v1/orders?select=status&id=eq.{order_id}", auth)
    check("wrong-amount payment does NOT mark order paid", rows == [{"status": "pending_payment"}], str(rows))

    pi = "pi_test_" + uuid.uuid4().hex[:10]
    code, r = send_event("checkout.session.completed", {
        "id": "cs_test_x", "payment_status": "paid", "amount_total": 2032,
        "payment_intent": pi, "metadata": {"order_id": order_id}})
    check("signed correct event accepted", code == 200, f"{code} {r}")
    code, rows = curl("GET", f"{BASE}/rest/v1/orders?select=status,payment_intent_id&id=eq.{order_id}", auth)
    check("order is now paid with payment intent stored", rows == [{"status": "paid", "payment_intent_id": pi}], str(rows))

    send_event("payment_intent.succeeded", {"id": pi, "amount_received": 2032, "metadata": {"order_id": order_id}})
    send_event("checkout.session.completed", {
        "id": "cs_test_x", "payment_status": "paid", "amount_total": 2032,
        "payment_intent": pi, "metadata": {"order_id": order_id}})
    code, events = curl("GET", f"{BASE}/rest/v1/order_status_events?select=status,note&order_id=eq.{order_id}&order=created_at", auth)
    paid_events = [e for e in events if e["status"] == "paid"]
    check("duplicate deliveries don't repeat the paid event", len(paid_events) == 1, str(events))

    code, r = curl("POST", fn("create-checkout-session"), auth, {"order_id": order_id})
    check("paying an already-paid order returns no checkout url", code == 200 and r.get("checkout_url") is None and r.get("status") == "paid", f"{r}")

    code, orders = curl("GET", f"{BASE}/rest/v1/orders?select=id,status,total_cents,venues(name),collection_points(name,floor_label,block_label),order_items(title_snapshot,quantity)", auth)
    check("orders list with embeds (what the app queries)", code == 200 and orders[0]["venues"]["name"] == "Aviva Stadium" and len(orders[0]["order_items"]) == 2, f"{code} {orders}")

    # a different user cannot see or pay this order
    code, r = curl("POST", fn("create-checkout-session"), {"apikey": ANON, "Authorization": f"Bearer {ANON}", "Content-Type": "application/json"}, {"order_id": order_id})
    check("anon cannot create checkout session", code == 401, f"{code}")

    # --- catalog: venues, cafes, menus, photos ---
    code, venues = curl("GET", f"{BASE}/rest/v1/venues?select=id,name,kind,is_open,cover_image_url,group_name&is_active=eq.true", auth)
    cafes = [v for v in venues if v["kind"] == "cafe"]
    stadiums = [v for v in venues if v["kind"] == "venue"]
    check("at least 10 venues that are not cafes", len(stadiums) >= 10, f"{len(stadiums)}")
    check("at least 12 cafes", len(cafes) >= 12, f"{len(cafes)}")
    check("every venue and cafe has a photo", all(v["cover_image_url"] for v in venues), str([v["name"] for v in venues if not v["cover_image_url"]]))
    code, _ = curl("GET", cafes[0]["cover_image_url"])
    check("a catalog photo loads from Storage", code == 200, str(code))
    code, credits = curl("GET", f"{BASE}/rest/v1/image_credits?select=image_key,author,license", auth)
    check("image credits are readable", code == 200 and len(credits) > 20, f"{code}")

    def menu(venue_id):
        code, items = curl(
            "GET",
            f"{BASE}/rest/v1/menu_items?select=id,title,price_cents,is_available,image_url,menu_categories(title),"
            f"menu_item_option_groups(menu_option_groups(title,is_required,menu_options(id,title,price_delta_cents)))"
            f"&venue_id=eq.{venue_id}&order=sort_order", auth)
        return {i["title"]: i for i in items}

    def point(venue_id):
        code, pts = curl("GET", f"{BASE}/rest/v1/collection_points?select=id&venue_id=eq.{venue_id}&is_open=eq.true", auth)
        return pts[0]["id"]

    cafe = next(v for v in cafes if v["name"] == "Guys - Guys Blackrock")
    cafe_menu = menu(cafe["id"])
    check("cafe menu has the screenshot items", all(t in cafe_menu for t in ["Americano", "Flat White", "Caramel Slice", "Almond Croissant", "Sparkling Water", "Ham & Cheese Toastie"]), str(list(cafe_menu)[:5]))
    check("unavailable item is visible but flagged", cafe_menu["Caramel Slice"]["is_available"] is False)
    check("cafe menu has 8 sandwiches and 12 coffees", sum(1 for i in cafe_menu.values() if i["menu_categories"]["title"] == "Sandwiches") == 8 and sum(1 for i in cafe_menu.values() if i["menu_categories"]["title"] == "Coffee") == 12)
    check("every menu item has a photo", all(i["image_url"] for i in cafe_menu.values()))

    stadium = next(v for v in stadiums if v["name"] == "Croke Park")
    stadium_menu = menu(stadium["id"])
    check("venue menu has bar items plus soft drinks and sandwiches", all(t in stadium_menu for t in ["Guinness", "Coca-Cola", "Ham & Cheese Toastie"]))

    def order(venue, items, **extra):
        payload = {"venue_id": venue["id"], "collection_point_id": point(venue["id"]), "items": items, **extra}
        return curl("POST", fn("create-order"), {**auth, "idempotency-key": str(uuid.uuid4())}, payload)

    code, r = order(cafe, [{"menu_item_id": cafe_menu["Caramel Slice"]["id"], "quantity": 1}])
    check("unavailable item cannot be ordered", code == 409, f"{code} {r}")

    # options: Latte needs a size; Large (+50) and Oat milk (+50) change the price
    latte = cafe_menu["Latte"]
    groups = {g["menu_option_groups"]["title"]: g["menu_option_groups"] for g in latte["menu_item_option_groups"]}
    size = {o["title"]: o["id"] for o in groups["Size"]["menu_options"]}
    milk = {o["title"]: o["id"] for o in groups["Milk"]["menu_options"]}
    syrup = {o["title"]: o["id"] for o in groups["Syrup"]["menu_options"]}
    code, r = order(cafe, [{"menu_item_id": latte["id"], "quantity": 1}])
    check("required size must be chosen", code == 400, f"{code} {r}")
    code, r = order(cafe, [{"menu_item_id": latte["id"], "quantity": 1, "option_ids": [size["Regular"], size["Large"]]}])
    check("two sizes are rejected", code == 400, f"{code} {r}")
    code, r = order(cafe, [{"menu_item_id": cafe_menu["Espresso"]["id"], "quantity": 1, "option_ids": [size["Large"]]}])
    check("option from another item is rejected", code == 400, f"{code} {r}")
    code, r = curl("POST", fn("create-order"), {**auth}, {"venue_id": cafe["id"], "preview": True,
                   "items": [{"menu_item_id": latte["id"], "quantity": 2, "option_ids": [size["Large"], milk["Oat milk"], syrup["Vanilla"], syrup["Caramel"]]}]})
    base_latte = latte["price_cents"]
    unit = base_latte + 50 + 50 + 40 + 40
    check("preview prices options server-side", code == 200 and r["subtotal_cents"] == unit * 2, f"{code} {r} expected {unit * 2}")

    code, r = curl("POST", fn("create-order"), {**auth}, {"venue_id": cafe["id"], "preview": True,
                   "items": [{"menu_item_id": latte["id"].upper(), "quantity": 2, "option_ids": [size["Large"].upper(), milk["Oat milk"].upper(), syrup["Vanilla"].upper(), syrup["Caramel"].upper()]}]})
    check("upper-case ids (as the iOS app sends them) are priced the same", code == 200 and r["subtotal_cents"] == unit * 2, f"{code} {r}")

    # pickup time, promo codes, discount through Stripe
    from datetime import datetime, timedelta, timezone
    iso = lambda minutes: (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()
    line = [{"menu_item_id": latte["id"], "quantity": 2, "option_ids": [size["Regular"]]}]
    code, r = order(cafe, line, pickup_at=iso(-30))
    check("past pickup time is rejected", code == 400, f"{code} {r}")
    code, r = order(cafe, line, promo_code="NOPE")
    check("unknown promo code is rejected", code == 400 and "promo" in r.get("error", "").lower(), f"{code} {r}")
    code, p10 = curl("POST", fn("create-order"), auth, {"venue_id": cafe["id"], "items": line, "promo_code": "skip10", "preview": True})
    sub = base_latte * 2
    disc = round(sub * 0.10)
    fee = round((sub - disc) * 0.075)
    check("SKIP10 takes 10% off (fee charged on the discounted amount)",
          code == 200 and p10["discount_cents"] == disc and p10["service_fee_cents"] == fee and p10["total_cents"] == sub - disc + fee, f"{code} {p10}")
    code, w2 = curl("POST", fn("create-order"), auth, {"venue_id": cafe["id"], "items": line, "promo_code": "WELCOME2", "preview": True})
    check("WELCOME2 takes 2.00 off", code == 200 and w2["discount_cents"] == 200, f"{code} {w2}")

    code, cafe_order = order(cafe, line, promo_code="SKIP10", pickup_at=iso(45))
    check("cafe order with promo and pickup time is created", code == 201 and cafe_order["discount_cents"] == disc and cafe_order["pickup_at"], f"{code} {cafe_order}")
    code, sess = curl("POST", fn("create-checkout-session"), auth, {"order_id": cafe_order["id"]})
    check("Stripe session for a discounted order matches our total", code == 200 and (sess.get("checkout_url") or "").startswith("https://checkout.stripe.com/"), f"{code} {sess}")

    # separate baskets: a second order at a stadium is independent
    code, stadium_order = order(stadium, [{"menu_item_id": stadium_menu["Guinness"]["id"], "quantity": 2}])
    check("order at a different venue is independent", code == 201 and stadium_order["venue_id"] == stadium["id"] and stadium_order["id"] != cafe_order["id"], f"{code} {stadium_order}")
    code, r = order(cafe, [{"menu_item_id": stadium_menu["Guinness"]["id"], "quantity": 1}])
    check("items cannot cross venues", code == 400, f"{code} {r}")

    code, r = send_event("checkout.session.completed", {
        "id": "cs_test_y", "payment_status": "paid", "amount_total": cafe_order["total_cents"],
        "payment_intent": "pi_test_" + uuid.uuid4().hex[:10], "metadata": {"order_id": cafe_order["id"]}})
    code, rows = curl("GET", f"{BASE}/rest/v1/orders?select=status&id=eq.{cafe_order['id']}", auth)
    check("webhook marks the discounted cafe order paid", rows == [{"status": "paid"}], str(rows))
    code, rows = curl("GET", f"{BASE}/rest/v1/orders?select=status&id=eq.{stadium_order['id']}", auth)
    check("the other venue's order is still unpaid", rows == [{"status": "pending_payment"}], str(rows))
    code, line_rows = curl("GET", f"{BASE}/rest/v1/order_items?select=title_snapshot,options_snapshot&order_id=eq.{cafe_order['id']}", auth)
    check("order keeps a snapshot of chosen options", code == 200 and line_rows[0]["options_snapshot"][0]["title"] == "Regular", str(line_rows))

    code, promos = curl("GET", f"{BASE}/rest/v1/promo_codes?select=code", auth)
    check("users cannot list promo codes", code == 200 and promos == [], f"{code} {promos}")

    restaurants = [v for v in venues if v["kind"] == "restaurant"]
    check("at least 8 restaurants", len(restaurants) >= 8, str(len(restaurants)))
    resto = next(v for v in restaurants if v["name"] == "Dragon Pearl")
    resto_menu = menu(resto["id"])
    check("chinese restaurant has Sweet & Sour Chicken", "Sweet & Sour Chicken" in resto_menu, str(list(resto_menu)[:6]))
    takeout_line = [{"menu_item_id": resto_menu["Sweet & Sour Chicken"]["id"], "quantity": 1}]
    code, takeout = order(resto, takeout_line, fulfillment_type="takeout")
    check("restaurant takeout order is created", code == 201 and takeout.get("fulfillment_type") == "takeout", f"{code} {takeout}")

    from datetime import datetime, timedelta, timezone
    reserve = (datetime.now(timezone.utc) + timedelta(hours=2)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    code, dine = order(
        resto,
        takeout_line,
        fulfillment_type="dine_in",
        payment_mode="at_venue",
        party_size=3,
        pickup_at=reserve,
    )
    check(
        "dine-in pay-at-venue is confirmed without Stripe",
        code == 201 and dine.get("status") == "paid" and dine.get("payment_mode") == "at_venue" and dine.get("party_size") == 3,
        f"{code} {dine}",
    )
    code, sess = curl("POST", fn("create-checkout-session"), auth, {"order_id": dine["id"]})
    check("at-venue order has no Stripe checkout", code == 200 and sess.get("checkout_url") is None, f"{code} {sess}")

    # force ready then collect
    curl("PATCH", f"{BASE}/rest/v1/orders?id=eq.{dine['id']}", {**admin, "Prefer": "return=minimal"}, {"status": "ready"})
    code, marked = curl("POST", fn("mark-order-collected"), auth, {"order_id": dine["id"]})
    check("ready order can be marked collected", code == 200 and marked.get("status") == "collected", f"{code} {marked}")
    code, marked2 = curl("POST", fn("mark-order-collected"), auth, {"order_id": dine["id"]})
    check("collecting again is rejected", code == 400, f"{code} {marked2}")

    # --- delete account ---
    code, r = curl("POST", fn("delete-account"), auth, {})
    check("delete-account succeeds", code == 200 and r.get("deleted") is True, f"{code} {r}")
    user_id = None
    code, r = curl("GET", f"{BASE}/rest/v1/orders?select=id&id=eq.{order_id}", admin)
    check("user's orders removed with the account", code == 200 and r == [], str(r))
finally:
    if user_id:
        curl("DELETE", f"{BASE}/auth/v1/admin/users/{user_id}", admin)

print()
print("ALL PASSED" if not failures else f"FAILED: {failures}")
sys.exit(1 if failures else 0)
