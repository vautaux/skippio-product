import Foundation

// MARK: - User

/// The signed-in Supabase user, reduced to what the UI needs.
struct AppUser: Equatable {
  let id: UUID
  let email: String
  let fullName: String
  /// Auth provider ("email", "google", ...).
  let provider: String

  var displayName: String {
    if !fullName.isEmpty { return fullName }
    return email.split(separator: "@").first.map(String.init) ?? email
  }

  var firstName: String {
    displayName.split(separator: " ").first.map(String.init) ?? displayName
  }

  var initial: String { String(displayName.prefix(1)).uppercased() }
  var isGoogle: Bool { provider == "google" }
}

// MARK: - Money

enum Money {
  static func format(cents: Int, currency: String = "EUR") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.locale = Locale(identifier: "en_IE")
    return formatter.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(currency) \(cents / 100)"
  }
}

// MARK: - Venues

enum VenueKind: String, Codable, CaseIterable {
  case cafe
  case venue
  case restaurant
  case `private`
}

enum FulfillmentType: String, Codable, Equatable {
  case collection
  case takeout
  case dineIn = "dine_in"
  case seatDelivery = "seat_delivery"
}

enum PaymentMode: String, Codable, Equatable {
  case stripe
  case atVenue = "at_venue"
}

struct Venue: Codable, Identifiable, Hashable {
  let id: UUID
  let name: String
  let address: String
  let city: String
  let country: String
  let coverImageURL: String?
  let logoURL: String?
  let subtitle: String?
  let kind: VenueKind
  let isOpen: Bool
  let isActive: Bool
  let latitude: Double?
  let longitude: Double?
  let groupName: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case address
    case city
    case country
    case coverImageURL = "cover_image_url"
    case logoURL = "logo_url"
    case subtitle
    case kind
    case isOpen = "is_open"
    case isActive = "is_active"
    case latitude
    case longitude
    case groupName = "group_name"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    address = try c.decode(String.self, forKey: .address)
    city = try c.decode(String.self, forKey: .city)
    country = try c.decode(String.self, forKey: .country)
    coverImageURL = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
    logoURL = try c.decodeIfPresent(String.self, forKey: .logoURL)
    subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    kind = try c.decodeIfPresent(VenueKind.self, forKey: .kind) ?? .venue
    isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
    isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
    longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    groupName = try c.decodeIfPresent(String.self, forKey: .groupName)
  }

  /// Short initials used when a venue has no logo image.
  var initials: String {
    // Skip stray punctuation such as the "-" in "Guys - Guys Blackrock".
    let letters = name
      .split(separator: " ")
      .filter { $0.first?.isLetter == true }
      .prefix(2)
      .compactMap { $0.first }
    return String(letters).uppercased()
  }
}

struct CollectionPoint: Codable, Identifiable, Hashable {
  let id: UUID
  let venueID: UUID
  let name: String
  let floorLabel: String
  let blockLabel: String
  let averageWaitSeconds: Int
  let isOpen: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case venueID = "venue_id"
    case name
    case floorLabel = "floor_label"
    case blockLabel = "block_label"
    case averageWaitSeconds = "average_wait_seconds"
    case isOpen = "is_open"
  }

  var locationLabel: String { "\(floorLabel) - \(blockLabel)" }

  var waitLabel: String {
    let minutes = max(1, averageWaitSeconds / 60)
    return "\(minutes)-\(minutes + 1) min"
  }
}

// MARK: - Menu

struct MenuItem: Identifiable, Hashable, Decodable {
  let id: UUID
  let categoryID: UUID
  let title: String
  let subtitle: String?
  let imageURL: String?
  let volumeLabel: String?
  let priceCents: Int
  let currency: String
  let isAvailable: Bool
  let sortOrder: Int
  let allergens: [String]
  let optionGroups: [OptionGroup]

