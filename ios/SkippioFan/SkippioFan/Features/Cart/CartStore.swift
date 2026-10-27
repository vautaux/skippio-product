import Foundation

/// Just enough of a menu item to show it in the basket (and to store it between launches).
struct CartItem: Codable, Hashable {
  let id: UUID
  let title: String
  let subtitle: String?
  let volumeLabel: String?
  let imageURL: String?
  let priceCents: Int
  let currency: String

  init(_ item: MenuItem) {
    id = item.id
    title = item.title
    subtitle = item.subtitle
    volumeLabel = item.volumeLabel
    imageURL = item.imageURL
    priceCents = item.priceCents
    currency = item.currency
  }
}

struct CartOption: Codable, Hashable {
  let id: UUID
  let group: String
  let title: String
  let priceDeltaCents: Int
}

/// One row of a basket. The same item with different options is a different row.
struct CartLine: Identifiable, Codable, Equatable {
  let item: CartItem
  let options: [CartOption]
  var quantity: Int

  var id: String {
    item.id.uuidString + "|" + options.map { $0.id.uuidString }.sorted().joined(separator: ",")
  }

  var unitCents: Int { item.priceCents + options.reduce(0) { $0 + $1.priceDeltaCents } }
  var totalCents: Int { unitCents * quantity }

  /// "Regular, Oat milk, Vanilla"
  var optionsLabel: String? {
    options.isEmpty ? nil : options.map(\.title).joined(separator: ", ")
  }
}

/// Everything the customer has chosen at one venue, café or restaurant.
struct Basket: Codable, Equatable {
  var venue: Venue
  var collectionPoint: CollectionPoint?
  var lines: [CartLine] = []
  /// nil means as soon as possible (takeout / venue collection).
  var pickupAt: Date?
  var orderedForHalftime = false
  var promoCode: String?
  var fulfillmentType: FulfillmentType = .collection
  var paymentMode: PaymentMode = .stripe
  var partySize: Int? = nil
  var seatRow: String = ""
  var seatNumber: String = ""
  /// Sent with create-order. It changes whenever the basket does, so retrying the
  /// same basket returns the same order instead of creating a second one.
  var idempotencyKey = UUID().uuidString

