import ActivityKit
import SwiftUI
import WidgetKit

private enum LiveTheme {
  static let orange = Color(red: 0.93, green: 0.48, blue: 0.12)
  static let ink = Color(red: 0.12, green: 0.10, blue: 0.08)
  static let muted = Color(red: 0.35, green: 0.32, blue: 0.28)
  static let cream = Color(red: 0.99, green: 0.97, blue: 0.94)
  static let chip = Color(red: 1.0, green: 0.93, blue: 0.84)
  static let ready = Color(red: 0.12, green: 0.55, blue: 0.32)
}

private let ordersDeepLink = URL(string: "skippiodemo://orders")!

struct OrderLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: OrderActivityAttributes.self) { context in
      lockScreen(context: context)
        .activityBackgroundTint(LiveTheme.cream)
        .activitySystemActionForegroundColor(LiveTheme.ink)
        .widgetURL(ordersDeepLink)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text("Skippio")
            .font(.headline.weight(.bold))
            .foregroundStyle(LiveTheme.orange)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.statusLabel)
            .font(.headline.weight(.bold))
            .foregroundStyle(context.state.statusRaw == "ready" ? LiveTheme.ready : LiveTheme.ink)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.attributes.venueName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LiveTheme.ink)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.detail)
            .font(.caption)
            .foregroundStyle(LiveTheme.muted)
            .lineLimit(2)
        }
      } compactLeading: {
        Image(systemName: context.state.statusRaw == "ready" ? "checkmark.circle.fill" : "cup.and.saucer.fill")
          .foregroundStyle(LiveTheme.orange)
      } compactTrailing: {
        Text(context.state.statusLabel)
          .font(.caption2.weight(.bold))
          .foregroundStyle(context.state.statusRaw == "ready" ? LiveTheme.ready : .white)
      } minimal: {
        Image(systemName: context.state.statusRaw == "ready" ? "checkmark.circle.fill" : "cup.and.saucer.fill")
          .foregroundStyle(LiveTheme.orange)
      }
      .widgetURL(ordersDeepLink)
    }
  }

  @ViewBuilder
  private func lockScreen(context: ActivityViewContext<OrderActivityAttributes>) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center) {
        Text("Skippio")
          .font(.caption.weight(.heavy))
          .foregroundStyle(LiveTheme.orange)
        Spacer(minLength: 8)
        Text(context.state.statusLabel)
          .font(.caption.weight(.bold))
          .foregroundStyle(context.state.statusRaw == "ready" ? LiveTheme.ready : LiveTheme.ink)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(context.state.statusRaw == "ready" ? LiveTheme.ready.opacity(0.15) : LiveTheme.chip)
          .clipShape(Capsule())
      }

      Text(context.attributes.venueName)
        .font(.title3.weight(.bold))
        .foregroundStyle(LiveTheme.ink)
        .lineLimit(2)
        .minimumScaleFactor(0.85)

      Text(context.state.detail)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(LiveTheme.muted)
        .lineLimit(2)

      if context.state.statusRaw == "ready" {
        Text(context.attributes.isSeatDelivery ? "On the way to your seat" : "Ready to collect")
          .font(.title3.weight(.heavy))
          .foregroundStyle(LiveTheme.ready)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(LiveTheme.cream)
  }
}
