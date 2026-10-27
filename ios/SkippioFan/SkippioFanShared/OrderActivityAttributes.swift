import ActivityKit
import Foundation

/// Shared between the app and the Live Activity widget extension.
struct OrderActivityAttributes: ActivityAttributes {
  /// Values that change as the kitchen progresses.
  public struct ContentState: Codable, Hashable {
    var statusRaw: String
    var statusLabel: String
    var detail: String
  }

  var orderID: String
  var venueName: String
  var itemSummary: String
  var isSeatDelivery: Bool
  var seatLabel: String?
}

enum OrderActivityTiming {
  /// Deterministic 5–10 minutes, matching the edge function (Orders ETA copy only).
  static func readyAfter(orderID: UUID) -> TimeInterval {
    var hash: UInt32 = 0
    for byte in orderID.uuidString.utf8 {
      hash = hash &* 31 &+ UInt32(byte)
    }
    let minutes = 5 + Int(hash % 6)
    return TimeInterval(minutes * 60)
  }

  static func estimatedReadyAt(orderID: UUID, createdAt: Date = Date()) -> Date {
    createdAt.addingTimeInterval(readyAfter(orderID: orderID))
  }

  static func content(
    statusRaw: String,
    itemSummary: String,
    isSeatDelivery: Bool = false,
    seatLabel: String? = nil
  ) -> OrderActivityAttributes.ContentState {
    let items = itemSummary.isEmpty ? "Your order" : itemSummary
    let seat = seatLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label: String
    let detail: String
    switch statusRaw {
    case "ready":
      label = "Ready"
      if isSeatDelivery {
        detail = (seat?.isEmpty == false) ? "Deliver \(seat!)" : "On the way to your seat"
      } else {
        detail = "Collect \(items)"
      }
    case "preparing":
      label = "Preparing"
      if isSeatDelivery, let seat, !seat.isEmpty {
        detail = seat
      } else {
        detail = items
      }
    case "paid":
      label = "Received"
      if isSeatDelivery, let seat, !seat.isEmpty {
        detail = seat
      } else {
        detail = items
      }
    default:
      label = statusRaw.capitalized
      detail = items
    }
    return .init(statusRaw: statusRaw, statusLabel: label, detail: detail)
  }
}
