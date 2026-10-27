import SwiftUI
import UIKit

/// Scroll-space position of the in-flow category tab bar.
private struct TabBarTopKey: PreferenceKey {
  static var defaultValue: CGFloat = .greatestFiniteMagnitude
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Scroll-space position of each category header.
private struct SectionTopsKey: PreferenceKey {
  static var defaultValue: [UUID: CGFloat] = [:]
  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue()) { $1 }
  }
}

private enum Layout {
  static let scrollSpace = "menuScroll"
  static let coverHeight: CGFloat = 250
  static let navRowHeight: CGFloat = 52
  static let tabRowHeight: CGFloat = 48

  static var safeTop: CGFloat {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    return scene?.keyWindow?.safeAreaInsets.top ?? 47
  }
}

extension Venue {
  /// Small label above the title, e.g. "Guys".
  var brandLabel: String? {
    guard let groupName, !groupName.isEmpty else { return nil }
    return groupName
  }

  /// "Guys - Guys Blackrock" is shown as "Guys Blackrock" under the brand label.
  var displayTitle: String {
    if let range = name.range(of: " - ") { return String(name[range.upperBound...]) }
    return name
  }

  /// Title for lists: drops a repeated brand ("Guys - Guys Blackrock" becomes "Guys Blackrock")
  /// but keeps "Hypergoat Coffee - Swords" whole.
  var listTitle: String {
    if let group = groupName, displayTitle.hasPrefix(group) { return displayTitle }
    return name
  }
}

struct MenuView: View {
  let venue: Venue

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var chrome: AppChrome
  @EnvironmentObject private var cart: CartStore

  @State private var categories: [MenuCategory] = []
  @State private var collectionPoint: CollectionPoint?
  @State private var activeCategoryID: UUID?
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var showCart = false
  @State private var optionItem: MenuItem?
  @State private var isSearching = false
  @State private var query = ""
  @State private var tabBarTop: CGFloat = .greatestFiniteMagnitude
  @State private var sectionTops: [UUID: CGFloat] = [:]
  @FocusState private var searchFocused: Bool

  private let repository = MenuRepository()
  private let safeTop = Layout.safeTop

  private var stickyHeight: CGFloat { safeTop + Layout.navRowHeight + Layout.tabRowHeight }
  /// The in-flow tab bar is "stuck" once it reaches the bottom of the nav row.
  private var isStuck: Bool { tabBarTop < safeTop + Layout.navRowHeight + 1 }

