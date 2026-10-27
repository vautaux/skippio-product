import AuthenticationServices
import UIKit

/// Presents a web page in a system browser sheet and returns when it redirects to
/// our custom URL scheme (that is how Stripe Checkout hands control back to the app).
@MainActor
final class WebAuthRunner: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func run(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
        if let callbackURL {
          continuation.resume(returning: callbackURL)
        } else {
          continuation.resume(throwing: error ?? URLError(.cancelled))
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      if !session.start() {
        continuation.resume(throwing: URLError(.cannotOpenFile))
      }
    }
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
  }
}

/// Runs the pay-for-an-order flow: get a Stripe Checkout page from the backend,
/// let the user pay, then wait for the webhook to confirm.
@MainActor
final class CheckoutCoordinator: ObservableObject {
  enum Outcome {
    /// Stripe confirmed payment and the order is now paid.
    case paid
    /// Payment went through at Stripe but our webhook hasn't confirmed it yet.
    case processing
    case cancelled
    case failed(String)
  }

  @Published private(set) var isWorking = false

  private let service = CheckoutService()
  private let orders = OrdersRepository()
  private let webAuth = WebAuthRunner()

  func pay(orderID: UUID) async -> Outcome {
    isWorking = true
    defer { isWorking = false }

    do {
      let session = try await service.checkoutSession(orderID: orderID)

      guard let urlString = session.checkoutURL, let url = URL(string: urlString) else {
        // Nothing to pay: the order is already past "pending payment".
        switch session.status {
        case "pending_payment": return .failed("We couldn't start the payment. Please try again.")
        case "cancelled": return .failed("This order was cancelled.")
        case "processing": return await waitForPayment(orderID: orderID, attempts: 10)
        default: return .paid
        }
      }

      let callback: URL
      do {
        callback = try await webAuth.run(url: url, callbackScheme: "skippiodemo")
      } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
        // User closed the page. They may have paid just before closing, so check once.
        return await waitForPayment(orderID: orderID, attempts: 1, cancelledIfUnpaid: true)
      }

      let result = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "result" })?.value

      if result == "success" {
        return await waitForPayment(orderID: orderID, attempts: 12)
      }
      return await waitForPayment(orderID: orderID, attempts: 1, cancelledIfUnpaid: true)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// The webhook is what marks an order paid, so poll briefly after the redirect.
  private func waitForPayment(orderID: UUID, attempts: Int, cancelledIfUnpaid: Bool = false) async -> Outcome {
    for attempt in 0..<attempts {
      if let status = try? await orders.fetchStatus(orderID: orderID), status != .pendingPayment {
        return status == .cancelled ? .cancelled : .paid
      }
      if attempt < attempts - 1 {
        try? await Task.sleep(nanoseconds: 800_000_000)
      }
    }
    // Don't leave the Pay button spinning forever if the webhook is slow — Orders
    // will catch up when the webhook lands.
    return cancelledIfUnpaid ? .cancelled : .processing
  }
}
