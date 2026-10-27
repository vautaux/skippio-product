import SwiftUI

/// "Your order": one venue's basket. Paying creates the order on the server, then hands off
/// to Stripe Checkout; the order only becomes "paid" when Stripe's webhook says so.
struct CartView: View {
  let venue: Venue
  /// Called after payment succeeds (or is confirmed shortly), so the caller can
  /// close the menu and move to the Orders tab.
  let onOrderPlaced: () -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var cart: CartStore
  @EnvironmentObject private var chrome: AppChrome
  @StateObject private var checkout = CheckoutCoordinator()

  @State private var isCreatingOrder = false
  @State private var errorMessage: String?
  @State private var preview: PricePreview?
  @State private var showSlotPicker = false
  @State private var showPromo = false
  @State private var promoInput = ""
  @State private var promoError: String?
  @State private var isCheckingPromo = false

  private let service = CheckoutService()
  private let termsURL = URL(string: "https://www.skippio.io")!

  private var basket: Basket? { cart.basket(for: venue) }
  private var isBusy: Bool { isCreatingOrder || checkout.isWorking }

  var body: some View {
    ZStack {
      Color.white.ignoresSafeArea()

      if let basket {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 18) {
            title
            sectionLabel(for: basket)
            linesCard(basket)
            if basket.fulfillmentType == .dineIn {
              dineInSummary(basket)
              dineInPaymentChoice(basket)
            } else if venue.kind == .venue {
              venueFulfillmentSection(basket)
              if basket.fulfillmentType == .seatDelivery {
                seatFields(basket)
              }
              halftimeCard(basket)
            } else {
              // Cafés and restaurant takeout / pickup.
              timeSlotSection(basket)
            }
            promoSection(basket)
            totalsCard(basket)

            if let errorMessage {
              Text(errorMessage)
                .font(.app(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.closedRed)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 8)
          .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
      } else {
        VStack(spacing: 8) {
          Text("Your basket is empty")
            .font(.app(size: 19, weight: .heavy))
            .foregroundStyle(AppColors.text)
          Text("Add something from the menu to get started.")
            .font(.app(size: 15))
            .foregroundStyle(AppColors.mutedText)
        }
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    // The menu hands over to this screen; keep the tab bar out of the way of "Pay".
    .onAppear {
      guard chrome.selectedTab == .home else { return }
      chrome.isTabBarHidden = true
    }
    .onDisappear {
      // Back to menu: menu keeps the bar hidden. Pay → Orders (or any other tab): show it.
      if chrome.selectedTab != .home {
        chrome.isTabBarHidden = false
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { topBar }
    .safeAreaInset(edge: .bottom, spacing: 0) { payBar }
    .task(id: basket?.idempotencyKey) { await refreshPreview() }
    .sheet(isPresented: $showSlotPicker) {
      if let basket { SlotPicker(selected: basket.pickupAt) { cart.setPickup($0, venueID: venue.id) } }
    }
    .sheet(isPresented: $showPromo) { promoSheet }
  }

  // MARK: - Header

  private var topBar: some View {
    HStack {
      Button { dismiss() } label: {
        Circle()
          .fill(AppColors.chipFill.opacity(0.7))
          .frame(width: 40, height: 40)
          .overlay(
            Image(systemName: "chevron.left")
              .font(.app(size: 15, weight: .bold))
              .foregroundStyle(AppColors.text)
          )
      }
      .buttonStyle(.plain)
      // Always allow leaving — Pay used to lock Back while waiting on Stripe/webhook.
      .accessibilityLabel("Back")
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.white)
  }

  private var title: some View {
    Text("Your order")
      .font(.app(size: 32, weight: .heavy))
      .foregroundStyle(AppColors.text)
  }

  private func sectionLabel(for basket: Basket) -> some View {
    Text("\(venue.displayTitle.uppercased()) \u{00B7} \(basket.itemCount) ITEM\(basket.itemCount == 1 ? "" : "S")")
      .font(.app(size: 13, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(AppColors.mutedText)
  }

  // MARK: - Lines

  private func linesCard(_ basket: Basket) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(basket.lines.enumerated()), id: \.element.id) { index, line in
        if index > 0 { Divider().padding(.leading, 84) }
        HStack(spacing: 14) {
          ItemPhoto(url: line.item.imageURL)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          VStack(alignment: .leading, spacing: 3) {
            Text(line.item.title)
              .font(.app(size: 17, weight: .bold))
              .foregroundStyle(AppColors.text)
              .lineLimit(2)
            if let label = line.optionsLabel {
              Text(label)
                .font(.app(size: 13))
                .foregroundStyle(AppColors.mutedText)
                .lineLimit(2)
            }
            Text(Money.format(cents: line.totalCents, currency: line.item.currency))
              .font(.app(size: 15, weight: .semibold))
              .foregroundStyle(AppColors.text)
          }

          Spacer(minLength: 6)
          stepper(for: line)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
      }
    }
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppColors.border, lineWidth: 1))
    .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    .disabled(isBusy)
  }

  private func stepper(for line: CartLine) -> some View {
    HStack(spacing: 10) {
      Button { cart.decrement(lineID: line.id, venueID: venue.id) } label: {
        Image(systemName: line.quantity == 1 ? "trash" : "minus")
          .font(.app(size: 13, weight: .bold))
          .foregroundStyle(AppColors.primary)
          .frame(width: 32, height: 32)
          .background(AppColors.primaryLight.opacity(0.7))
          .clipShape(Circle())
      }
      .accessibilityLabel(line.quantity == 1 ? "Remove \(line.item.title)" : "Remove one \(line.item.title)")

      Text("\(line.quantity)")
        .font(.app(size: 16, weight: .bold))
        .foregroundStyle(AppColors.text)
        .frame(minWidth: 18)

      Button { cart.increment(lineID: line.id, venueID: venue.id) } label: {
        Image(systemName: "plus")
          .font(.app(size: 13, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 32, height: 32)
          .background(AppColors.primary)
          .clipShape(Circle())
      }
      .disabled(line.quantity >= CartStore.maxPerItem)
      .accessibilityLabel("Add one \(line.item.title)")
    }
    .buttonStyle(.plain)
  }

  // MARK: - Time slot / half-time

  private func timeSlotSection(_ basket: Basket) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(basket.fulfillmentType == .takeout ? "When do you want to pick up?" : "Select a time slot")
        .font(.app(size: 19, weight: .heavy))
        .foregroundStyle(AppColors.text)

      HStack(spacing: 10) {
        slotChoice(
          title: "ASAP",
          detail: venue.kind == .cafe || basket.fulfillmentType == .takeout
            ? "Ready in about 5-10 min"
            : "As soon as possible",
          isOn: basket.pickupAt == nil
        ) { cart.setPickup(nil, venueID: venue.id) }

        slotChoice(
          title: "Order for later",
          detail: basket.pickupAt.map(Self.slotLabel) ?? "Choose a time",
          isOn: basket.pickupAt != nil
        ) { showSlotPicker = true }
      }
    }
    .disabled(isBusy)
  }

  private func slotChoice(title: String, detail: String, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.app(size: 16, weight: .bold))
          .foregroundStyle(AppColors.text)
        Text(detail)
          .font(.app(size: 13))
          .foregroundStyle(AppColors.mutedText)
          .lineLimit(1)
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
      .background(isOn ? AppColors.primaryLight.opacity(0.45) : Color.white)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(isOn ? AppColors.primary : AppColors.border, lineWidth: isOn ? 1.5 : 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  static func slotLabel(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }

  private func venueFulfillmentSection(_ basket: Basket) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("How should we get it to you?")
        .font(.app(size: 17, weight: .bold))
        .foregroundStyle(AppColors.text)

      HStack(spacing: 10) {
        venueModeChip(
          title: "Collect",
          subtitle: "Pick up at the stand",
          selected: basket.fulfillmentType != .seatDelivery
        ) {
          cart.setFulfillment(.collection, venueID: venue.id)
        }
        venueModeChip(
          title: "Deliver",
          subtitle: "To your seat",
          selected: basket.fulfillmentType == .seatDelivery
        ) {
          cart.setFulfillment(.seatDelivery, venueID: venue.id)
        }
      }
    }
  }

  private func venueModeChip(
    title: String,
    subtitle: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.app(size: 16, weight: .bold))
          .foregroundStyle(AppColors.text)
        Text(subtitle)
          .font(.app(size: 13))
          .foregroundStyle(AppColors.mutedText)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(selected ? AppColors.primaryLight.opacity(0.55) : AppColors.card)
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(selected ? AppColors.primary : AppColors.border, lineWidth: selected ? 1.5 : 0.5)
      )
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
  }

  private func seatFields(_ basket: Basket) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Where are you sitting?")
        .font(.app(size: 17, weight: .bold))
        .foregroundStyle(AppColors.text)

      HStack(spacing: 12) {
        seatField(
          title: "Row",
          text: Binding(
            get: { basket.seatRow },
            set: { cart.setSeatRow($0, venueID: venue.id) }
          ),
          id: "seat-row"
        )
        seatField(
          title: "Seat",
          text: Binding(
            get: { basket.seatNumber },
            set: { cart.setSeatNumber($0, venueID: venue.id) }
          ),
          id: "seat-number"
        )
      }
    }
    .padding(16)
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppColors.border, lineWidth: 1))
  }

  private func seatField(title: String, text: Binding<String>, id: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.app(size: 13, weight: .semibold))
        .foregroundStyle(AppColors.mutedText)
      TextField(title, text: text)
        .font(.app(size: 18, weight: .semibold))
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(AppColors.chipFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(isBusy)
        .accessibilityIdentifier(id)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func halftimeCard(_ basket: Basket) -> some View {
    Toggle(
      isOn: Binding(
        get: { basket.orderedForHalftime },
        set: { cart.setHalftime($0, venueID: venue.id) }
      )
    ) {
      VStack(alignment: .leading, spacing: 3) {
        Text(basket.fulfillmentType == .seatDelivery
          ? "Deliver at half-time"
          : "Order for half-time")
          .font(.app(size: 17, weight: .bold))
          .foregroundStyle(AppColors.text)
        Text(basket.fulfillmentType == .seatDelivery
          ? "We’ll bring it to your seat at the break."
          : "Let the bar know to have it ready at the break.")
          .font(.app(size: 13))
          .foregroundStyle(AppColors.mutedText)
      }
    }
    .tint(AppColors.primary)
    .padding(16)
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppColors.border, lineWidth: 1))
    .disabled(isBusy)
  }

  // MARK: - Promo

  private func promoSection(_ basket: Basket) -> some View {
    HStack {
      if let code = basket.promoCode {
        HStack(spacing: 8) {
          Image(systemName: "tag.fill").foregroundStyle(AppColors.primary)
          Text(code)
            .font(.app(size: 16, weight: .bold))
            .foregroundStyle(AppColors.text)
          Text("applied")
            .font(.app(size: 14))
            .foregroundStyle(AppColors.mutedText)
        }
        Spacer()
        Button("Remove") {
          cart.setPromoCode(nil, venueID: venue.id)
          preview = nil
        }
        .font(.app(size: 15, weight: .semibold))
        .foregroundStyle(AppColors.primary)
        .disabled(isBusy)
      } else {
        Button {
          promoInput = ""
          promoError = nil
          showPromo = true
        } label: {
          Text("Have a promo code?")
            .font(.app(size: 16, weight: .semibold))
            .foregroundStyle(AppColors.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("promo-link")
        Spacer()
      }
    }
  }

  private var promoSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Promo code")
        .font(.app(size: 24, weight: .heavy))
        .foregroundStyle(AppColors.text)
        .padding(.top, 24)

      TextField("Enter your code", text: $promoInput)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .font(.app(size: 18, weight: .semibold))
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(AppColors.chipFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("promo-field")

      if let promoError {
        Text(promoError)
          .font(.app(size: 14, weight: .semibold))
          .foregroundStyle(AppColors.closedRed)
      }

      Button {
        Task { await applyPromo() }
      } label: {
        ZStack {
          if isCheckingPromo { ProgressView().tint(.white) } else {
            Text("Apply")
              .font(.app(size: 18, weight: .bold))
          }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .background(promoInput.trimmingCharacters(in: .whitespaces).isEmpty ? AppColors.primary.opacity(0.4) : AppColors.primary)
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .disabled(promoInput.trimmingCharacters(in: .whitespaces).isEmpty || isCheckingPromo)
      .accessibilityIdentifier("promo-apply")

      Spacer()
    }
    .padding(.horizontal, 20)
    .background(Color.white.ignoresSafeArea())
    .presentationDetents([.height(320)])
  }

  private func applyPromo() async {
    guard var candidate = basket else { return }
    candidate.promoCode = promoInput.trimmingCharacters(in: .whitespaces).uppercased()
    isCheckingPromo = true
    promoError = nil
    defer { isCheckingPromo = false }
    do {
      let result = try await service.preview(basket: candidate)
      cart.setPromoCode(result.promoCode ?? candidate.promoCode, venueID: venue.id)
      preview = result
      showPromo = false
    } catch {
      promoError = error.localizedDescription
    }
  }

  /// Keeps the totals in step with the server whenever the basket (or promo) changes.
  private func refreshPreview() async {
    guard let basket, basket.promoCode != nil else {
      preview = nil
      return
    }
    do {
      preview = try await service.preview(basket: basket)
    } catch {
      // The code stopped being valid (or the network failed): fall back to full price.
      cart.setPromoCode(nil, venueID: venue.id)
      preview = nil
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Totals

  private struct Amounts {
    let subtotal: Int
    let discount: Int
    let fee: Int
    let total: Int
  }

  private func amounts(_ basket: Basket) -> Amounts {
    if basket.promoCode != nil, let preview {
      return Amounts(
        subtotal: preview.subtotalCents,
        discount: preview.discountCents,
        fee: preview.serviceFeeCents,
        total: preview.totalCents
      )
    }
    return Amounts(subtotal: basket.subtotalCents, discount: 0, fee: basket.serviceFeeCents, total: basket.totalCents)
  }

  private func totalsCard(_ basket: Basket) -> some View {
    let a = amounts(basket)
    return VStack(spacing: 10) {
      totalRow("Subtotal", cents: a.subtotal, currency: basket.currency)
      if a.discount > 0 {
        totalRow("Promo \(basket.promoCode ?? "")", cents: -a.discount, currency: basket.currency, tint: AppColors.openGreen)
      }
      totalRow("Service fee (7.5%)", cents: a.fee, currency: basket.currency)
      Divider()
      totalRow("Total", cents: a.total, currency: basket.currency, bold: true)
    }
    .padding(16)
    .background(AppColors.backgroundSoft.opacity(0.7))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func totalRow(_ title: String, cents: Int, currency: String, bold: Bool = false, tint: Color? = nil) -> some View {
    HStack {
      Text(title)
        .font(.app(size: bold ? 18 : 16, weight: bold ? .heavy : .regular))
      Spacer()
      Text((cents < 0 ? "\u{2212}" : "") + Money.format(cents: abs(cents), currency: currency))
        .font(.app(size: bold ? 18 : 16, weight: bold ? .heavy : .semibold))
    }
    .foregroundStyle(tint ?? AppColors.text)
  }

  // MARK: - Dine-in

  private func dineInSummary(_ basket: Basket) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Reservation")
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(AppColors.mutedText)

      Label("\(basket.partySize ?? 2) guest\((basket.partySize ?? 2) == 1 ? "" : "s")", systemImage: "person.2.fill")
        .font(.app(size: 16, weight: .semibold))
        .foregroundStyle(AppColors.text)

      if let when = basket.pickupAt {
        Label(when.formatted(date: .complete, time: .omitted), systemImage: "calendar")
          .font(.app(size: 16, weight: .semibold))
          .foregroundStyle(AppColors.text)
        Label(when.formatted(date: .omitted, time: .shortened), systemImage: "clock")
          .font(.app(size: 16, weight: .semibold))
          .foregroundStyle(AppColors.text)
      }

      Text("Food will be ready when you arrive.")
        .font(.app(size: 14))
        .foregroundStyle(AppColors.mutedText)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppColors.chipFill.opacity(0.5))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func dineInPaymentChoice(_ basket: Basket) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Payment")
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(AppColors.mutedText)
      paymentChoiceRow(
        title: "Pay now",
        detail: "Card via Stripe",
        selected: basket.paymentMode == .stripe
      ) { cart.setPaymentMode(.stripe, venueID: venue.id) }
      paymentChoiceRow(
        title: "Pay at restaurant",
        detail: "Settle when you arrive",
        selected: basket.paymentMode == .atVenue
      ) { cart.setPaymentMode(.atVenue, venueID: venue.id) }
    }
  }

  private func paymentChoiceRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.app(size: 17, weight: .bold)).foregroundStyle(AppColors.text)
          Text(detail).font(.app(size: 14)).foregroundStyle(AppColors.mutedText)
        }
        Spacer()
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? AppColors.primary : AppColors.mutedText)
          .font(.app(size: 22))
      }
      .padding(14)
      .background(selected ? AppColors.primaryLight.opacity(0.55) : AppColors.card)
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(selected ? AppColors.primary : AppColors.border, lineWidth: selected ? 1.5 : 0.5)
      )
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  // MARK: - Pay

  @ViewBuilder
  private var payBar: some View {
    if let basket {
      let atVenue = basket.fulfillmentType == .dineIn && basket.paymentMode == .atVenue
      let seatIncomplete = basket.fulfillmentType == .seatDelivery && !basket.hasValidSeat
      VStack(spacing: 8) {
        Button {
          Task { await pay() }
        } label: {
          ZStack {
            if isBusy {
              ProgressView().tint(.white)
            } else if atVenue {
              Text("Confirm reservation")
                .font(.app(size: 20, weight: .bold))
            } else {
              Text("Pay \(Money.format(cents: amounts(basket).total, currency: basket.currency))")
                .font(.app(size: 20, weight: .bold))
            }
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 60)
          .background(AppColors.primary.opacity(seatIncomplete ? 0.45 : 1))
          .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || seatIncomplete)
        .accessibilityIdentifier("pay-button")

        Text(atVenue
          ? "Your table and food will be ready at the reservation time. Pay at the restaurant."
          : "By placing your order you agree to our [Terms of Use](https://www.skippio.io) and [Privacy Policy](https://www.skippio.io). Secure payment by Stripe.")
          .font(.app(size: 12))
          .foregroundStyle(AppColors.mutedText)
          .multilineTextAlignment(.center)
          .tint(AppColors.primary)
      }
      .padding(.horizontal, 20)
      .padding(.top, 10)
      .padding(.bottom, 8)
      .background(Color.white)
    }
  }

  private func finishPlaced(order: CreatedOrder, from current: Basket) {
    // Dine-in: confirmation email only — no Live Activity timer.
    if current.fulfillmentType != .dineIn {
      let summary = current.lines
        .map { "\($0.quantity)× \($0.item.title)" }
        .joined(separator: ", ")
      let seatLabel: String? = {
        guard current.fulfillmentType == .seatDelivery, current.hasValidSeat else { return nil }
        return "Row \(current.trimmedSeatRow) · Seat \(current.trimmedSeatNumber)"
      }()
      OrderLiveActivityController.start(
        orderID: order.id,
        venueName: venue.name,
        itemSummary: summary.isEmpty ? "Your order" : summary,
        status: .paid,
        isSeatDelivery: current.fulfillmentType == .seatDelivery,
        seatLabel: seatLabel
      )
    }
    onOrderPlaced()
    cart.clear(venueID: venue.id)
  }

  private func pay() async {
    guard var current = basket else { return }
    errorMessage = nil

    if current.fulfillmentType == .dineIn {
      guard current.partySize != nil, current.pickupAt != nil else {
        errorMessage = "Choose a party size and reservation time before continuing."
        return
      }
    } else if current.fulfillmentType == .seatDelivery {
      guard current.hasValidSeat else {
        errorMessage = "Enter your row and seat number for delivery."
        return
      }
    } else if let pickup = current.pickupAt, pickup < Date().addingTimeInterval(6 * 60) {
      cart.setPickup(nil, venueID: venue.id)
      errorMessage = "That collection time has passed, so we switched you back to ASAP. Tap Pay again to continue."
      return
    }
    current = basket ?? current

    isCreatingOrder = true
    let order: CreatedOrder
    do {
      order = try await service.createOrder(from: current)
    } catch {
      isCreatingOrder = false
      errorMessage = error.localizedDescription
      return
    }
    isCreatingOrder = false

    // Pay at restaurant: order is already confirmed (paid) — no Stripe sheet.
    if current.paymentMode == .atVenue || order.status != .pendingPayment {
      finishPlaced(order: order, from: current)
      return
    }

    switch await checkout.pay(orderID: order.id) {
    case .paid, .processing:
      finishPlaced(order: order, from: current)
    case .cancelled:
      errorMessage = "Payment wasn't completed. Your basket is saved, so you can try again."
    case .failed(let message):
      errorMessage = message
    }
  }
}

