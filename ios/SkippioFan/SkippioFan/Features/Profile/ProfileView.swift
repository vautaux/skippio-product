import CoreImage.CIFilterBuiltins
import SwiftUI

struct ProfileView: View {
  @EnvironmentObject private var auth: AuthStore
  @EnvironmentObject private var chrome: AppChrome

  @State private var showCode = false
  @State private var showAccount = false
  @State private var confirmLogout = false
  @State private var confirmDelete = false
  @State private var isDeleting = false
  @State private var errorMessage: String?

  private let siteURL = URL(string: "https://www.skippio.io")!
  private let darkCard = Color(red: 0.14, green: 0.11, blue: 0.09)

  var body: some View {
    ZStack(alignment: .top) {
      AppColors.background.ignoresSafeArea()

      VStack(spacing: 0) {
        header

        ScrollView(.vertical, showsIndicators: false) {
          VStack(spacing: 16) {
            identityCard

            Button { showCode = true } label: { showCodeCard }
              .buttonStyle(.plain)

            section(title: "ACCOUNT") {
              Button { showAccount = true } label: {
                profileRow(title: "Account", icon: "person.crop.circle")
              }
              .buttonStyle(.plain)
            }

            section(title: "ABOUT") {
              Link(destination: siteURL) { profileRow(title: "About Skippio", external: true) }
              Divider().padding(.leading, 16)
              Link(destination: siteURL) { profileRow(title: "Terms of Use", external: true) }
              Divider().padding(.leading, 16)
              Link(destination: siteURL) { profileRow(title: "Privacy Policy", external: true) }
              Divider().padding(.leading, 16)
              NavigationLink { ImageCreditsView() } label: { profileRow(title: "Image credits") }
                .buttonStyle(.plain)
            }

            Button { confirmLogout = true } label: {
              Text("Log out")
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.text)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .appCardStyle(radius: 14)
            }
            .buttonStyle(.plain)

            Button { confirmDelete = true } label: {
              if isDeleting {
                ProgressView()
              } else {
                Text("Delete account")
                  .font(.app(size: 15, weight: .semibold))
                  .foregroundStyle(Color.red)
              }
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .padding(.top, 4)

            if let errorMessage {
              Text(errorMessage)
                .font(.app(size: 13))
                .foregroundStyle(AppColors.closedRed)
                .multilineTextAlignment(.center)
            }

            Text("v\(appVersion)")
              .font(.app(size: 13))
              .foregroundStyle(AppColors.mutedText)
              .padding(.bottom, AppSpacing.tabBarClearance)
          }
          .padding(.horizontal, AppSpacing.screenHorizontal)
          .padding(.top, 16)
        }
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: $showCode) {
      if let user = auth.user { CodeSheet(user: user) }
    }
    .sheet(isPresented: $showAccount) {
      AccountSheet()
    }
    .confirmationDialog("Log out of Skippio?", isPresented: $confirmLogout, titleVisibility: .visible) {
      Button("Log out", role: .destructive) {
        Task { await auth.signOut() }
      }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Delete your account?",
      isPresented: $confirmDelete,
      titleVisibility: .visible
    ) {
      Button("Delete account", role: .destructive) {
        Task { await deleteAccount() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes your account, favourites and order history. It can't be undone.")
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  private func deleteAccount() async {
    errorMessage = nil
    isDeleting = true
    defer { isDeleting = false }
    do {
      try await auth.deleteAccount()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      Button {
        chrome.selectedTab = .home
      } label: {
        Circle()
          .fill(Color.white.opacity(0.28))
          .frame(width: 40, height: 40)
          .overlay(
            Image(systemName: "chevron.left")
              .font(.app(size: 15, weight: .bold))
              .foregroundStyle(.white)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Back to Home")

      Text("Profile")
        .font(.app(size: 20, weight: .heavy))
        .foregroundStyle(.white)

      Spacer()
    }
    .padding(.horizontal, AppSpacing.screenHorizontal)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    // Extends the orange band up under the status bar.
    .background(AppColors.primary.ignoresSafeArea(edges: .top))
  }

  // MARK: - Cards

  private var identityCard: some View {
    HStack(spacing: 16) {
      avatar

      VStack(alignment: .leading, spacing: 4) {
        Text(auth.user?.displayName ?? "")
          .font(.app(size: 21, weight: .bold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .foregroundStyle(.white)
        Text(auth.user?.email ?? "")
          .font(.app(size: 14))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .foregroundStyle(.white.opacity(0.7))
      }

      Spacer(minLength: 0)
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(darkCard)
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
  }

  /// Initial-on-gradient avatar. The Google badge only shows for Google sign-ins.
  private var avatar: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [AppColors.primary, AppColors.primary.opacity(0.6)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .frame(width: 70, height: 70)
      .overlay(
        Text(auth.user?.initial ?? "")
          .font(.app(size: 28, weight: .bold))
          .foregroundStyle(.white)
      )
      .overlay(alignment: .bottomTrailing) {
        if auth.user?.isGoogle == true {
          Circle()
            .fill(Color.white)
            .frame(width: 24, height: 24)
            .overlay(
              Text("G")
                .font(.app(size: 14, weight: .heavy))
                .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
            )
            .overlay(Circle().stroke(darkCard, lineWidth: 2))
            .offset(x: 2, y: 2)
        }
      }
  }

  private var showCodeCard: some View {
    HStack(spacing: 16) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(darkCard)
        .frame(width: 48, height: 48)
        .overlay(
          Image(systemName: "qrcode")
            .font(.app(size: 24))
            .foregroundStyle(AppColors.primary)
        )

      Text("Show my code")
        .font(.app(size: 15, weight: .bold))
        .foregroundStyle(AppColors.text)

      Spacer()

      Image(systemName: "chevron.right")
        .font(.app(size: 14, weight: .semibold))
        .foregroundStyle(AppColors.primary)
    }
    .padding(14)
    .background(AppColors.card)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(AppColors.primary.opacity(0.55), lineWidth: 1)
    )
  }

  // MARK: - Sections

  private func section<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.app(size: 12, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(AppColors.mutedText)
        .padding(.leading, 4)

      VStack(spacing: 0) {
        content()
      }
      .appCardStyle(radius: 18)
    }
  }

  private func profileRow(title: String, icon: String? = nil, external: Bool = false) -> some View {
    HStack(spacing: 12) {
      if let icon {
        Image(systemName: icon)
          .font(.app(size: 17))
          .foregroundStyle(AppColors.text)
          .frame(width: 28)
      }

      Text(title)
        .font(.app(size: 15, weight: .semibold))
        .foregroundStyle(AppColors.text)

      Spacer()

      Image(systemName: external ? "arrow.up.right" : "chevron.right")
        .font(.app(size: 13, weight: .semibold))
        .foregroundStyle(AppColors.mutedText)
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
    .contentShape(Rectangle())
  }
}

// MARK: - Sheets

/// A QR code of the user's id, to be scanned by venue staff.
private struct CodeSheet: View {
  let user: AppUser
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 20) {
      Text("My code")
        .font(.app(size: 22, weight: .heavy))
        .foregroundStyle(AppColors.text)
        .padding(.top, 28)

      if let image = qrImage(for: user.id.uuidString) {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 240, height: 240)
          .padding(20)
          .background(Color.white)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      }

      Text(user.displayName)
        .font(.app(size: 17, weight: .bold))
        .foregroundStyle(AppColors.text)

      Text("Show this to venue staff to identify your account.")
        .font(.app(size: 14))
        .foregroundStyle(AppColors.mutedText)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      Spacer()

      Button("Done") { dismiss() }
        .font(.app(size: 16, weight: .bold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(AppColors.primary)
        .clipShape(Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
    .frame(maxWidth: .infinity)
    .background(AppColors.background.ignoresSafeArea())
    .presentationDetents([.large])
  }

  private func qrImage(for text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

private struct AccountSheet: View {
  @EnvironmentObject private var auth: AuthStore
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var isSaving = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Name") {
          TextField("Full name", text: $name)
            .textContentType(.name)
        }
        Section("Email") {
          Text(auth.user?.email ?? "")
            .foregroundStyle(AppColors.mutedText)
        }
        if let errorMessage {
          Section {
            Text(errorMessage).foregroundStyle(AppColors.closedRed)
          }
        }
      }
      .navigationTitle("Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            if isSaving { ProgressView() } else { Text("Save") }
          }
          .disabled(isSaving || trimmedName.isEmpty || trimmedName == auth.user?.fullName)
        }
      }
      .onAppear { name = auth.user?.fullName ?? "" }
    }
    .presentationDetents([.medium])
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func save() async {
    errorMessage = nil
    isSaving = true
    defer { isSaving = false }
    do {
      try await auth.updateName(trimmedName)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
