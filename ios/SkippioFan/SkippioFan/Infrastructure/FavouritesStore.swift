import Foundation

/// The user's favourite venues, stored in Supabase so they follow the account.
@MainActor
final class FavouritesStore: ObservableObject {
  @Published private(set) var ids: Set<UUID> = []
  @Published var errorMessage: String?

  private let repository = FavouritesRepository()

  func contains(_ venue: Venue) -> Bool { ids.contains(venue.id) }

  func load() async {
    do {
      ids = try await repository.fetchIDs()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func reset() {
    ids = []
  }

  /// Updates the heart immediately, then syncs; rolls back if the server refuses.
  func toggle(_ venue: Venue, userID: UUID) async {
    let wasFavourite = ids.contains(venue.id)
    if wasFavourite { ids.remove(venue.id) } else { ids.insert(venue.id) }

    do {
      if wasFavourite {
        try await repository.remove(venueID: venue.id, userID: userID)
      } else {
        try await repository.add(venueID: venue.id, userID: userID)
      }
    } catch {
      if wasFavourite { ids.insert(venue.id) } else { ids.remove(venue.id) }
      errorMessage = "Couldn't update your favourites. Please try again."
    }
  }
}