/// Collection time today: scrollable hour / minute wheels (15-minute steps, from 5 minutes ahead).
private struct SlotPicker: View {
  let selected: Date?
  let onPick: (Date) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var hour = 12
  @State private var minute = 0

  private var calendar: Calendar { .current }
  private let minuteStep = 5
  private var earliest: Date { Date().addingTimeInterval(5 * 60) }
  private var dayStart: Date { calendar.startOfDay(for: Date()) }
  private var endOfToday: Date {
    calendar.date(byAdding: .day, value: 1, to: dayStart)?.addingTimeInterval(-60) ?? earliest
  }

  private var availableHours: [Int] {
    (0..<24).filter { h in !minutes(for: h).isEmpty }
  }

  private func minutes(for hourValue: Int) -> [Int] {
    stride(from: 0, through: 55, by: minuteStep).compactMap { m -> Int? in
      guard let candidate = calendar.date(
        bySettingHour: hourValue, minute: m, second: 0, of: dayStart
      ) else { return nil }
      return (candidate >= earliest && candidate <= endOfToday) ? m : nil
    }
  }

  private var availableMinutes: [Int] { minutes(for: hour) }

  private var combined: Date? {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart)
  }

  private var canConfirm: Bool {
    guard let when = combined else { return false }
    return when >= earliest && when <= endOfToday
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Order for later")
        .font(.app(size: 24, weight: .heavy))
        .foregroundStyle(AppColors.text)

      HStack(spacing: 0) {
        VStack(spacing: 6) {
          Text("Hour")
            .font(.app(size: 13, weight: .semibold))
            .foregroundStyle(AppColors.mutedText)
          Picker("Hour", selection: $hour) {
            ForEach(availableHours, id: \.self) { h in
              Text(String(format: "%02d", h)).tag(h)
            }
          }
          .pickerStyle(.wheel)
          .frame(maxWidth: .infinity)
          .clipped()
        }

        Text(":")
          .font(.app(size: 28, weight: .bold))
          .foregroundStyle(AppColors.text)
          .padding(.top, 18)

        VStack(spacing: 6) {
          Text("Min")
            .font(.app(size: 13, weight: .semibold))
            .foregroundStyle(AppColors.mutedText)
          Picker("Minute", selection: $minute) {
            ForEach(availableMinutes, id: \.self) { m in
              Text(String(format: "%02d", m)).tag(m)
            }
          }
          .pickerStyle(.wheel)
          .frame(maxWidth: .infinity)
          .clipped()
        }
      }
      .frame(height: 160)
      .padding(.vertical, 4)
      .background(AppColors.chipFill.opacity(0.55))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

      if let when = combined, canConfirm {
        Text(CartView.slotLabel(when))
          .font(.app(size: 15, weight: .semibold))
          .foregroundStyle(AppColors.text)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Button {
        guard let when = combined, canConfirm else { return }
        onPick(when)
        dismiss()
      } label: {
        Text("Confirm time")
          .font(.app(size: 18, weight: .bold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 54)
          .background(canConfirm ? AppColors.primary : AppColors.primary.opacity(0.45))
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .disabled(!canConfirm)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .padding(.top, 24)
    .padding(.bottom, 16)
    .background(Color.white.ignoresSafeArea())
    .presentationDetents([.medium])
    .onAppear { bootstrap() }
    .onChange(of: hour) { _, _ in snapMinute() }
  }

  private func bootstrap() {
    let seed: Date = {
      guard let selected, calendar.isDateInToday(selected), selected >= earliest else {
        return earliest
      }
      return selected
    }()
    let rounded = roundUp(seed)
    hour = calendar.component(.hour, from: rounded)
    minute = calendar.component(.minute, from: rounded)
    snapToValid()
  }

  private func snapToValid() {
    if !availableHours.contains(hour) {
      hour = availableHours.first ?? hour
    }
    snapMinute()
  }

  private func snapMinute() {
    let mins = availableMinutes
    if !mins.contains(minute) {
      minute = mins.first ?? 0
    }
  }

  private func roundUp(_ date: Date) -> Date {
    let minuteValue = calendar.component(.minute, from: date)
    let remainder = minuteValue % minuteStep
    let add = remainder == 0 ? 0 : minuteStep - remainder
    let base = calendar.date(bySetting: .second, value: 0, of: date) ?? date
    return calendar.date(byAdding: .minute, value: add, to: base) ?? base
  }
}
