import { adminClient, authenticate, json, preflight } from "../_shared/http.ts";

// Permanently deletes the signed-in user. Their profile, favourites, reward wallet
// and orders are removed by the database's ON DELETE CASCADE rules.
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

  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) {
    console.error("delete-account failed", error);
    return json(500, { error: "We could not delete your account. Please try again." });
  }

  return json(200, { deleted: true });
});