  private struct AllergenRow: Decodable { let allergen: String }
  private struct OptionLink: Decodable {
    let group: OptionGroup?
    enum CodingKeys: String, CodingKey { case group = "menu_option_groups" }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case categoryID = "category_id"
    case title
    case subtitle
    case imageURL = "image_url"
    case volumeLabel = "volume_label"
    case priceCents = "price_cents"
    case currency
    case isAvailable = "is_available"
    case sortOrder = "sort_order"
    case allergenRows = "menu_item_allergens"
    case optionLinks = "menu_item_option_groups"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    categoryID = try c.decode(UUID.self, forKey: .categoryID)
    title = try c.decode(String.self, forKey: .title)
    subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
    volumeLabel = try c.decodeIfPresent(String.self, forKey: .volumeLabel)
    priceCents = try c.decode(Int.self, forKey: .priceCents)
    currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "EUR"
    isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
    sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    let rows = try c.decodeIfPresent([AllergenRow].self, forKey: .allergenRows) ?? []
    allergens = rows.map(\.allergen).sorted()
    let links = try c.decodeIfPresent([OptionLink].self, forKey: .optionLinks) ?? []
    optionGroups = links.compactMap(\.group).sorted { $0.sortOrder < $1.sortOrder }
  }

  var hasOptions: Bool { !optionGroups.isEmpty }

  /// What the menu row shows under the title.
  var detailLine: String? {
    [volumeLabel, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.first
  }
}

/// A choice shown when adding an item, such as Size, Milk or Syrup.
struct OptionGroup: Identifiable, Hashable, Decodable {
  let id: UUID
  let title: String
  let isRequired: Bool
  let allowsMultiple: Bool
  let sortOrder: Int
  let options: [MenuOption]

  enum CodingKeys: String, CodingKey {
    case id, title
    case isRequired = "is_required"
    case allowsMultiple = "allows_multiple"
    case sortOrder = "sort_order"
    case options = "menu_options"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
    allowsMultiple = try c.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
    sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    let decoded = try c.decodeIfPresent([MenuOption].self, forKey: .options) ?? []
    options = decoded.sorted { $0.sortOrder < $1.sortOrder }
  }
}

struct MenuOption: Identifiable, Hashable, Decodable {
  let id: UUID
  let title: String
  let priceDeltaCents: Int
  let sortOrder: Int

  enum CodingKeys: String, CodingKey {
    case id, title
    case priceDeltaCents = "price_delta_cents"
    case sortOrder = "sort_order"
  }
}

struct MenuCategory: Identifiable, Hashable, Decodable {
  let id: UUID
  let title: String
  let sortOrder: Int
  let items: [MenuItem]

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case sortOrder = "sort_order"
    case items = "menu_items"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    let decoded = try c.decodeIfPresent([MenuItem].self, forKey: .items) ?? []
    items = decoded.sorted { $0.sortOrder < $1.sortOrder }
  }
}

// MARK: - Orders

enum OrderStatus: String, Codable {
  case pendingPayment = "pending_payment"
  case paid
  case preparing
  case ready
  case collected
  case cancelled

  var label: String {
    switch self {
    case .pendingPayment: return "Awaiting payment"
    // Kitchen has the order as soon as payment clears — don't surface a separate "Paid" state.
    case .paid, .preparing: return "Preparing"
    case .ready: return "Ready to collect"
    case .collected: return "Collected"
    case .cancelled: return "Cancelled"
    }
  }

  /// Active kitchen / pickup orders shown in the Orders tab (never unpaid).
  var isActive: Bool {
    switch self {
    case .paid, .preparing, .ready: return true
    case .pendingPayment, .collected, .cancelled: return false
    }
  }

  /// Unpaid checkout drafts are hidden from Orders entirely.
  var showsInOrders: Bool {
    self != .pendingPayment
  }
}

struct FanOrder: Decodable, Identifiable {
  struct Line: Decodable {
    struct Picked: Decodable { let title: String }

    let title: String
    let quantity: Int
    let options: [Picked]

    enum CodingKeys: String, CodingKey {
      case title = "title_snapshot"
      case quantity
      case options = "options_snapshot"
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      title = try c.decode(String.self, forKey: .title)
      quantity = try c.decode(Int.self, forKey: .quantity)
      options = try c.decodeIfPresent([Picked].self, forKey: .options) ?? []
    }

    var displayTitle: String {
      options.isEmpty ? title : "\(title) (\(options.map(\.title).joined(separator: ", ")))"
    }
  }

  struct VenueRef: Decodable { let name: String }

  struct CollectionRef: Decodable {
    let name: String
    let floorLabel: String
    let blockLabel: String

    enum CodingKeys: String, CodingKey {
      case name
      case floorLabel = "floor_label"
      case blockLabel = "block_label"
    }

    var label: String { "\(name) - \(floorLabel), \(blockLabel)" }
  }