  var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }
  var subtotalCents: Int { lines.reduce(0) { $0 + $1.totalCents } }
  var currency: String { lines.first?.item.currency ?? "EUR" }
  var serviceFeeCents: Int { CartStore.serviceFee(onNet: subtotalCents) }
  var totalCents: Int { subtotalCents + serviceFeeCents }

  var trimmedSeatRow: String {
    seatRow.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedSeatNumber: String {
    seatNumber.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var hasValidSeat: Bool {
    !trimmedSeatRow.isEmpty && !trimmedSeatNumber.isEmpty
  }

  /// Empty dine-in / takeout shells must survive until the first item is added.
  var shouldKeepWhenEmpty: Bool {
    fulfillmentType == .dineIn
      || fulfillmentType == .takeout
      || partySize != nil
      || pickupAt != nil
  }
}

/// One basket per café or venue, kept per signed-in user. Prices here are for display;
/// the server recalculates everything from the database when the order is created.
@MainActor
final class CartStore: ObservableObject {
  nonisolated static let maxPerItem = 20
  /// Must match SERVICE_FEE_BPS in the create-order edge function.
  nonisolated static let serviceFeeBasisPoints = 750

  @Published private(set) var baskets: [UUID: Basket] = [:] {
    didSet { persist() }
  }

  private var userID: UUID?

  nonisolated static func serviceFee(onNet net: Int) -> Int {
    (net * serviceFeeBasisPoints + 5000) / 10000
  }

  // MARK: - Reading

  func basket(for venue: Venue) -> Basket? {
    guard let basket = baskets[venue.id], !basket.lines.isEmpty else { return nil }
    return basket
  }

  func itemCount(for venue: Venue) -> Int { basket(for: venue)?.itemCount ?? 0 }

  /// Quantity of an item across all of its option combinations.
  func quantity(of itemID: UUID, at venue: Venue) -> Int {
    basket(for: venue)?.lines.filter { $0.item.id == itemID }.reduce(0) { $0 + $1.quantity } ?? 0
  }

  // MARK: - Per-user storage

  /// Call when the signed-in user changes. A different user never sees someone else's baskets.
  func bind(userID: UUID?) {
    guard userID != self.userID else { return }
    self.userID = nil // don't write the outgoing user's baskets under the new key
    baskets = [:]
    self.userID = userID
    guard let userID,
      let data = UserDefaults.standard.data(forKey: Self.storageKey(userID)),
      let stored = try? JSONDecoder().decode([String: Basket].self, from: data)
    else { return }
    var restored: [UUID: Basket] = [:]
    for (key, basket) in stored {
      if let id = UUID(uuidString: key), !basket.lines.isEmpty { restored[id] = basket }
    }
    baskets = restored
  }

  private static func storageKey(_ userID: UUID) -> String { "baskets.v1.\(userID.uuidString)" }

  private func persist() {
    guard let userID else { return }
    let stored = Dictionary(
      uniqueKeysWithValues: baskets.filter { !$0.value.lines.isEmpty }.map { ($0.key.uuidString, $0.value) }
    )
    if let data = try? JSONEncoder().encode(stored) {
      UserDefaults.standard.set(data, forKey: Self.storageKey(userID))
    }
  }

  // MARK: - Editing

  /// Adds one of an item (with the chosen options) to this venue's basket.
  func add(_ item: MenuItem, options: [CartOption] = [], venue: Venue, collectionPoint: CollectionPoint?) {
    var basket = baskets[venue.id] ?? Basket(venue: venue, collectionPoint: collectionPoint)
    basket.venue = venue
    basket.collectionPoint = collectionPoint ?? basket.collectionPoint

    let candidate = CartLine(item: CartItem(item), options: options, quantity: 1)
    if let index = basket.lines.firstIndex(where: { $0.id == candidate.id }) {
      guard basket.lines[index].quantity < Self.maxPerItem else { return }
      basket.lines[index].quantity += 1
    } else {
      basket.lines.append(candidate)
    }
    commit(basket)
  }

  func increment(lineID: String, venueID: UUID) {
    mutate(venueID) { basket in
      guard let index = basket.lines.firstIndex(where: { $0.id == lineID }),
        basket.lines[index].quantity < Self.maxPerItem
      else { return }
      basket.lines[index].quantity += 1
    }
  }

  func decrement(lineID: String, venueID: UUID) {
    mutate(venueID) { basket in
      guard let index = basket.lines.firstIndex(where: { $0.id == lineID }) else { return }
      if basket.lines[index].quantity > 1 {
        basket.lines[index].quantity -= 1
      } else {
        basket.lines.remove(at: index)
      }
    }
  }

  func setPickup(_ date: Date?, venueID: UUID) {
    mutate(venueID) { $0.pickupAt = date }
  }

  func setHalftime(_ value: Bool, venueID: UUID) {
    mutate(venueID) { $0.orderedForHalftime = value }
  }

  func setPromoCode(_ code: String?, venueID: UUID) {
    mutate(venueID) { $0.promoCode = code }
  }

  func setFulfillment(_ type: FulfillmentType, venueID: UUID) {
    mutate(venueID) { basket in
      basket.fulfillmentType = type
      if type != .seatDelivery {
        basket.seatRow = ""
        basket.seatNumber = ""
      }
    }
  }

  func setPaymentMode(_ mode: PaymentMode, venueID: UUID) {
    mutate(venueID) { $0.paymentMode = mode }
  }

  func setPartySize(_ size: Int?, venueID: UUID) {
    mutate(venueID) { $0.partySize = size }
  }

  func setSeatRow(_ value: String, venueID: UUID) {
    // Don't rotate the idempotency key on every keystroke.
    guard var basket = baskets[venueID] else { return }
    basket.seatRow = value
    baskets[venueID] = basket
  }

  func setSeatNumber(_ value: String, venueID: UUID) {
    guard var basket = baskets[venueID] else { return }
    basket.seatNumber = value
    baskets[venueID] = basket
  }

  /// Ensures a basket shell exists so dine-in reservation can be stored before items.
  func ensureBasket(
    venue: Venue,
    collectionPoint: CollectionPoint?,
    fulfillment: FulfillmentType,
    partySize: Int? = nil,
    pickupAt: Date? = nil
  ) {
    if var existing = baskets[venue.id] {
      existing.venue = venue
      existing.collectionPoint = collectionPoint ?? existing.collectionPoint
      existing.fulfillmentType = fulfillment
      if fulfillment == .dineIn {
        if let partySize { existing.partySize = partySize }
        if let pickupAt { existing.pickupAt = pickupAt }
      } else {
        existing.partySize = nil
        existing.pickupAt = pickupAt
      }
      baskets[venue.id] = existing
      return
    }
    baskets[venue.id] = Basket(
      venue: venue,
      collectionPoint: collectionPoint,
      pickupAt: pickupAt,
      fulfillmentType: fulfillment,
      partySize: partySize
    )
  }

  /// Empties one basket (after paying). Other venues' baskets are untouched.
  func clear(venueID: UUID) {
    baskets[venueID] = nil
  }

  private func mutate(_ venueID: UUID, _ change: (inout Basket) -> Void) {
    guard var basket = baskets[venueID] else { return }
    change(&basket)
    commit(basket)
  }

  private func commit(_ updated: Basket) {
    var basket = updated
    basket.idempotencyKey = UUID().uuidString
    if basket.lines.isEmpty && !basket.shouldKeepWhenEmpty {
      baskets[basket.venue.id] = nil
    } else {
      baskets[basket.venue.id] = basket
    }
  }
}
