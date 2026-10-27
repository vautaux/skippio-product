import SwiftUI

struct OrdersView: View {
  @EnvironmentObject private var auth: AuthStore
  @EnvironmentObject private var chrome: AppChrome

  @State private var orders: [FanOrder] = []
  @State private var hasLoaded = false
  @State private var errorMessage: String?
  @State private var notice: String?
  @State private var collectingOrderID: UUID?
  @State private var orderAwaitingCollectConfirm: FanOrder?
  @State private var orderToModify: FanOrder?
  @State private var isModifyingReservation = false
  @State private var selectedTab = 0

  private let repository = OrdersRepository()

  var body: some View {
    ZStack {
      AppColors.background.ignoresSafeArea()
      VStack(alignment: .leading, spacing: 12) {
        Text("Orders")
          .font(.app(size: 24, weight: .heavy))
          .foregroundStyle(AppColors.text)
          .padding(.top, 12)

        HStack(spacing: 8) {
          segmentPill(title: "Active", tag: 0)
          segmentPill(title: "Past", tag: 1)
          Spacer()
        }
        .padding(.bottom, 4)

        if let notice {
          Text(notice)
            .font(.app(size: 14, weight: .medium))
            .foregroundStyle(AppColors.text)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.primaryLight.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        if !hasLoaded && errorMessage == nil {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let errorMessage, orders.isEmpty {
          VStack(spacing: 10) {
            Text("Could not load orders")
              .font(.app(size: 18, weight: .heavy))
              .foregroundStyle(AppColors.text)
            Text(errorMessage)
              .font(.app(size: 15))
              .foregroundStyle(AppColors.text)
              .multilineTextAlignment(.center)
            pillButton("Try again") { Task { await load() } }
              .padding(.top, 8)
          }
          .padding(.horizontal, 24)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(.bottom, 90)
        } else if filteredOrders.isEmpty {
          emptyState
        } else {
          ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
              ForEach(filteredOrders) { order in
                orderCard(order)
              }
            }
            .padding(.top, 4)
            .padding(.bottom, AppSpacing.tabBarClearance)
          }
          .refreshable { await load() }
        }
      }
      .padding(.horizontal, AppSpacing.screenHorizontal)
    }
    .toolbar(.hidden, for: .navigationBar)
    // Runs each time the tab appears; keeps refreshing while something is in progress.
    .onAppear {
      chrome.isTabBarHidden = false
      selectedTab = 0
    }
    .alert(
      "Collected?",
      isPresented: Binding(
        get: { orderAwaitingCollectConfirm != nil },
        set: { if !$0 { orderAwaitingCollectConfirm = nil } }
      )
    ) {
      Button("Yes") {
        if let order = orderAwaitingCollectConfirm {
          Task { await collect(order) }
        }
        orderAwaitingCollectConfirm = nil
      }
      Button("Not yet", role: .cancel) {
        orderAwaitingCollectConfirm = nil
      }
    } message: {
      Text("This moves the order to Past and clears any Live Activity for it.")
    }
    .sheet(item: $orderToModify) { order in
      DineInReservationSheet(
        venueTitle: order.venue?.name ?? "Restaurant",
        initialPartySize: order.partySize ?? 2,
        initialReservation: order.pickupAt,
        confirmTitle: "Save",
        navigationTitleText: "Modify reservation"
      ) { partySize, when in
        Task { await saveReservation(order: order, partySize: partySize, when: when) }
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    }
    .task(id: auth.user?.id) {
      await load()
      while !Task.isCancelled {
        let interval: UInt64 = orders.contains { $0.status.isActive && $0.status != .pendingPayment } ? 4 : 30
        try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
        if Task.isCancelled { break }
        await load()
      }
    }
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack {
      Spacer()
      VStack(spacing: 10) {
        Text(selectedTab == 0 ? "You have no active orders" : "You have no past orders")
          .font(.app(size: 18, weight: .heavy))
          .foregroundStyle(AppColors.text)
          .multilineTextAlignment(.center)
        Text(selectedTab == 0
          ? "When you have active orders,\nthey'll show up here"
          : "Your completed orders\nwill show up here")
          .multilineTextAlignment(.center)
          .foregroundStyle(AppColors.text)
          .font(.app(size: 15, weight: .regular))

        pillButton("Discover available options") {
          chrome.selectedTab = .home
        }
        .padding(.top, 18)
      }
      .padding(.horizontal, 24)
      // Optically centre above the floating tab bar.
      .padding(.bottom, 90)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.app(size: 15, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 29)
        .frame(height: 46)
        .background(AppColors.primary)
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Cards

  private func orderCard(_ order: FanOrder) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(order.venue?.name ?? "Order")
            .font(.app(size: 17, weight: .bold))
            .foregroundStyle(AppColors.text)
          Text(order.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.app(size: 13))
            .foregroundStyle(AppColors.mutedText)
        }
        Spacer()
        statusBadge(order.status)
      }

      Text(order.summary)
        .font(.app(size: 14))
        .foregroundStyle(AppColors.text)
        .fixedSize(horizontal: false, vertical: true)

      if order.fulfillmentType == .seatDelivery, let seat = order.seatLabel {
        let suffix = order.orderedForHalftime ? " · half-time" : ""
        Label("Deliver · \(seat)\(suffix)", systemImage: "ticket.fill")
          .font(.app(size: 13, weight: .semibold))
          .foregroundStyle(AppColors.mutedText)
        if let collection = order.collectionPoint {
          Label("From \(collection.label)", systemImage: "mappin.and.ellipse")
            .font(.app(size: 13))
            .foregroundStyle(AppColors.mutedText)
        }
      } else if let collection = order.collectionPoint {
        Label(order.orderedForHalftime ? "\(collection.label) · half-time" : collection.label, systemImage: "mappin.and.ellipse")
          .font(.app(size: 13))
          .foregroundStyle(AppColors.mutedText)
      }

      if order.fulfillmentType == .dineIn {
        if let party = order.partySize {
          Label("\(party) guests · dine in", systemImage: "fork.knife")
            .font(.app(size: 13, weight: .semibold))
            .foregroundStyle(AppColors.mutedText)
        }
        if order.paymentMode == .atVenue {
          Label("Pay at restaurant", systemImage: "sterlingsign.circle")
            .font(.app(size: 13, weight: .semibold))
            .foregroundStyle(AppColors.primary)
        }
      }

      if let pickupAt = order.pickupAt {
        Label(
          order.fulfillmentType == .dineIn
            ? "Reservation \(pickupAt.formatted(date: .abbreviated, time: .shortened))"
            : "Collect \(pickupAt.formatted(date: .abbreviated, time: .shortened))",
          systemImage: "clock"
        )
          .font(.app(size: 13, weight: .semibold))
          .foregroundStyle(AppColors.mutedText)
      }

      if order.fulfillmentType != .dineIn, order.status == .paid || order.status == .preparing {
        let readyAt = OrderActivityTiming.estimatedReadyAt(orderID: order.id, createdAt: order.createdAt)
        let readyCopy = order.fulfillmentType == .seatDelivery
          ? "At your seat around \(readyAt.formatted(date: .omitted, time: .shortened))"
          : "Ready around \(readyAt.formatted(date: .omitted, time: .shortened))"
        Label(readyCopy, systemImage: "cup.and.saucer.fill")
          .font(.app(size: 13, weight: .semibold))
          .foregroundStyle(AppColors.primary)
      }

      if order.status.isActive, order.fulfillmentType == .dineIn {
        Button {
          orderToModify = order
        } label: {
          Text("Modify reservation")
            .font(.app(size: 14, weight: .bold))
            .foregroundStyle(AppColors.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(AppColors.primaryLight.opacity(0.55))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isModifyingReservation || collectingOrderID != nil)
        .accessibilityIdentifier("modify-reservation")
      }

      HStack(alignment: .center) {
        Text(Money.format(cents: order.totalCents, currency: order.currency))
          .font(.app(size: 17, weight: .heavy))
          .foregroundStyle(AppColors.text)
        Spacer(minLength: 12)
        if order.status.isActive {
          Button {
            orderAwaitingCollectConfirm = order
          } label: {
            ZStack {
              if collectingOrderID == order.id {
                ProgressView().tint(.white)
              } else {
                Text("Collected?")
                  .font(.app(size: 14, weight: .bold))
              }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(AppColors.openGreen)
            .clipShape(Capsule())
          }
          .buttonStyle(.plain)
          .disabled(collectingOrderID != nil || isModifyingReservation)
          .accessibilityIdentifier("collect-button")
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .appCardStyle(radius: 20)
  }

  private func statusBadge(_ status: OrderStatus) -> some View {
    let (foreground, background): (Color, Color) = {
      switch status {
      case .ready: return (AppColors.openGreen, AppColors.openGreenBackground)
      case .cancelled: return (AppColors.closedRed, AppColors.closedRedBackground)
      case .collected: return (AppColors.mutedText, AppColors.chipFill)
      case .paid, .preparing: return (AppColors.text, AppColors.primaryLight.opacity(0.7))
      case .pendingPayment: return (AppColors.mutedText, AppColors.chipFill)
      }
    }()

    return Text(status.label)
      .font(.app(size: 12, weight: .bold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(background)
      .clipShape(Capsule())
  }

  private func segmentPill(title: String, tag: Int) -> some View {
    let active = selectedTab == tag
    return Button {
      selectedTab = tag
    } label: {
      Text(title)
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(active ? Color.white : AppColors.mutedText)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(active ? AppColors.primary : AppColors.card)
        .clipShape(Capsule())
        .overlay(
          Capsule().stroke(active ? Color.clear : AppColors.border, lineWidth: 0.5)
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Data

  private var filteredOrders: [FanOrder] {
    orders
      .filter(\.status.showsInOrders)
      .filter { selectedTab == 0 ? $0.status.isActive : !$0.status.isActive }
  }

  private func load() async {
    _ = await repository.tickProgress()
    do {
      orders = try await repository.fetchOrders()
      errorMessage = nil
      OrderLiveActivityController.sync(orders: orders)
    } catch {
      // Keep showing what we have if a background refresh fails.
      if orders.isEmpty { errorMessage = error.localizedDescription }
    }
    hasLoaded = true
  }

  private func collect(_ order: FanOrder) async {
    collectingOrderID = order.id
    notice = nil
    do {
      try await repository.markCollected(orderID: order.id)
      OrderLiveActivityController.end(orderID: order.id)
      notice = "Marked as collected. Thanks!"
    } catch {
      notice = error.localizedDescription
    }
    collectingOrderID = nil
    await load()
  }

  private func saveReservation(order: FanOrder, partySize: Int, when: Date) async {
    isModifyingReservation = true
    notice = nil
    do {
      try await repository.modifyReservation(orderID: order.id, partySize: partySize, pickupAt: when)
      orderToModify = nil
      notice = "Reservation updated. A confirmation email is on its way."
      await load()
    } catch {
      notice = error.localizedDescription
    }
    isModifyingReservation = false
  }
}
