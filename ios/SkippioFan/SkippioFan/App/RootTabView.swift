import SwiftUI

/// Lets pushed screens (like the menu) hide the floating tab bar.
@MainActor
final class AppChrome: ObservableObject {
  @Published var isTabBarHidden = false
  /// Shared so any screen (e.g. after checkout) can switch tabs.
  @Published var selectedTab: AppTab = .home

  /// After Pay: always show the tab bar and jump to Orders.
  func openOrdersAfterCheckout() {
    isTabBarHidden = false
    selectedTab = .orders
  }
}

enum AppTab: CaseIterable, Hashable {
  case home
  case orders
  case rewards
  case profile

  var title: String {
    switch self {
    case .home: return "Home"
    case .orders: return "Orders"
    case .rewards: return "Rewards"
    case .profile: return "Profile"
    }
  }

  var icon: String {
    switch self {
    case .home: return "house"
    case .orders: return "list.clipboard"
    case .rewards: return "star"
    case .profile: return "person"
    }
  }

  var selectedIcon: String { icon + ".fill" }
}

struct RootTabView: View {
  @StateObject private var chrome = AppChrome()

  var body: some View {
    ZStack(alignment: .bottom) {
      // The system tab bar is hidden; we draw our own floating one below.
      TabView(selection: $chrome.selectedTab) {
        NavigationStack { HomeView() }
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.home)

        NavigationStack { OrdersView() }
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.orders)

        NavigationStack { RewardsView() }
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.rewards)

        NavigationStack { ProfileView() }
          .toolbar(.hidden, for: .tabBar)
          .tag(AppTab.profile)
      }

      if !chrome.isTabBarHidden {
        FloatingTabBar(selection: $chrome.selectedTab)
          .padding(.horizontal, 16)
          .padding(.bottom, 4)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .environmentObject(chrome)
    .animation(.easeInOut(duration: 0.2), value: chrome.isTabBarHidden)
    .tint(AppColors.primary)
    // Leaving the menu/cart (e.g. after Pay → Orders) must always bring the tab bar back.
    .onChange(of: chrome.selectedTab) { _, tab in
      // Home's menu/cart own hiding while that tab is active; everywhere else keep the bar.
      if tab != .home {
        chrome.isTabBarHidden = false
      }
    }
    // Live Activity / deep links: skippiodemo://orders → Active Orders.
    .onOpenURL { url in
      guard url.scheme == "skippiodemo" else { return }
      if url.host == "orders" || url.path.contains("orders") {
        chrome.isTabBarHidden = false
        chrome.selectedTab = .orders
      }
    }
  }
}

private struct FloatingTabBar: View {
  @Binding var selection: AppTab

  var body: some View {
    HStack(spacing: 0) {
      ForEach(AppTab.allCases, id: \.self) { tab in
        Button {
          selection = tab
        } label: {
          VStack(spacing: 4) {
            Image(systemName: selection == tab ? tab.selectedIcon : tab.icon)
              .font(.app(size: 22, weight: .regular))
              .frame(height: 26)
            Text(tab.title)
              .font(.app(size: 11, weight: .bold))
          }
          .foregroundStyle(selection == tab ? AppColors.primary : AppColors.mutedText)
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
      }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 8)
    .background(AppColors.card)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(AppColors.border, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 6)
  }
}
