import SwiftUI

struct RewardsView: View {
  @State private var wallet: RewardWallet = .empty
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var selectedTab = 0

  private let repository = RewardsRepository()

  var body: some View {
    VStack(spacing: 0) {
      // Cream title block that runs up under the status bar.
      Text("Rewards")
        .font(.app(size: 24, weight: .heavy))
        .foregroundStyle(AppColors.text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.screenHorizontal)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(AppColors.background.ignoresSafeArea(edges: .top))

      HStack(spacing: 10) {
        rewardsSegment(title: "Available", count: wallet.availablePoints, tag: 0)
        rewardsSegment(title: "Upcoming", count: wallet.upcomingPoints, tag: 1)
        rewardsSegment(title: "Expired", count: wallet.expiredPoints, tag: 2)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.top, 10)

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .background(AppColors.screenGrey.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task {
      await loadWallet()
    }
  }

  @ViewBuilder
  private var content: some View {
    if isLoading {
      ProgressView()
        .padding(.top, 60)
    } else if let errorMessage {
      statusMessage(title: "Could not load rewards", detail: errorMessage)
    } else if selectedCount == 0 {
      statusMessage(
        title: "Sorry, at the moment there\nare no rewards listed!",
        detail: "If there are any new available\nrewards, they'll show up here!"
      )
    } else {
      rewardCard(title: selectedTitle, count: selectedCount)
        .padding(.horizontal, AppSpacing.screenHorizontal)
        .padding(.top, 20)
    }
  }

  private var selectedTitle: String {
    ["Available", "Upcoming", "Expired"][selectedTab]
  }

  private var selectedCount: Int {
    switch selectedTab {
    case 0: return wallet.availablePoints
    case 1: return wallet.upcomingPoints
    default: return wallet.expiredPoints
    }
  }

  private func rewardsSegment(title: String, count: Int, tag: Int) -> some View {
    let active = selectedTab == tag
    return Button {
      selectedTab = tag
    } label: {
      HStack(spacing: 7) {
        Text(title)
          .lineLimit(1)
        Text("\(count)")
          .lineLimit(1)
          .opacity(active ? 1 : 0.5)
      }
      .font(.app(size: 14, weight: .bold))
      .minimumScaleFactor(0.85)
      .padding(.horizontal, 16)
      .frame(height: 36)
      .foregroundStyle(active ? Color.white : AppColors.mutedText)
      .background(active ? AppColors.primary : AppColors.chipFill.opacity(0.45))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func rewardCard(title: String, count: Int) -> some View {
    HStack {
      Text(title)
        .font(.app(size: 16, weight: .bold))
        .foregroundStyle(AppColors.text)
      Spacer()
      Text("\(count)")
        .font(.app(size: 20, weight: .bold))
        .foregroundStyle(AppColors.text)
    }
    .padding(16)
    .appCardStyle(radius: 16)
  }

  private func statusMessage(title: String, detail: String) -> some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.app(size: 18, weight: .heavy))
        .foregroundStyle(AppColors.text)
        .multilineTextAlignment(.center)
      Text(detail)
        .font(.app(size: 15))
        .foregroundStyle(AppColors.text)
        .multilineTextAlignment(.center)
    }
    .padding(.top, 28)
    .padding(.horizontal, 12)
  }

  private func loadWallet() async {
    isLoading = true
    defer { isLoading = false }

    do {
      wallet = try await repository.fetchWallet()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
