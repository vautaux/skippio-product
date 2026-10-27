import SwiftUI

/// Choose dine-in or takeout before opening a restaurant menu.
struct RestaurantModeSheet: View {
  let venue: Venue
  let onChoose: (FulfillmentType) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(venue.name)
        .font(.app(size: 22, weight: .heavy))
        .foregroundStyle(AppColors.text)
      Text("How would you like to order?")
        .font(.app(size: 16))
        .foregroundStyle(AppColors.mutedText)

      modeButton(
        title: "Dine in",
        detail: "Reserve a table and pre-order food",
        icon: "fork.knife"
      ) { onChoose(.dineIn) }

      modeButton(
        title: "Takeout",
        detail: "Order for collection",
        icon: "takeoutbag.and.cup.and.straw"
      ) { onChoose(.takeout) }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.top, 28)
    .padding(.bottom, 24)
    .background(AppColors.background)
  }

  private func modeButton(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.app(size: 22, weight: .semibold))
          .foregroundStyle(AppColors.primary)
          .frame(width: 40)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.app(size: 18, weight: .bold))
            .foregroundStyle(AppColors.text)
          Text(detail)
            .font(.app(size: 14))
            .foregroundStyle(AppColors.mutedText)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .foregroundStyle(AppColors.mutedText)
      }
      .padding(16)
      .background(AppColors.card)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

/// Party size + calendar date + scrollable time for dine-in (new or modify).
struct DineInReservationSheet: View {
  let venueTitle: String
  var initialPartySize: Int = 2
  var initialReservation: Date? = nil
  var confirmTitle: String = "Continue"
  var navigationTitleText: String? = nil
  let onConfirm: (Int, Date) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var partySize = 2
  @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
  @State private var selectedTime: Date = Self.defaultTime()
  @State private var didBootstrap = false

  private var calendar: Calendar { .current }

  init(
    venue: Venue,
    initialPartySize: Int = 2,
    initialReservation: Date? = nil,
    confirmTitle: String = "Continue",
    navigationTitleText: String? = nil,
    onConfirm: @escaping (Int, Date) -> Void
  ) {
    self.venueTitle = venue.listTitle
    self.initialPartySize = initialPartySize
    self.initialReservation = initialReservation
    self.confirmTitle = confirmTitle
    self.navigationTitleText = navigationTitleText
    self.onConfirm = onConfirm
  }

  init(
    venueTitle: String,
    initialPartySize: Int = 2,
    initialReservation: Date? = nil,
    confirmTitle: String = "Continue",
    navigationTitleText: String? = nil,
    onConfirm: @escaping (Int, Date) -> Void
  ) {
    self.venueTitle = venueTitle
    self.initialPartySize = initialPartySize
    self.initialReservation = initialReservation
    self.confirmTitle = confirmTitle
    self.navigationTitleText = navigationTitleText
    self.onConfirm = onConfirm
  }

  /// Reservations: from 30 minutes ahead through 7 days.
  private var earliest: Date { Date().addingTimeInterval(30 * 60) }
  private var latest: Date { Date().addingTimeInterval(7 * 24 * 60 * 60) }

  private var dayRange: ClosedRange<Date> {
    let start = calendar.startOfDay(for: earliest)
    let end = calendar.startOfDay(for: latest)
    return start...end
  }

  /// 15-minute slots for the chosen day (only future times if today).
  private var timeSlots: [Date] {
    let dayStart = calendar.startOfDay(for: selectedDay)
    guard let open = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: dayStart),
          let close = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: dayStart)
    else { return [] }

    var slots: [Date] = []
    var cursor = open
    while cursor <= close {
      if cursor >= earliest && cursor <= latest {
        slots.append(cursor)
      }
      guard let next = calendar.date(byAdding: .minute, value: 15, to: cursor) else { break }
      cursor = next
    }
    return slots
  }

  private var combinedReservation: Date? {
    let parts = calendar.dateComponents([.hour, .minute], from: selectedTime)
    return calendar.date(
      bySettingHour: parts.hour ?? 12,
      minute: parts.minute ?? 0,
      second: 0,
      of: selectedDay
    )
  }

  private var canContinue: Bool {
    guard let when = combinedReservation else { return false }
    return when >= earliest && when <= latest && timeSlots.contains(where: {
      calendar.isDate($0, equalTo: when, toGranularity: .minute)
    })
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          partySection
          dateSection
          timeSection
          summary
        }
        .padding(20)
        .padding(.bottom, 24)
      }
      .background(AppColors.background)
      .navigationTitle(navigationTitleText ?? "Reserve at \(venueTitle)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(confirmTitle) {
            if let when = combinedReservation { onConfirm(partySize, when) }
          }
          .fontWeight(.bold)
          .disabled(!canContinue)
        }
      }
      .onAppear {
        if !didBootstrap {
          bootstrapFromInitial()
          didBootstrap = true
        }
        snapToValidSelection()
      }
      .onChange(of: selectedDay) { _, _ in snapTimeToAvailable() }
    }
  }

  private func bootstrapFromInitial() {
    partySize = min(max(initialPartySize, 1), 20)
    if let initial = initialReservation {
      selectedDay = calendar.startOfDay(for: initial)
      selectedTime = initial
    }
  }

  private var partySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Party size")
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(AppColors.mutedText)
      Stepper("\(partySize) guest\(partySize == 1 ? "" : "s")", value: $partySize, in: 1...20)
        .font(.app(size: 17, weight: .semibold))
        .padding(14)
        .background(AppColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private var dateSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Date")
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(AppColors.mutedText)
      DatePicker(
        "Reservation date",
        selection: $selectedDay,
        in: dayRange,
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .tint(AppColors.primary)
      .padding(8)
      .background(AppColors.card)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  private var timeSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Time")
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(AppColors.mutedText)

      if timeSlots.isEmpty {
        Text("No times left on this day. Pick another date.")
          .font(.app(size: 15))
          .foregroundStyle(AppColors.closedRed)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AppColors.closedRedBackground)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      } else {
        Picker("Time", selection: $selectedTime) {
          ForEach(timeSlots, id: \.self) { slot in
            Text(slot.formatted(date: .omitted, time: .shortened)).tag(slot)
          }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipped()
        .background(AppColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
    }
  }

  private var summary: some View {
    Group {
      if let when = combinedReservation, canContinue {
        HStack(spacing: 8) {
          Image(systemName: "calendar.badge.clock")
            .foregroundStyle(AppColors.primary)
          Text(when.formatted(date: .complete, time: .shortened))
            .font(.app(size: 15, weight: .semibold))
            .foregroundStyle(AppColors.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.primaryLight.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
    }
  }

  private func snapToValidSelection() {
    if selectedDay < dayRange.lowerBound { selectedDay = dayRange.lowerBound }
    if selectedDay > dayRange.upperBound { selectedDay = dayRange.upperBound }
    snapTimeToAvailable()
  }

  private func snapTimeToAvailable() {
    guard let first = timeSlots.first else { return }
    if !timeSlots.contains(where: { calendar.isDate($0, equalTo: selectedTime, toGranularity: .minute) }) {
      selectedTime = first
    }
  }

  private static func defaultTime() -> Date {
    let calendar = Calendar.current
    let start = Date().addingTimeInterval(60 * 60)
    let minute = ((calendar.component(.minute, from: start) / 15) + 1) * 15
    return calendar.date(
      bySettingHour: calendar.component(.hour, from: start) + (minute >= 60 ? 1 : 0),
      minute: minute % 60,
      second: 0,
      of: start
    ) ?? start
  }
}
