import Foundation
import Supabase

enum AppConfig {
  // Used only when the Xcode build settings did not inject a URL and key.
  // Real values stay in the local xcconfig files, which are not committed.
  private static let fallbackSupabaseURL = ""
  private static let fallbackAnonKey = ""

  private static func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  static var configurationError: String? {
    let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
    let rawKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? ""

    let url = normalized(rawURL)
    let key = normalized(rawKey)

    let hasValidURL = !url.isEmpty && !url.contains("$(") && URL(string: url)?.host?.isEmpty == false
    let hasValidKey = !key.isEmpty && !key.contains("$(") && key != "your-anon-key"
    let fallbackHasValidURL = URL(string: fallbackSupabaseURL)?.host?.isEmpty == false
    let fallbackHasValidKey = !fallbackAnonKey.isEmpty

    if !hasValidURL && !fallbackHasValidURL {
      return "SUPABASE_URL must contain a valid host"
    }
    if !hasValidKey && !fallbackHasValidKey {
      return "SUPABASE_ANON_KEY is missing or placeholder"
    }

    return nil
  }

  static var supabaseURL: URL? {
    guard configurationError == nil else { return nil }
    let rawURL = normalized(Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? "")
    if !rawURL.isEmpty, !rawURL.contains("$("), let url = URL(string: rawURL), url.host?.isEmpty == false {
      return url
    }
    return URL(string: fallbackSupabaseURL)
  }

  static var supabaseAnonKey: String? {
    guard configurationError == nil else { return nil }
    let key = normalized(Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? "")
    if !key.isEmpty, !key.contains("$("), key != "your-anon-key" {
      return key
    }
    return fallbackAnonKey
  }
}

enum SupabaseClientProvider {
  static let isConfigured = AppConfig.configurationError == nil

  /// One client for the whole app. Auth state (session, refresh timer, listeners)
  /// lives inside it, so creating a new one per call would lose the signed-in user.
  static let shared: SupabaseClient? = {
    guard
      let url = AppConfig.supabaseURL,
      let key = AppConfig.supabaseAnonKey
    else {
      return nil
    }

    return SupabaseClient(supabaseURL: url, supabaseKey: key)
  }()
}
