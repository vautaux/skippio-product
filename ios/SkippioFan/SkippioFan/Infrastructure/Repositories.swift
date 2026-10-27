import Foundation
import Supabase

enum RepositoryConfigError: LocalizedError {
  case invalidSupabaseConfiguration

  var errorDescription: String? {
    AppConfig.configurationError ?? "Supabase configuration is invalid."
  }
}

/// A server-side failure with a message that is safe to show to the user.
struct BackendError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum Backend {
  static func client() throws -> SupabaseClient {
    guard
      SupabaseClientProvider.isConfigured,
      let client = SupabaseClientProvider.shared
    else {
      throw RepositoryConfigError.invalidSupabaseConfiguration
    }
    return client
  }
}

// MARK: - Edge functions

enum EdgeFunctions {
  /// Calls a Supabase Edge Function. The user's access token is attached by the client.
  static func call<T: Decodable>(
    _ name: String,
    headers: [String: String] = [:],
    body: some Encodable
  ) async throws -> T {
    let client = try Backend.client()
    do {
      return try await client.functions.invoke(
        name,
        options: FunctionInvokeOptions(headers: headers, body: body)
      )
    } catch let FunctionsError.httpError(_, data) {
      throw BackendError(message: message(from: data))
    }
  }

  static func callWithoutResult(_ name: String) async throws {
    let client = try Backend.client()
    do {
      try await client.functions.invoke(name)
    } catch let FunctionsError.httpError(_, data) {
      throw BackendError(message: message(from: data))
    }
  }

  /// Functions reply with `{ "error": "..." }`; the gateway uses `{ "message": "..." }`.
  private static func message(from data: Data) -> String {
    struct Payload: Decodable {
      let error: String?
      let message: String?
    }
    let payload = try? JSONDecoder().decode(Payload.self, from: data)
    return payload?.error ?? payload?.message ?? "Something went wrong. Please try again."
  }
}

// MARK: - Venues & favourites

struct VenueRepository {
  func fetchVenues() async throws -> [Venue] {
    try await Backend.client()
      .from("venues")
      .select()
      .eq("is_active", value: true)
      .order("name", ascending: true)
      .execute()
      .value
  }
}

struct FavouritesRepository {
  private struct Row: Decodable { let venue_id: UUID }
  private struct NewRow: Encodable {
    let user_id: UUID
    let venue_id: UUID
  }

  func fetchIDs() async throws -> Set<UUID> {
    let rows: [Row] = try await Backend.client()
      .from("favourite_venues")
      .select("venue_id")
      .execute()
      .value
    return Set(rows.map(\.venue_id))
  }

  func add(venueID: UUID, userID: UUID) async throws {
    try await Backend.client()
      .from("favourite_venues")
      .upsert(NewRow(user_id: userID, venue_id: venueID), onConflict: "user_id,venue_id", ignoreDuplicates: true)
      .execute()
  }

  func remove(venueID: UUID, userID: UUID) async throws {
    try await Backend.client()
      .from("favourite_venues")
      .delete()
      .eq("user_id", value: userID.uuidString)
      .eq("venue_id", value: venueID.uuidString)
      .execute()
  }
}

// MARK: - Menu

struct MenuRepository {
  func fetchCollectionPoints(venueID: UUID) async throws -> [CollectionPoint] {
    try await Backend.client()
      .from("collection_points")
      .select()
      .eq("venue_id", value: venueID.uuidString)
      .order("name", ascending: true)
      .execute()
      .value
  }

  func fetchCategories(venueID: UUID) async throws -> [MenuCategory] {
    let categories: [MenuCategory] = try await Backend.client()
      .from("menu_categories")
      .select(
        """
        id, title, sort_order,
        menu_items(id, category_id, title, subtitle, image_url, volume_label, price_cents, currency, is_available, sort_order, menu_item_allergens(allergen), menu_item_option_groups(menu_option_groups(id, title, is_required, allows_multiple, sort_order, menu_options(id, title, price_delta_cents, sort_order))))
        """
      )
      .eq("venue_id", value: venueID.uuidString)
      .order("sort_order", ascending: true)
      .execute()
      .value
    // Unavailable items stay in the list (shown as "Temporarily Unavailable").
    return categories.filter { !$0.items.isEmpty }.sorted { $0.sortOrder < $1.sortOrder }
  }
}

// MARK: - Orders

struct OrdersRepository {
  private static let columns = """
    id, status, total_cents, currency, created_at, ordered_for_halftime, pickup_at,
    fulfillment_type, payment_mode, party_size, seat_row, seat_number,
    venues(name),
    collection_points(name, floor_label, block_label),
    order_items(title_snapshot, quantity, options_snapshot)
    """

  func fetchOrders() async throws -> [FanOrder] {
    try await Backend.client()
      .from("orders")
      .select(Self.columns)
      .order("created_at", ascending: false)
      .limit(50)
      .execute()
      .value
  }

  func fetchStatus(orderID: UUID) async throws -> OrderStatus? {
    struct Row: Decodable { let status: OrderStatus }
    let rows: [Row] = try await Backend.client()
      .from("orders")
      .select("status")
      .eq("id", value: orderID.uuidString)
      .limit(1)
      .execute()
      .value
    return rows.first?.status
  }

