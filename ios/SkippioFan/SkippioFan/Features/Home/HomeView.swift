import SwiftUI

struct HomeView: View {
  @EnvironmentObject private var auth: AuthStore
  @EnvironmentObject private var favourites: FavouritesStore
  @EnvironmentObject private var cart: CartStore
  @EnvironmentObject private var chrome: AppChrome
  @StateObject private var location = LocationProvider()

  @State private var venues: [Venue] = []
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var selectedKind: VenueKind = .cafe
  @State private var searchText = ""
  @State private var showFavouritesOnly = false
  @State private var openNowOnly = false
  @State private var showMap = false
  @State private var pushedVenue: Venue?
  @State private var restaurantChoice: Venue?
  @State private var dineInSetup: Venue?

  private let venueRepository = VenueRepository()
  private let menuRepository = MenuRepository()

  var body: some View {
    ZStack {
      AppColors.background.ignoresSafeArea()

      VStack(alignment: .leading, spacing: 16) {
        header
        searchField
        kindChips
        openNowFilter
        listContent
      }
      .padding(.top, 12)
    }
    .toolbar(.hidden, for: .navigationBar)
    // After Pay → Orders, clear the menu/cart stack so it can't re-hide the tab bar.
    .onChange(of: chrome.selectedTab) { _, tab in
      if tab != .home {
        pushedVenue = nil
        chrome.isTabBarHidden = false
      }
    }
    .navigationDestination(item: $pushedVenue) { venue in
      // Explicitly pass env objects — nested destinations sometimes drop them.
      MenuView(venue: venue)
        .environmentObject(cart)
        .environmentObject(favourites)
        .environmentObject(auth)
        .environmentObject(chrome)
    }
    .sheet(item: $restaurantChoice) { venue in
      RestaurantModeSheet(venue: venue) { fulfillment in
        restaurantChoice = nil
        if fulfillment == .dineIn {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dineInSetup = venue }
        } else {
          Task { await openRestaurant(venue, fulfillment: .takeout) }
        }
      }
      .presentationDetents([.height(300)])
      .presentationDragIndicator(.visible)
    }
    .sheet(item: $dineInSetup) { venue in
      DineInReservationSheet(venue: venue) { partySize, when in
        dineInSetup = nil
        Task { await openRestaurant(venue, fulfillment: .dineIn, partySize: partySize, reservationAt: when) }
      }
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showMap) {
      VenueMapView(venues: venues) { venue in
        // Wait for the sheet to finish closing before pushing the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openVenue(venue) }
      }
    }
    .alert(
      "Favourites",
      isPresented: Binding(
        get: { favourites.errorMessage != nil },
        set: { if !$0 { favourites.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(favourites.errorMessage ?? "")
    }
    .task {
      location.start()
      await loadVenues()
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        HStack(spacing: 8) {
          Image(systemName: "mappin.and.ellipse")
            .font(.app(size: 14, weight: .semibold))
            .foregroundStyle(AppColors.primary)
          Text("Ireland")
            .font(.app(size: 15, weight: .bold))
            .foregroundStyle(AppColors.text)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .appCardStyle(radius: 22)

        Spacer()

        HStack(spacing: 10) {
          squareIconButton(system: "map", label: "Map", active: false) {
            showMap = true
          }
          squareIconButton(
            system: showFavouritesOnly ? "heart.fill" : "heart",
            label: showFavouritesOnly ? "Show all venues" : "Show favourites",
            active: showFavouritesOnly
          ) {
            showFavouritesOnly.toggle()
          }
        }
      }

      Text(greetingText)
        .font(.app(size: 24, weight: .heavy))
        .foregroundStyle(AppColors.text)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .padding(.horizontal, AppSpacing.screenHorizontal)
  }

  private var greetingText: String {
    let hour = Calendar.current.component(.hour, from: Date())
    let greeting: String
    switch hour {
    case 5..<12: greeting = "Good morning"
    case 12..<17: greeting = "Good afternoon"
    default: greeting = "Good evening"
    }
    guard let name = auth.user?.firstName else { return greeting }
    return "\(greeting), \(name)"
  }

  private var searchField: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.app(size: 17, weight: .regular))
        .foregroundStyle(AppColors.mutedText)
      TextField("Search cafés, venues, events", text: $searchText)
        .font(.app(size: 16))
        .foregroundStyle(AppColors.text)
        .submitLabel(.search)
        .autocorrectionDisabled()
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(AppColors.mutedText.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 52)
    .appCardStyle(radius: 20)
    .padding(.horizontal, AppSpacing.screenHorizontal)
  }

  private var kindChips: some View {
    HStack(spacing: 10) {
      kindChip(title: "Cafés", icon: "cup.and.saucer", kind: .cafe)
      kindChip(title: "Venues", icon: "ticket", kind: .venue)
      kindChip(title: "Restaurants", icon: "fork.knife", kind: .restaurant)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, AppSpacing.screenHorizontal)
  }

  private var openNowFilter: some View {
    Button {
      openNowOnly.toggle()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: openNowOnly ? "checkmark.circle.fill" : "circle")
          .font(.app(size: 16, weight: .semibold))
          .foregroundStyle(openNowOnly ? AppColors.openGreen : AppColors.mutedText)
        Text("Open now")
          .font(.app(size: 15, weight: .semibold))
          .foregroundStyle(AppColors.text)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, AppSpacing.screenHorizontal)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(openNowOnly ? "Showing open places only" : "Show open places only")
  }

