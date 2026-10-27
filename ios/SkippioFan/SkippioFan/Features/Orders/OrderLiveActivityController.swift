import ActivityKit
import Foundation

/// Starts and updates the Lock Screen / Dynamic Island Live Activity for an order.
/// Dine-in reservations never use Live Activities (email confirmation instead).
@MainActor
enum OrderLiveActivityController {
  static func start(
    orderID: UUID,
    venueName: String,
    itemSummary: String,
    status: OrderStatus,
    isSeatDelivery: Bool = false,
    seatLabel: String? = nil
  ) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

    let attributes = OrderActivityAttributes(
      orderID: orderID.uuidString,
      venueName: venueName,
      itemSummary: itemSummary,
      isSeatDelivery: isSeatDelivery,
      seatLabel: seatLabel
    )
    let state = OrderActivityTiming.content(
      statusRaw: status.rawValue,
      itemSummary: itemSummary,
      isSeatDelivery: isSeatDelivery,
      seatLabel: seatLabel
    )

    let content = ActivityContent(state: state, staleDate: nil)
    for activity in Activity<OrderActivityAttributes>.activities where activity.attributes.orderID == orderID.uuidString {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    do {
      _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
    } catch {
      print("Live Activity start failed: \(error.localizedDescription)")
    }
  }

  static func end(orderID: UUID) {
    for activity in Activity<OrderActivityAttributes>.activities where activity.attributes.orderID == orderID.uuidString {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }

  static func sync(orders: [FanOrder]) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

    for order in orders where order.status.isActive && order.fulfillmentType != .dineIn {
      let isSeat = order.fulfillmentType == .seatDelivery
      let state = OrderActivityTiming.content(
        statusRaw: order.status.rawValue,
        itemSummary: order.summary,
        isSeatDelivery: isSeat,
        seatLabel: order.seatLabel
      )
      let content = ActivityContent(state: state, staleDate: nil)

      if let activity = Activity<OrderActivityAttributes>.activities.first(where: { $0.attributes.orderID == order.id.uuidString }) {
        Task { await activity.update(content) }
      } else if order.status == .paid || order.status == .preparing || order.status == .ready {
        start(
          orderID: order.id,
          venueName: order.venue?.name ?? "Skippio",
          itemSummary: order.summary,
          status: order.status,
          isSeatDelivery: isSeat,
          seatLabel: order.seatLabel
        )
      }
    }

    // End activities for orders that are no longer active, or that are dine-in.
    let liveIDs = Set(
      orders
        .filter { $0.status.isActive && $0.fulfillmentType != .dineIn }
        .map { $0.id.uuidString }
    )
    for activity in Activity<OrderActivityAttributes>.activities where !liveIDs.contains(activity.attributes.orderID) {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