  /// Advances paid → preparing → ready on a 5–10 minute kitchen clock (demo).
  @discardableResult
  func tickProgress() async -> Bool {
    struct Body: Encodable {}
    struct Payload: Decodable {
      struct Update: Decodable {
        let id: UUID
        let status: String
      }
      let updates: [Update]
    }
    do {
      let _: Payload = try await EdgeFunctions.call("tick-order-progress", body: Body())
      return true
    } catch {
      return false
    }
  }

  func markCollected(orderID: UUID) async throws {
    struct Body: Encodable { let order_id: UUID }
    struct Payload: Decodable {
      let id: UUID
      let status: OrderStatus
    }
    let _: Payload = try await EdgeFunctions.call(
      "mark-order-collected",
      body: Body(order_id: orderID)
    )
  }

  func modifyReservation(orderID: UUID, partySize: Int, pickupAt: Date) async throws {
    struct Body: Encodable {
      let order_id: UUID
      let party_size: Int
      let pickup_at: String
    }
    struct Payload: Decodable {
      let id: UUID
      let partySize: Int?
      let pickupAt: Date?

      enum CodingKeys: String, CodingKey {
        case id
        case partySize = "party_size"
        case pickupAt = "pickup_at"
      }
    }
    let _: Payload = try await EdgeFunctions.call(
      "modify-reservation",
      body: Body(
        order_id: orderID,
        party_size: partySize,
        pickup_at: ISO8601DateFormatter().string(from: pickupAt)
      )
    )
  }
}

// MARK: - Checkout

struct CheckoutService {
  private struct OrderLine: Encodable {
    let menu_item_id: UUID
    let quantity: Int
    let option_ids: [UUID]
  }

  private struct OrderBody: Encodable {
    let venue_id: UUID
    let collection_point_id: UUID?
    let ordered_for_halftime: Bool
    let pickup_at: Date?
    let promo_code: String?
    let fulfillment_type: String
    let payment_mode: String
    let party_size: Int?
    let seat_row: String?
    let seat_number: String?
    let preview: Bool
    let items: [OrderLine]

    enum CodingKeys: String, CodingKey {
      case venue_id, collection_point_id, ordered_for_halftime, pickup_at, promo_code
      case fulfillment_type, payment_mode, party_size, seat_row, seat_number, preview, items
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(venue_id, forKey: .venue_id)
      try c.encodeIfPresent(collection_point_id, forKey: .collection_point_id)
      try c.encode(ordered_for_halftime, forKey: .ordered_for_halftime)
      if let pickup_at {
        try c.encode(ISO8601DateFormatter().string(from: pickup_at), forKey: .pickup_at)
      }
      try c.encodeIfPresent(promo_code, forKey: .promo_code)
      try c.encode(fulfillment_type, forKey: .fulfillment_type)
      try c.encode(payment_mode, forKey: .payment_mode)
      try c.encodeIfPresent(party_size, forKey: .party_size)
      try c.encodeIfPresent(seat_row, forKey: .seat_row)
      try c.encodeIfPresent(seat_number, forKey: .seat_number)
      try c.encode(preview, forKey: .preview)
      try c.encode(items, forKey: .items)
    }
  }

  private struct SessionBody: Encodable {
    let order_id: UUID
  }

  private func body(for basket: Basket, preview: Bool) -> OrderBody {
    let seatDelivery = basket.fulfillmentType == .seatDelivery
    return OrderBody(
      venue_id: basket.venue.id,
      collection_point_id: basket.collectionPoint?.id,
      ordered_for_halftime: basket.orderedForHalftime,
      pickup_at: basket.pickupAt,
      promo_code: basket.promoCode,
      fulfillment_type: basket.fulfillmentType.rawValue,
      payment_mode: basket.paymentMode.rawValue,
      party_size: basket.partySize,
      seat_row: seatDelivery ? basket.trimmedSeatRow : nil,
      seat_number: seatDelivery ? basket.trimmedSeatNumber : nil,
      preview: preview,
      items: basket.lines.map {
        OrderLine(menu_item_id: $0.item.id, quantity: $0.quantity, option_ids: $0.options.map(\.id))
      }
    )
  }

  func createOrder(from basket: Basket) async throws -> CreatedOrder {
    guard basket.collectionPoint != nil, !basket.lines.isEmpty else {
      throw BackendError(message: "Your basket is empty.")
    }

    // The same key is reused for the same basket, so a retry can never double-charge.
    return try await EdgeFunctions.call(
      "create-order",
      headers: ["idempotency-key": basket.idempotencyKey],
      body: body(for: basket, preview: false)
    )
  }

  /// Server-side prices for the basket, including any promo code.
  func preview(basket: Basket) async throws -> PricePreview {
    try await EdgeFunctions.call("create-order", body: body(for: basket, preview: true))
  }

  func checkoutSession(orderID: UUID) async throws -> CheckoutSessionInfo {
    try await EdgeFunctions.call("create-checkout-session", body: SessionBody(order_id: orderID))
  }
}

// MARK: - Credits

struct ImageCreditsRepository {
  func fetch() async throws -> [ImageCredit] {
    try await Backend.client()
      .from("image_credits")
      .select()
      .order("title", ascending: true)
      .execute()
      .value
  }
}

// MARK: - Rewards

struct RewardsRepository {
  func fetchWallet() async throws -> RewardWallet {
    // Fetch as a list: a user without a wallet row yet gets zero rows, which
    // `.single()` would treat as an error.
    let wallets: [RewardWallet] = try await Backend.client()
      .from("reward_wallets")
      .select()
      .limit(1)
      .execute()
      .value

    return wallets.first ?? .empty
  }
}
