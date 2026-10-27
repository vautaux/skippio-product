import CoreLocation
import Foundation

/// Provides the user's coarse location so venues can show a real distance.
/// If permission is denied, `location` stays nil and the UI simply omits distances.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var location: CLLocation?

  private let manager = CLLocationManager()

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
  }

  func start() {
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      manager.requestLocation()
    default:
      break
    }
  }

  func distanceKm(to venue: Venue) -> Double? {
    guard let location, let lat = venue.latitude, let lon = venue.longitude else { return nil }
    return location.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
  }

  // MARK: - CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    if status == .authorizedWhenInUse || status == .authorizedAlways {
      manager.requestLocation()
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let latest = locations.last else { return }
    Task { @MainActor in
      self.location = latest
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Distances are optional; failing to get a fix just hides them.
  }
}
