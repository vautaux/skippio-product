// Stripe redirects the in-app browser here after Checkout. We bounce straight on to
// the app's custom URL scheme, which the app's web-auth session intercepts.
// This endpoint reveals nothing and changes nothing; payment state only ever changes
// through the signed Stripe webhook.
Deno.serve((req) => {
  const params = new URL(req.url).searchParams;
  const orderId = params.get("order_id") ?? "";
  const result = params.get("result") === "success" ? "success" : "cancel";

  // Only forward a well-formed UUID.
  const safeOrderId = /^[0-9a-f-]{36}$/i.test(orderId) ? orderId : "";

  return new Response(null, {
    status: 302,
    headers: {
      Location: `skippiodemo://checkout?result=${result}&order_id=${safeOrderId}`,
    },
  });
});