  private func kindChip(title: String, icon: String, kind: VenueKind) -> some View {
    // Searching and the favourites filter look across every category.
    let active = selectedKind == kind && !isCrossCategory
    return Button {
      selectedKind = kind
      searchText = ""
      showFavouritesOnly = false
    } label: {
      HStack(spacing: 7) {
        Image(systemName: icon)
          .font(.app(size: 13, weight: .medium))
        Text(title)
          .font(.app(size: 15, weight: .bold))
      }
      .foregroundStyle(active ? Color.white : AppColors.text)
      .padding(.horizontal, 16)
      .frame(height: 44)
      .background(active ? AppColors.primary : AppColors.card)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(active ? Color.clear : AppColors.border, lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(active ? 0 : 0.04), radius: 6, x: 0, y: 2)
    }
    .buttonStyle(.plain)
  }

  private func squareIconButton(
    system: String,
    label: String,
    active: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(active ? AppColors.primary : AppColors.card)
        .frame(width: 44, height: 44)
        .overlay(
          Image(systemName: system)
            .font(.app(size: 17, weight: .medium))
            .foregroundStyle(active ? Color.white : AppColors.text)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(active ? Color.clear : AppColors.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  // MARK: - List

  @ViewBuilder
  private var listContent: some View {
    if isLoading && venues.isEmpty {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage {
      messageView(
        title: "Could not load venues",
        detail: errorMessage,
        actionTitle: "Try again"
      ) {
        Task { await loadVenues() }
      }
    } else if visibleVenues.isEmpty {
      emptyState
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(spacing: 14) {
          ForEach(visibleVenues) { venue in
            // The heart is a sibling of the tappable card (not nested inside it),
            // otherwise taps on the heart would open the menu instead.
            if venue.kind == .cafe || venue.kind == .restaurant {
              cafeRow(venue)
            } else {
              venueCard(venue)
            }
          }
        }
        .padding(.horizontal, AppSpacing.screenHorizontal)
        .padding(.top, 4)
        .padding(.bottom, AppSpacing.tabBarClearance)
      }
      .refreshable {
        await loadVenues()
        await favourites.load()
      }
    }
  }

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private var isCrossCategory: Bool { isSearching || showFavouritesOnly }

  /// Open venues first, then nearest first (when location is available).
  private var visibleVenues: [Venue] {
    let query = searchText.trimmingCharacters(in: .whitespaces)

    return venues
      .filter { venue in
        if showFavouritesOnly && !favourites.contains(venue) { return false }
        if !query.isEmpty {
          return venue.name.localizedCaseInsensitiveContains(query)
            || venue.address.localizedCaseInsensitiveContains(query)
            || venue.city.localizedCaseInsensitiveContains(query)
        }
        if openNowOnly && !venue.isOpen { return false }
        return showFavouritesOnly || venue.kind == selectedKind
      }
      .sorted { lhs, rhs in
        if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
        let l = location.distanceKm(to: lhs)
        let r = location.distanceKm(to: rhs)
        switch (l, r) {
        case let (l?, r?) where l != r: return l < r
        default: return lhs.name < rhs.name
        }
      }
  }

  private var emptyState: some View {
    let (title, detail): (String, String) = {
      if isSearching { return ("No results", "Nothing matches \"\(searchText)\".") }
      if showFavouritesOnly {
        return ("No favourites yet", "Tap the heart on a venue or café to save it here.")
      }
      if openNowOnly {
        return ("Nothing open right now", "Turn off Open now to see closed places too.")
      }
      switch selectedKind {
      case .cafe: return ("No cafés yet", "Cafés near you will appear here.")
      case .venue: return ("No venues yet", "Stadiums, racecourses and festivals will appear here.")
      case .restaurant: return ("No restaurants yet", "Restaurants near you will appear here.")
      case .private: return ("No private venues", "Private venues you have access to will appear here.")
      }
    }()

    return messageView(title: title, detail: detail, actionTitle: nil, action: {})
  }

  private func messageView(
    title: String,
    detail: String,
    actionTitle: String?,
    action: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.app(size: 20, weight: .heavy))
        .foregroundStyle(AppColors.text)
      Text(detail)
        .font(.app(size: 16))
        .foregroundStyle(AppColors.text)
        .multilineTextAlignment(.center)

      if let actionTitle {
        Button(action: action) {
          Text(actionTitle)
            .font(.app(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .frame(height: 46)
            .background(AppColors.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
      }
    }
    .padding(.horizontal, 36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, AppSpacing.tabBarClearance)
  }

  // MARK: - Rows

  private func openVenue(_ venue: Venue) {
    if venue.kind == .restaurant {
      restaurantChoice = venue
    } else {
      pushedVenue = venue
    }
  }

  private func openRestaurant(
    _ venue: Venue,
    fulfillment: FulfillmentType,
    partySize: Int? = nil,
    reservationAt: Date? = nil
  ) async {
    let points = (try? await menuRepository.fetchCollectionPoints(venueID: venue.id)) ?? []
    let point = points.first
    cart.ensureBasket(
      venue: venue,
      collectionPoint: point,
      fulfillment: fulfillment,
      partySize: partySize,
      pickupAt: reservationAt
    )
    cart.setPaymentMode(.stripe, venueID: venue.id)
    await MainActor.run { pushedVenue = venue }
  }

  private func cafeRow(_ venue: Venue) -> some View {
    HStack(spacing: 14) {
      Button {
        openVenue(venue)
      } label: {
        HStack(spacing: 14) {
          VenueArtwork(url: venue.logoURL ?? venue.coverImageURL, initials: venue.initials, style: .logo)
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(venue.isOpen ? 1 : 0.55)
            .overlay(alignment: .topTrailing) { basketBadge(for: venue).offset(x: 6, y: -6) }

          VStack(alignment: .leading, spacing: 5) {
            Text(venue.listTitle)
              .font(.app(size: 17, weight: .bold))
              .foregroundStyle(AppColors.text)
              .lineLimit(2)
              .multilineTextAlignment(.leading)

            if let subtitle = venue.subtitle ?? Optional(venue.city), !subtitle.isEmpty {
              Text(subtitle)
                .font(.app(size: 15))
                .foregroundStyle(AppColors.mutedText)
                .lineLimit(1)
            }

            statusLine(for: venue)
          }

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      favouriteButton(for: venue)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .appCardStyle(radius: 24)
  }

  @ViewBuilder
  private func basketBadge(for venue: Venue) -> some View {
    let count = cart.itemCount(for: venue)
    if count > 0 { BasketBadge(count: count) }
  }

  private func favouriteButton(for venue: Venue) -> some View {
    FavouriteButton(isFavourite: favourites.contains(venue)) {
      guard let userID = auth.user?.id else { return }
      Task { await favourites.toggle(venue, userID: userID) }
    }
  }

  private func statusLine(for venue: Venue) -> some View {
    HStack(spacing: 7) {
      Circle()
        .fill(venue.isOpen ? AppColors.openGreen : AppColors.closedRed)
        .frame(width: 7, height: 7)
      Text(venue.isOpen ? "Open" : "Closed")
        .font(.app(size: 13, weight: .bold))
        .foregroundStyle(venue.isOpen ? AppColors.openGreen : AppColors.closedRed)

      if let km = location.distanceKm(to: venue) {
        Circle()
          .fill(AppColors.mutedText.opacity(0.35))
          .frame(width: 3, height: 3)
        Image(systemName: "mappin.and.ellipse")
          .font(.app(size: 12))
          .foregroundStyle(AppColors.primary)
        Text(distanceLabel(km, spaced: true))
          .font(.app(size: 13, weight: .semibold))
          .foregroundStyle(AppColors.mutedText)
      }
    }
  }

  private func venueCard(_ venue: Venue) -> some View {
    Button {
      openVenue(venue)
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        ZStack(alignment: .topTrailing) {
          VenueArtwork(url: venue.coverImageURL, initials: venue.initials, style: .hero)
            .frame(height: 176)
            .frame(maxWidth: .infinity)
            .clipped()
            // Closed venues are washed out, like the reference design.
            .overlay(Color.white.opacity(venue.isOpen ? 0 : 0.55))

          HStack(spacing: 8) {
            basketBadge(for: venue)
            StatusPill(isOpen: venue.isOpen)
          }
          .padding(12)
        }
        .frame(height: 176)

        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(venue.name)
              .font(.app(size: 19, weight: .bold))
              .foregroundStyle(AppColors.text)
              .lineLimit(1)
            Text(venueSubtitle(venue))
              .font(.app(size: 14))
              .foregroundStyle(AppColors.mutedText)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.right")
            .font(.app(size: 13, weight: .semibold))
            .foregroundStyle(AppColors.mutedText.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .appCardStyle(radius: 26)
    // Sits on top of the card as a sibling of the button, pinned to the photo's corner.
    .overlay(alignment: .topTrailing) {
      favouriteButton(for: venue)
        .padding(.top, 176 - 44 - 12)
        .padding(.trailing, 12)
    }
  }

  private func venueSubtitle(_ venue: Venue) -> String {
    var text = venue.address
    if let km = location.distanceKm(to: venue) {
      text += "  ·  \(distanceLabel(km, spaced: false)) away"
    }
    return text
  }

  private func distanceLabel(_ km: Double, spaced: Bool) -> String {
    let unit = spaced ? " km" : "km"
    return String(format: "%.1f", km) + unit
  }

  // MARK: - Actions

  private func loadVenues() async {
    isLoading = true
    defer { isLoading = false }

    do {
      venues = try await venueRepository.fetchVenues()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
