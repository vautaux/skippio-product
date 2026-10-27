import SwiftUI

/// Attribution for every licensed photo in the catalog (required by CC BY / CC BY-SA).
struct ImageCreditsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var chrome: AppChrome

  @State private var credits: [ImageCredit] = []
  @State private var isLoading = true
  @State private var errorMessage: String?

  private let repository = ImageCreditsRepository()

  var body: some View {
    ZStack {
      AppColors.background.ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Photos of venues, drinks and food come from Wikimedia Commons and are used under the licences below. Tap a photo title to see its source.")
            .font(.app(size: 15))
            .foregroundStyle(AppColors.mutedText)

          if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
          } else if let errorMessage {
            Text(errorMessage)
              .font(.app(size: 15))
              .foregroundStyle(AppColors.closedRed)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                if index > 0 { Divider().padding(.leading, 16) }
                creditRow(credit)
              }
            }
            .appCardStyle(radius: 18)
          }

          Text("Typeface: Source Sans 3 by Adobe, SIL Open Font License 1.1.")
            .font(.app(size: 13))
            .foregroundStyle(AppColors.mutedText)
            .padding(.top, 6)
        }
        .padding(.horizontal, AppSpacing.screenHorizontal)
        .padding(.top, 14)
        .padding(.bottom, AppSpacing.tabBarClearance)
      }
    }
    .navigationTitle("Image credits")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private func creditRow(_ credit: ImageCredit) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let url = URL(string: credit.sourceURL) {
        Link(destination: url) {
          Text(credit.title)
            .font(.app(size: 15, weight: .bold))
            .foregroundStyle(AppColors.text)
            .multilineTextAlignment(.leading)
        }
      }
      Text("\(credit.author) \u{00B7} \(credit.license)")
        .font(.app(size: 13))
        .foregroundStyle(AppColors.mutedText)
        .multilineTextAlignment(.leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func load() async {
    do {
      credits = try await repository.fetch()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }
}
