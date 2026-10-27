import MapKit
import SwiftUI

/// Every venue and café with a known location, plotted on a map.
struct VenueMapView: View {
  let venues: [Venue]
  let onOpenMenu: (Venue) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selected: Venue?
  @State private var position: MapCameraPosition = .automatic

  private var mappable: [Venue] {
    venues.filter { $0.latitude != nil && $0.longitude != nil }
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      Map(position: $position) {
        UserAnnotation()

        ForEach(mappable) { venue in
          if let lat = venue.latitude, let lon = venue.longitude {
            Annotation(venue.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
              pin(for: venue)
                .onTapGesture { selected = venue }
            }
          }
        }
      }
      .mapControls {
        MapUserLocationButton()
        MapCompass()
      }
      .ignoresSafeArea()

      VStack {
        HStack {
          Spacer()
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.app(size: 15, weight: .bold))
              .foregroundStyle(AppColors.text)
              .frame(width: 40, height: 40)
              .background(AppColors.card)
              .clipShape(Circle())
              .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        Spacer()
      }

      if let venue = selected {
        selectionCard(venue)
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      } else if mappable.isEmpty {
        Text("No venues have a location yet.")
          .font(.app(size: 15, weight: .semibold))
          .padding(14)
          .background(AppColors.card)
          .clipShape(Capsule())
          .padding(.bottom, 24)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: selected)
  }

  private func pin(for venue: Venue) -> some View {
    let isSelected = selected?.id == venue.id
    let icon: String = {
      switch venue.kind {
      case .cafe: return "cup.and.saucer.fill"
      case .restaurant: return "fork.knife"
      default: return "ticket.fill"
      }
    }()
    return Image(systemName: icon)
      .font(.app(size: isSelected ? 18 : 15, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: isSelected ? 42 : 34, height: isSelected ? 42 : 34)
      .background(venue.isOpen ? AppColors.primary : Color.gray)
      .clipShape(Circle())
      .overlay(Circle().stroke(Color.white, lineWidth: 2))
      .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
  }

  private func selectionCard(_ venue: Venue) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(venue.name)
            .font(.app(size: 19, weight: .bold))
            .foregroundStyle(AppColors.text)
          Text(venue.address)
            .font(.app(size: 14))
            .foregroundStyle(AppColors.mutedText)
        }
        Spacer()
        StatusPill(isOpen: venue.isOpen)
      }

      Button {
        dismiss()
        onOpenMenu(venue)
      } label: {
        Text("View menu")
          .font(.app(size: 15, weight: .bold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 46)
          .background(AppColors.primary)
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
    }
    .padding(16)
    .background(AppColors.card)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.15), radius: 14, y: 4)
  }
}
