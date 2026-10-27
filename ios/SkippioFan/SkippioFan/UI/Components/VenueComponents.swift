import SwiftUI

/// Remote image with a tidy fallback so cards never look broken while loading
/// or when a venue has no artwork.
struct VenueArtwork: View {
  enum Style {
    case hero
    case logo
  }

  let url: String?
  let initials: String
  let style: Style

  var body: some View {
    Group {
      if let url, let imageURL = URL(string: url) {
        AsyncImage(url: imageURL) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          default:
            fallback
          }
        }
      } else {
        fallback
      }
    }
  }

  @ViewBuilder
  private var fallback: some View {
    switch style {
    case .hero:
      LinearGradient(
        colors: [
          Color(red: 0.42, green: 0.50, blue: 0.60),
          Color(red: 0.70, green: 0.75, blue: 0.80)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .overlay(
        Image(systemName: "sportscourt")
          .font(.app(size: 44, weight: .light))
          .foregroundStyle(.white.opacity(0.55))
      )
    case .logo:
      AppColors.chipFill
        .overlay(
          Text(initials)
            .font(.app(size: 26, weight: .heavy))
            .foregroundStyle(AppColors.mutedText.opacity(0.8))
        )
    }
  }
}

struct StatusPill: View {
  let isOpen: Bool

  var body: some View {
    Text(isOpen ? "Open" : "Closed")
      .font(.app(size: 13, weight: .bold))
      .foregroundStyle(isOpen ? AppColors.openGreen : AppColors.closedRed)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(isOpen ? AppColors.openGreenBackground : AppColors.closedRedBackground)
      .clipShape(Capsule())
  }
}

struct FavouriteButton: View {
  let isFavourite: Bool
  let action: () -> Void
  var size: CGFloat = 44

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(AppColors.chipFill.opacity(0.9))
        .frame(width: size, height: size)
        .overlay(
          Image(systemName: isFavourite ? "heart.fill" : "heart")
            .font(.app(size: 17, weight: .medium))
            .foregroundStyle(isFavourite ? AppColors.primary : AppColors.text)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isFavourite ? "Remove from favourites" : "Add to favourites")
  }
}

/// Menu item photo with a soft placeholder while loading or when there is no photo.
struct ItemPhoto: View {
  let url: String?

  var body: some View {
    ZStack {
      AppColors.chipFill.opacity(0.7)
      if let url, let imageURL = URL(string: url) {
        AsyncImage(url: imageURL) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          default:
            placeholder
          }
        }
      } else {
        placeholder
      }
    }
  }

  private var placeholder: some View {
    Image(systemName: "cup.and.saucer.fill")
      .foregroundStyle(AppColors.primary.opacity(0.6))
  }
}

/// Small orange pill showing how many items are waiting in a venue's basket.
struct BasketBadge: View {
  let count: Int

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "bag.fill")
        .font(.app(size: 11, weight: .bold))
      Text("\(count)")
        .font(.app(size: 13, weight: .bold))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(AppColors.primary)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
    .accessibilityLabel("\(count) items in basket")
  }
}
