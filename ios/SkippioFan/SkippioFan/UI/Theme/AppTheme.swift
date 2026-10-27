import SwiftUI

enum AppColors {
  static let background = Color(red: 0.961, green: 0.945, blue: 0.918)
  static let backgroundSoft = Color(red: 0.98, green: 0.97, blue: 0.95)
  /// Neutral grey used behind the Rewards list.
  static let screenGrey = Color(red: 0.949, green: 0.949, blue: 0.949)
  /// Slightly warm white used for cards.
  static let card = Color(red: 1.0, green: 0.992, blue: 0.973)
  static let primary = Color(red: 0.961, green: 0.627, blue: 0.231)
  static let primaryLight = Color(red: 0.99, green: 0.90, blue: 0.78)
  static let text = Color(red: 0.12, green: 0.11, blue: 0.10)
  static let mutedText = Color(red: 0.45, green: 0.42, blue: 0.38)
  static let border = Color(red: 0.92, green: 0.90, blue: 0.86)
  /// Pale beige used behind the heart button and inactive pills.
  static let chipFill = Color(red: 0.937, green: 0.918, blue: 0.882)

  static let openGreen = Color(red: 0.13, green: 0.55, blue: 0.29)
  static let openGreenBackground = Color(red: 0.86, green: 0.95, blue: 0.88)
  static let closedRed = Color(red: 0.86, green: 0.13, blue: 0.20)
  static let closedRedBackground = Color(red: 0.99, green: 0.89, blue: 0.89)
}

/// Source Sans 3 (SIL Open Font License, bundled in Resources/Fonts), the closest
/// open-licence match for the humanist sans used in the reference screenshots.
extension Font {
  static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let face: String
    switch weight {
    case .black, .heavy: face = "SourceSans3-Black"
    case .bold: face = "SourceSans3-Bold"
    case .semibold, .medium: face = "SourceSans3-Semibold"
    default: face = "SourceSans3-Regular"
    }
    // Source Sans runs a little smaller than SF at the same point size.
    return .custom(face, fixedSize: size * 1.06)
  }
}

enum AppSpacing {
  static let screenHorizontal: CGFloat = 20
  static let cardRadius: CGFloat = 24
  static let smallCardRadius: CGFloat = 14
  /// Space reserved at the bottom of scrolling content for the floating tab bar.
  static let tabBarClearance: CGFloat = 112
}

extension View {
  func appCardStyle(radius: CGFloat = AppSpacing.cardRadius) -> some View {
    self
      .background(AppColors.card)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(AppColors.border, lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 3)
  }
}
