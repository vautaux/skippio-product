import Foundation
import Supabase

/// Owns the signed-in session. Backed by Supabase Auth (email + password); the
/// session itself is persisted in the keychain by the Supabase client.
@MainActor
final class AuthStore: ObservableObject {
  enum State: Equatable {
    case loading
    case signedOut
    case signedIn(AppUser)
  }

  enum SignUpResult {
    case signedIn
    case confirmationRequired
  }

  @Published private(set) var state: State = .loading

  var user: AppUser? {
    if case .signedIn(let user) = state { return user }
    return nil
  }

  private var listener: Task<Void, Never>?

  init() {
    listener = Task { [weak self] in
      await self?.bootstrap()
    }
  }

  deinit {
    listener?.cancel()
  }

  // MARK: Session lifecycle

  private func bootstrap() async {
    guard let client = SupabaseClientProvider.shared else {
      state = .signedOut
      return
    }

    #if DEBUG
    // UI tests start from a signed-out app even when the simulator kept an older session.
    if CommandLine.arguments.contains("-uitest-signout") {
      try? await client.auth.signOut(scope: .local)
    }
    #endif

    // `session` refreshes an expired token and throws when nobody is signed in.
    if let session = try? await client.auth.session {
      state = .signedIn(Self.map(session.user))
    } else {
      state = .signedOut
    }

    for await (event, session) in client.auth.authStateChanges {
      switch event {
      case .signedIn, .tokenRefreshed, .userUpdated:
        if let session { state = .signedIn(Self.map(session.user)) }
      case .signedOut, .userDeleted:
        state = .signedOut
      default:
        break
      }
    }
  }

  private static func map(_ user: User) -> AppUser {
    AppUser(
      id: user.id,
      email: user.email ?? "",
      fullName: user.userMetadata["full_name"]?.stringValue ?? "",
      provider: user.appMetadata["provider"]?.stringValue ?? "email"
    )
  }

  // MARK: Actions

  func signIn(email: String, password: String) async throws {
    let client = try Backend.client()
    let session = try await client.auth.signIn(email: email, password: password)
    state = .signedIn(Self.map(session.user))
  }

  func signUp(firstName: String, lastName: String, email: String, password: String) async throws -> SignUpResult {
    let client = try Backend.client()
    let fullName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    let response = try await client.auth.signUp(
      email: email,
      password: password,
      data: [
        "full_name": .string(fullName),
        "first_name": .string(firstName),
        "last_name": .string(lastName),
      ]
    )

    if let session = response.session {
      state = .signedIn(Self.map(session.user))
      return .signedIn
    }
    // The project requires email confirmation: a 6-digit code was emailed.
    return .confirmationRequired
  }

  /// Confirms the 6-digit code from the sign-up email and signs the user in.
  func verifySignUpCode(email: String, code: String) async throws {
    let client = try Backend.client()
    let response = try await client.auth.verifyOTP(email: email, token: code, type: .signup)
    guard let session = response.session else {
      throw BackendError(message: "That code didn't work. Please try again.")
    }
    state = .signedIn(Self.map(session.user))
  }

  func resendSignUpCode(email: String) async throws {
    let client = try Backend.client()
    try await client.auth.resend(email: email, type: .signup)
  }

  func signOut() async {
    if let client = SupabaseClientProvider.shared {
      try? await client.auth.signOut()
    }
    state = .signedOut
  }

  func deleteAccount() async throws {
    try await EdgeFunctions.callWithoutResult("delete-account")
    // The server-side session is gone; clear the local one without calling the server again.
    if let client = SupabaseClientProvider.shared {
      try? await client.auth.signOut(scope: .local)
    }
    state = .signedOut
  }

  func updateName(_ name: String) async throws {
    let client = try Backend.client()
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let updated = try await client.auth.update(user: UserAttributes(data: ["full_name": .string(trimmed)]))

    // Keep the profiles table (used server-side) in step with the auth metadata.
    try await client
      .from("profiles")
      .update(["full_name": trimmed])
      .eq("id", value: updated.id.uuidString)
      .execute()

    state = .signedIn(Self.map(updated))
  }
}