  var body: some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .top) {
        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 0) {
            if isSearching {
              Color.clear.frame(height: safeTop + 64)
              searchResults
            } else {
              cover
              content(proxy: proxy)
            }
          }
        }
        .coordinateSpace(name: Layout.scrollSpace)
        .onPreferenceChange(TabBarTopKey.self) { tabBarTop = $0 }
        .onPreferenceChange(SectionTopsKey.self) { tops in
          sectionTops = tops
          updateActiveCategory()
        }
        .scrollDismissesKeyboard(.immediately)

        if isSearching {
          searchBar
        } else if isStuck {
          stickyBar(proxy: proxy)
        } else {
          floatingButtons
        }
      }
    }
    .background(Color.white)
    .ignoresSafeArea(edges: .top)
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .bottom) { basketBar }
    .onAppear {
      // Don't re-hide after Pay → Orders: this view can briefly reappear on the
      // inactive Home stack and would otherwise steal the tab bar forever.
      guard chrome.selectedTab == .home else { return }
      chrome.isTabBarHidden = true
    }
    .onDisappear {
      if chrome.selectedTab != .home {
        chrome.isTabBarHidden = false
      } else if !showCart {
        chrome.isTabBarHidden = false
      }
    }
    .task { await load() }
    .navigationDestination(isPresented: $showCart) {
      CartView(venue: venue) {
        showCart = false
        chrome.openOrdersAfterCheckout()
        // Pop the menu after the Orders tab is visible so this screen isn't briefly
        // re-rendered without its environment objects.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
      }
      .environmentObject(cart)
      .environmentObject(chrome)
    }
    .sheet(item: $optionItem) { item in
      OptionSheet(item: item, venue: venue) { options in
        cart.add(item, options: options, venue: venue, collectionPoint: collectionPoint)
      }
      .environmentObject(cart)
      .presentationDetents([.medium, .large])
    }
  }

  // MARK: - Cover

  private var cover: some View {
    ZStack(alignment: .bottomLeading) {
      VenueArtwork(url: venue.coverImageURL, initials: venue.initials, style: .hero)
        .frame(height: Layout.coverHeight)
        .frame(maxWidth: .infinity)
        .clipped()

      LinearGradient(
        colors: [Color.black.opacity(0.35), Color.black.opacity(0.05), Color.black.opacity(0.65)],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: Layout.coverHeight)

      VStack(alignment: .leading, spacing: 2) {
        if let brand = venue.brandLabel {
          Text(brand)
            .font(.app(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
        }
        Text(venue.displayTitle)
          .font(.app(size: 30, weight: .heavy))
          .foregroundStyle(.white)
          .lineLimit(2)
          .minimumScaleFactor(0.8)
        if venue.kind == .venue, let collectionPoint {
          Text(collectionPoint.locationLabel)
            .font(.app(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.top, 2)
        }
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
      .padding(.trailing, 110)

      if let collectionPoint {
        HStack(spacing: 6) {
          Image(systemName: "hourglass")
            .font(.app(size: 13, weight: .bold))
          Text(collectionPoint.waitLabel)
            .font(.app(size: 14, weight: .bold))
        }
        .foregroundStyle(AppColors.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.96))
        .clipShape(Capsule())
        .padding(.trailing, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .frame(height: Layout.coverHeight)
  }

  private var floatingButtons: some View {
    HStack {
      Button { dismiss() } label: { CircleButton(system: "chevron.left") }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
      Spacer()
      Button { startSearch() } label: { CircleButton(system: "magnifyingglass") }
        .buttonStyle(.plain)
        .accessibilityLabel("Search menu")
    }
    .padding(.horizontal, 16)
    .padding(.top, safeTop + 6)
  }

  // MARK: - Sticky bars

  private func stickyBar(proxy: ScrollViewProxy) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button { dismiss() } label: { CircleButton(system: "chevron.left", onDark: false, size: 34) }
          .buttonStyle(.plain)
          .accessibilityLabel("Back")
        Text(venue.displayTitle)
          .font(.app(size: 18, weight: .bold))
          .foregroundStyle(AppColors.text)
          .lineLimit(1)
        Spacer()
        Button { startSearch() } label: { CircleButton(system: "magnifyingglass", onDark: false, size: 34) }
          .buttonStyle(.plain)
          .accessibilityLabel("Search menu")
      }
      .padding(.horizontal, 16)
      .frame(height: Layout.navRowHeight)

      tabStrip(proxy: proxy)
    }
    .padding(.top, safeTop)
    .background(Color.white)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var searchBar: some View {
    HStack(spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(AppColors.mutedText)
        TextField("Search the menu", text: $query)
          .font(.app(size: 17))
          .focused($searchFocused)
          .submitLabel(.search)
          .autocorrectionDisabled()
          .accessibilityIdentifier("menu-search-field")
        if !query.isEmpty {
          Button { query = "" } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(AppColors.mutedText.opacity(0.7))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 44)
      .background(AppColors.chipFill.opacity(0.6))
      .clipShape(Capsule())

      Button("Cancel") {
        query = ""
        searchFocused = false
        isSearching = false
      }
      .font(.app(size: 16, weight: .semibold))
      .foregroundStyle(AppColors.primary)
    }
    .padding(.horizontal, 16)
    .padding(.top, safeTop + 8)
    .padding(.bottom, 10)
    .background(Color.white)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func startSearch() {
    isSearching = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
  }

  // MARK: - Content

  @ViewBuilder
  private func content(proxy: ScrollViewProxy) -> some View {
    if isLoading {
      ProgressView().padding(.top, 60)
    } else if let errorMessage {
      message(title: "Couldn't load the menu", detail: errorMessage, retry: true)
    } else if categories.isEmpty {
      message(title: "No menu yet", detail: "This venue hasn't published a menu.", retry: false)
    } else {
      if !venue.isOpen { closedBanner }

      // A plain VStack on purpose: scrollTo can only find section anchors that already exist.
      VStack(spacing: 0) {
        tabStrip(proxy: proxy)
          .background(
            GeometryReader { geo in
              Color.clear.preference(
                key: TabBarTopKey.self,
                value: geo.frame(in: .named(Layout.scrollSpace)).minY
              )
            }
          )

        ForEach(categories) { category in
          categorySection(category)
        }

        // Lets the last short category scroll all the way up under the sticky bar.
        Color.clear.frame(height: 420)
      }
    }
  }

  private var closedBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "moon.zzz.fill")
      Text("\(venue.displayTitle) is closed right now, so ordering is unavailable.")
        .font(.app(size: 14, weight: .semibold))
    }
    .foregroundStyle(AppColors.closedRed)
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppColors.closedRedBackground)
  }

  private func tabStrip(proxy: ScrollViewProxy) -> some View {
    ScrollViewReader { tabProxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 26) {
          ForEach(categories) { category in
            let isSelected = category.id == (activeCategoryID ?? categories.first?.id)
            VStack(spacing: 10) {
              Text(category.title)
                .font(.app(size: 17, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? AppColors.text : AppColors.mutedText)
                .lineLimit(1)
              Rectangle()
                .fill(isSelected ? AppColors.primary : Color.clear)
                .frame(height: 3)
            }
            .contentShape(Rectangle())
            .id(category.id)
            .onTapGesture {
              activeCategoryID = category.id
              withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("anchor-\(category.id.uuidString)", anchor: .top)
              }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(category.title)
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
      }
      .frame(height: Layout.tabRowHeight + 6)
      .background(Color.white)
      .onChange(of: activeCategoryID) { _, id in
        guard let id else { return }
        withAnimation { tabProxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  private func categorySection(_ category: MenuCategory) -> some View {
    VStack(spacing: 0) {
      // Scrolling to this lands the header just below the sticky bar.
      Color.clear
        .frame(height: stickyHeight)
        .padding(.top, -stickyHeight)
        .id("anchor-\(category.id.uuidString)")

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(category.title)
          .font(.app(size: 24, weight: .heavy))
          .foregroundStyle(AppColors.text)
        Text("\u{2014} \(category.items.count) items")
          .font(.app(size: 15, weight: .semibold))
          .foregroundStyle(AppColors.mutedText)
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.top, 22)
      .padding(.bottom, 8)
      .background(
        GeometryReader { geo in
          Color.clear.preference(
            key: SectionTopsKey.self,
            value: [category.id: geo.frame(in: .named(Layout.scrollSpace)).minY]
          )
        }
      )

      ForEach(Array(category.items.enumerated()), id: \.element.id) { index, item in
        itemRow(item)
        if index < category.items.count - 1 {
          Divider().padding(.leading, 20 + 66 + 14)
        }
      }
    }
  }

  private func updateActiveCategory() {
    guard !categories.isEmpty, !isSearching else { return }
    let threshold = stickyHeight + 14
    let known = categories.enumerated().compactMap { index, category in
      sectionTops[category.id].map { (index, category.id, $0) }
    }
    guard !known.isEmpty else { return }

    if let current = known.last(where: { $0.2 <= threshold }) {
      activeCategoryID = current.1
    } else if let first = known.min(by: { $0.0 < $1.0 }) {
      // Everything realised is below the bar, so we are just above the first of them.
      activeCategoryID = categories[max(0, first.0 - 1)].id
    }
  }

  // MARK: - Rows

  private var searchResults: some View {
    let needle = query.trimmingCharacters(in: .whitespaces)
    let matches = categories.flatMap(\.items).filter { item in
      needle.isEmpty
        || item.title.localizedCaseInsensitiveContains(needle)
        || (item.subtitle ?? "").localizedCaseInsensitiveContains(needle)
    }
    return VStack(spacing: 0) {
      if needle.isEmpty {
        message(title: "Search the menu", detail: "Type a drink, snack or sandwich.", retry: false)
      } else if matches.isEmpty {
        message(title: "No results", detail: "Nothing on this menu matches \"\(needle)\".", retry: false)
      } else {
        HStack {
          Text("\(matches.count) result\(matches.count == 1 ? "" : "s")")
            .font(.app(size: 15, weight: .semibold))
            .foregroundStyle(AppColors.mutedText)
          Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
          itemRow(item)
          if index < matches.count - 1 { Divider().padding(.leading, 20 + 66 + 14) }
        }
      }
    }
  }

  private func itemRow(_ item: MenuItem) -> some View {
    let canOrder = venue.isOpen && item.isAvailable
    return HStack(spacing: 14) {
      ItemPhoto(url: item.imageURL)
        .frame(width: 66, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(item.isAvailable ? 1 : 0.4)

      VStack(alignment: .leading, spacing: 3) {
        Text(item.title)
          .font(.app(size: 18, weight: .bold))
          .foregroundStyle(item.isAvailable ? AppColors.text : AppColors.mutedText)
          .lineLimit(2)
        if item.isAvailable {
          if let detail = item.detailLine {
            Text(detail)
              .font(.app(size: 14))
              .foregroundStyle(AppColors.mutedText)
              .lineLimit(1)
          }
          Text(Money.format(cents: item.priceCents, currency: item.currency))
            .font(.app(size: 16, weight: .semibold))
            .foregroundStyle(AppColors.text)
            .padding(.top, 1)
        } else {
          Text("Temporarily Unavailable")
            .font(.app(size: 14, weight: .semibold))
            .foregroundStyle(AppColors.mutedText)
        }
      }

      Spacer(minLength: 8)

      if canOrder { quantityControl(for: item) }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func quantityControl(for item: MenuItem) -> some View {
    let quantity = cart.quantity(of: item.id, at: venue)

    if item.hasOptions {
      // Customising always goes through the sheet; the badge shows how many are in the basket.
      Button { optionItem = item } label: {
        plusCircle
          .overlay(alignment: .topTrailing) {
            if quantity > 0 {
              Text("\(quantity)")
                .font(.app(size: 12, weight: .bold))
                .foregroundStyle(AppColors.primary)
                .frame(minWidth: 20, minHeight: 20)
                .background(Color.white)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppColors.primary, lineWidth: 1.5))
                .offset(x: 8, y: -8)
            }
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Customise \(item.title)")
    } else if quantity == 0 {
      Button { add(item) } label: { plusCircle }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(item.title)")
    } else {
      HStack(spacing: 10) {
        Button { cart.decrement(lineID: lineID(for: item), venueID: venue.id) } label: {
          Image(systemName: "minus")
            .font(.app(size: 13, weight: .bold))
            .foregroundStyle(AppColors.primary)
            .frame(width: 32, height: 32)
            .background(AppColors.primaryLight.opacity(0.7))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove one \(item.title)")

        Text("\(quantity)")
          .font(.app(size: 16, weight: .bold))
          .foregroundStyle(AppColors.text)
          .frame(minWidth: 18)

        Button { add(item) } label: {
          Image(systemName: "plus")
            .font(.app(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(AppColors.primary)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add one \(item.title)")
      }
    }
  }

  private var plusCircle: some View {
    Circle()
      .fill(AppColors.primary)
      .frame(width: 36, height: 36)
      .overlay(
        Image(systemName: "plus")
          .foregroundStyle(.white)
          .font(.app(size: 15, weight: .bold))
      )
  }

  /// Items without options have a single basket line, whose id is the item id plus no options.
  private func lineID(for item: MenuItem) -> String { item.id.uuidString + "|" }

  private func message(title: String, detail: String, retry: Bool) -> some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.app(size: 19, weight: .heavy))
        .foregroundStyle(AppColors.text)
      Text(detail)
        .font(.app(size: 16))
        .foregroundStyle(AppColors.mutedText)
        .multilineTextAlignment(.center)
      if retry {
        Button {
          Task { await load() }
        } label: {
          Text("Try again")
            .font(.app(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .frame(height: 46)
            .background(AppColors.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
      }
    }
    .padding(.horizontal, 32)
    .padding(.top, 48)
  }

  // MARK: - Basket bar

  @ViewBuilder
  private var basketBar: some View {
    if let basket = cart.basket(for: venue) {
      Button {
        searchFocused = false
        showCart = true
      } label: {
        HStack {
          Text("\(basket.itemCount)")
            .font(.app(size: 15, weight: .bold))
            .frame(width: 30, height: 30)
            .background(Color.white.opacity(0.25))
            .clipShape(Circle())
          Text("Your order")
            .font(.app(size: 17, weight: .bold))
          Spacer()
          Text(Money.format(cents: basket.subtotalCents, currency: basket.currency))
            .font(.app(size: 17, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(AppColors.primary)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("view-basket")
    }
  }

  // MARK: - Actions

  private func add(_ item: MenuItem) {
    cart.add(item, venue: venue, collectionPoint: collectionPoint)
  }

  private func load() async {
    isLoading = categories.isEmpty
    do {
      async let points = repository.fetchCollectionPoints(venueID: venue.id)
      async let loaded = repository.fetchCategories(venueID: venue.id)
      let (fetchedPoints, fetchedCategories) = try await (points, loaded)

      collectionPoint = fetchedPoints.first { $0.isOpen } ?? fetchedPoints.first
      categories = fetchedCategories
      activeCategoryID = activeCategoryID ?? fetchedCategories.first?.id
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }
}

private struct CircleButton: View {
  let system: String
  var onDark = true
  var size: CGFloat = 40

  var body: some View {
    Circle()
      .fill(onDark ? Color.white.opacity(0.96) : AppColors.chipFill.opacity(0.7))
      .frame(width: size, height: size)
      .shadow(color: .black.opacity(onDark ? 0.18 : 0), radius: 6, y: 2)
      .overlay(
        Image(systemName: system)
          .font(.app(size: size * 0.36, weight: .bold))
          .foregroundStyle(AppColors.text)
      )
  }
}