  let id: UUID
  let status: OrderStatus
  let totalCents: Int
  let currency: String
  let createdAt: Date
  let orderedForHalftime: Bool
  let pickupAt: Date?
  let fulfillmentType: FulfillmentType
  let paymentMode: PaymentMode
  let partySize: Int?
  let seatRow: String?
  let seatNumber: String?
  let venue: VenueRef?
  let collectionPoint: CollectionRef?
  let items: [Line]

  enum CodingKeys: String, CodingKey {
    case id
    case status
    case totalCents = "total_cents"
    case currency
    case createdAt = "created_at"
    case orderedForHalftime = "ordered_for_halftime"
    case pickupAt = "pickup_at"
    case fulfillmentType = "fulfillment_type"
    case paymentMode = "payment_mode"
    case partySize = "party_size"
    case seatRow = "seat_row"
    case seatNumber = "seat_number"
    case venue = "venues"
    case collectionPoint = "collection_points"
    case items = "order_items"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    status = try c.decode(OrderStatus.self, forKey: .status)
    totalCents = try c.decode(Int.self, forKey: .totalCents)
    currency = try c.decode(String.self, forKey: .currency)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    orderedForHalftime = try c.decodeIfPresent(Bool.self, forKey: .orderedForHalftime) ?? false
    pickupAt = try c.decodeIfPresent(Date.self, forKey: .pickupAt)
    fulfillmentType = try c.decodeIfPresent(FulfillmentType.self, forKey: .fulfillmentType) ?? .collection
    paymentMode = try c.decodeIfPresent(PaymentMode.self, forKey: .paymentMode) ?? .stripe
    partySize = try c.decodeIfPresent(Int.self, forKey: .partySize)
    seatRow = try c.decodeIfPresent(String.self, forKey: .seatRow)
    seatNumber = try c.decodeIfPresent(String.self, forKey: .seatNumber)
    venue = try c.decodeIfPresent(VenueRef.self, forKey: .venue)
    collectionPoint = try c.decodeIfPresent(CollectionRef.self, forKey: .collectionPoint)
    items = try c.decodeIfPresent([Line].self, forKey: .items) ?? []
  }

  var summary: String {
    items.map { "\($0.quantity) × \($0.displayTitle)" }.joined(separator: ", ")
  }

  /// "Row A · Seat 12" when this is a seat-delivery order.
  var seatLabel: String? {
    guard fulfillmentType == .seatDelivery,
      let row = seatRow?.trimmingCharacters(in: .whitespacesAndNewlines), !row.isEmpty,
      let seat = seatNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !seat.isEmpty
    else { return nil }
    return "Row \(row) · Seat \(seat)"
  }
}

struct CreatedOrder: Decodable {
  let id: UUID
  let status: OrderStatus
  let totalCents: Int
  let currency: String

  enum CodingKeys: String, CodingKey {
    case id
    case status
    case totalCents = "total_cents"
    case currency
  }
}

/// Server-calculated prices for a basket (promo code included).
struct PricePreview: Decodable {
  let subtotalCents: Int
  let discountCents: Int
  let serviceFeeCents: Int
  let totalCents: Int
  let currency: String
  let promoCode: String?

  enum CodingKeys: String, CodingKey {
    case subtotalCents = "subtotal_cents"
    case discountCents = "discount_cents"
    case serviceFeeCents = "service_fee_cents"
    case totalCents = "total_cents"
    case currency
    case promoCode = "promo_code"
  }
}

struct ImageCredit: Decodable, Identifiable {
  let imageKey: String
  let title: String
  let author: String
  let license: String
  let licenseURL: String?
  let sourceURL: String

  var id: String { imageKey }

  enum CodingKeys: String, CodingKey {
    case imageKey = "image_key"
    case title, author, license
    case licenseURL = "license_url"
    case sourceURL = "source_url"
  }
}

struct CheckoutSessionInfo: Decodable {
  let orderID: UUID
  let status: String
  let checkoutURL: String?

  enum CodingKeys: String, CodingKey {
    case orderID = "order_id"
    case status
    case checkoutURL = "checkout_url"
  }
}

// MARK: - Rewards

struct RewardWallet: Codable {
  let availablePoints: Int
  let upcomingPoints: Int
  let expiredPoints: Int

  static let empty = RewardWallet(availablePoints: 0, upcomingPoints: 0, expiredPoints: 0)

  enum CodingKeys: String, CodingKey {
    case availablePoints = "available_points"
    case upcomingPoints = "upcoming_points"
    case expiredPoints = "expired_points"
  }
}
