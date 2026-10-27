import SwiftUI

@main
struct SkippioFanApp: App {
  @StateObject private var auth = AuthStore()
  @StateObject private var favourites = FavouritesStore()
  @StateObject private var cart = CartStore()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(auth)
        .environmentObject(favourites)
        .environmentObject(cart)
        // The design is a light, warm theme. Without this, iPhones in dark mode
        // render all default text white on the cream background.
        .preferredColorScheme(.light)
    }
  }
}

/// Chooses between the loading splash, sign-in and the app itself.
struct RootView: View {
  @EnvironmentObject private var auth: AuthStore
  @EnvironmentObject private var favourites: FavouritesStore
  @EnvironmentObject private var cart: CartStore

  var body: some View {
    switch auth.state {
    case .loading:
      ZStack {
        AppColors.background.ignoresSafeArea()
        ProgressView()
      }
    case .signedOut:
      AuthView()
        .onAppear {
          // Never carry one user's data into the next session.
          favourites.reset()
          cart.bind(userID: nil)
        }
    case .signedIn(let user):
      RootTabView()
        .task(id: user.id) {
          // Baskets are kept per user, so load this user's before anything else.
          cart.bind(userID: user.id)
          await favourites.load()
        }
    }
  }
}
