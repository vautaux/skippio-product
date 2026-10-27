import SwiftUI

/// Create account / log in, then (for new accounts) the emailed confirmation code.
struct AuthView: View {
  @EnvironmentObject private var auth: AuthStore

  private enum Mode { case signUp, signIn, verify }
  private enum Field { case firstName, lastName, email, password, code }

  @State private var mode: Mode = .signUp
  @State private var firstName = ""
  @State private var lastName = ""
  @State private var email = ""
  @State private var password = ""
  @State private var showPassword = false
  @State private var code = ""
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var infoMessage: String?
  @State private var resendCooldown = 0
  @FocusState private var focused: Field?

  var body: some View {
    ZStack(alignment: .top) {
      AppColors.primary.ignoresSafeArea()

      VStack(spacing: 0) {
        Text("Skippio")
          .font(.app(size: 46, weight: .heavy))
          .tracking(-1)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: focused == nil ? 170 : 96)
          .padding(.top, focused == nil ? 20 : 4)
          .animation(.easeInOut(duration: 0.2), value: focused)

        ZStack {
          Color.white
          ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
              VStack(alignment: .leading, spacing: 18) {
                switch mode {
                case .signUp: signUpForm
                case .signIn: signInForm
                case .verify: verifyForm
                }
              }
              .padding(.horizontal, 24)
              .padding(.top, 30)
              // Extra room so the password / code field can scroll above the keyboard.
              .padding(.bottom, focused == nil ? 40 : 280)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: focused) { _, field in
              guard let field else { return }
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeInOut(duration: 0.25)) {
                  proxy.scrollTo(field, anchor: .center)
                }
              }
            }
          }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30))
        // Keep the home-indicator area filled, but still shrink for the keyboard.
        .ignoresSafeArea(.container, edges: .bottom)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focused = nil }
          .font(.app(size: 17, weight: .semibold))
      }
    }
  }

  // MARK: - Forms

  @ViewBuilder
  private var signUpForm: some View {
    Text("Create Account")
      .font(.app(size: 32, weight: .heavy))
      .foregroundStyle(AppColors.text)

    HStack(spacing: 4) {
      Text("Already have an account?")
        .foregroundStyle(AppColors.mutedText)
      Button("Login here") { switchMode(.signIn) }
        .foregroundStyle(AppColors.primary)
        .accessibilityIdentifier("switch-to-login")
    }
    .font(.app(size: 16, weight: .semibold))

    VStack(spacing: 0) {
      plainField("First Name", text: $firstName, field: .firstName)
        .textContentType(.givenName)
      Divider()
      plainField("Last Name", text: $lastName, field: .lastName)
        .textContentType(.familyName)
    }
    .modifier(FieldBox())

    plainField("Email", text: $email, field: .email)
      .keyboardType(.emailAddress)
      .textContentType(.emailAddress)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .modifier(FieldBox())

    passwordField(placeholder: "Password")

    Text("At least 8 characters.")
      .font(.app(size: 13))
      .foregroundStyle(AppColors.mutedText)
      .padding(.top, -8)

    messages
    primaryButton("Sign up", id: "auth-submit", enabled: canSubmit) { submit() }
  }

  @ViewBuilder
  private var signInForm: some View {
    Text("Login")
      .font(.app(size: 32, weight: .heavy))
      .foregroundStyle(AppColors.text)

    HStack(spacing: 4) {
      Text("New to Skippio?")
        .foregroundStyle(AppColors.mutedText)
      Button("Create an account") { switchMode(.signUp) }
        .foregroundStyle(AppColors.primary)
        .accessibilityIdentifier("switch-to-signup")
    }
    .font(.app(size: 16, weight: .semibold))

    plainField("Email", text: $email, field: .email)
      .keyboardType(.emailAddress)
      .textContentType(.emailAddress)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .modifier(FieldBox())

    passwordField(placeholder: "Password")

    messages
    primaryButton("Login", id: "auth-submit", enabled: canSubmit) { submit() }
  }

  @ViewBuilder
  private var verifyForm: some View {
    Text("Check your email")
      .font(.app(size: 32, weight: .heavy))
      .foregroundStyle(AppColors.text)

    Text("We sent a code to \(trimmedEmail). Enter it below to confirm your account.")
      .font(.app(size: 16))
      .foregroundStyle(AppColors.mutedText)

    TextField("000000", text: $code)
      .keyboardType(.numberPad)
      .textContentType(.oneTimeCode)
      .focused($focused, equals: .code)
      .font(.app(size: 28, weight: .bold))
      .tracking(6)
      .multilineTextAlignment(.center)
      .frame(height: 70)
      .modifier(FieldBox())
      .id(Field.code)
      .accessibilityIdentifier("auth-code")
      .onChange(of: code) { _, value in
        // Supabase defaults to 8-digit email OTPs; we pin the project to 6.
        let digits = String(value.filter(\.isNumber).prefix(8))
        if digits != value { code = digits }
        if (digits.count == 6 || digits.count == 8), !isWorking { submit() }
      }

    messages
    primaryButton("Confirm", id: "auth-verify", enabled: code.count == 6 || code.count == 8) { submit() }

    HStack {
      Button(resendCooldown > 0 ? "Resend code in \(resendCooldown)s" : "Resend code") {
        Task { await resend() }
      }
      .disabled(resendCooldown > 0 || isWorking)
      .font(.app(size: 16, weight: .semibold))
      .foregroundStyle(resendCooldown > 0 ? AppColors.mutedText : AppColors.primary)

      Spacer()

      Button("Use a different email") { switchMode(.signUp) }
        .font(.app(size: 16, weight: .semibold))
        .foregroundStyle(AppColors.mutedText)
    }
    .onAppear { focused = .code }
  }

  // MARK: - Pieces

  @ViewBuilder
  private var messages: some View {
    if let errorMessage {
      Text(errorMessage)
        .font(.app(size: 15, weight: .semibold))
        .foregroundStyle(AppColors.closedRed)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    if let infoMessage {
      Text(infoMessage)
        .font(.app(size: 15, weight: .semibold))
        .foregroundStyle(AppColors.openGreen)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func plainField(_ placeholder: String, text: Binding<String>, field target: Field) -> some View {
    TextField(placeholder, text: text)
      .font(.app(size: 18))
      .foregroundStyle(AppColors.text)
      .focused($focused, equals: target)
      .submitLabel(.next)
      .onSubmit { advance(from: target) }
      .padding(.horizontal, 16)
      .frame(height: 58)
      .id(target)
  }

  private func passwordField(placeholder: String) -> some View {
    HStack(spacing: 8) {
      Group {
        if showPassword {
          TextField(placeholder, text: $password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } else {
          SecureField(placeholder, text: $password)
        }
      }
      .font(.app(size: 18))
      .foregroundStyle(AppColors.text)
      .textContentType(mode == .signUp ? .newPassword : .password)
      .focused($focused, equals: .password)
      .submitLabel(.go)
      .onSubmit { if canSubmit { submit() } }

      Button { showPassword.toggle() } label: {
        Image(systemName: showPassword ? "eye.slash" : "eye")
          .font(.app(size: 17))
          .foregroundStyle(AppColors.mutedText)
          .frame(width: 36, height: 36)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(showPassword ? "Hide password" : "Show password")
    }
    .padding(.horizontal, 16)
    .frame(height: 58)
    .modifier(FieldBox())
    .id(Field.password)
  }

  private func primaryButton(_ title: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      ZStack {
        if isWorking {
          ProgressView().tint(.white)
        } else {
          Text(title)
            .font(.app(size: 20, weight: .bold))
        }
      }
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .frame(height: 58)
      .background(enabled ? AppColors.primary : AppColors.primary.opacity(0.45))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!enabled || isWorking)
    .accessibilityIdentifier(id)
    .padding(.top, 6)
  }

  // MARK: - Logic

  private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var canSubmit: Bool {
    guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else { return false }
    switch mode {
    case .signIn:
      return !password.isEmpty
    case .signUp:
      return password.count >= 8 && !firstName.trimmingCharacters(in: .whitespaces).isEmpty
    case .verify:
      return code.count == 6 || code.count == 8
    }
  }

  private func switchMode(_ target: Mode) {
    mode = target
    errorMessage = nil
    infoMessage = nil
    code = ""
    focused = nil
  }

  private func advance(from field: Field) {
    switch field {
    case .firstName: focused = .lastName
    case .lastName: focused = .email
    case .email: focused = .password
    case .password, .code: focused = nil
    }
  }

  private func submit() {
    focused = nil
    errorMessage = nil
    infoMessage = nil
    isWorking = true

    Task {
      defer { isWorking = false }
      do {
        switch mode {
        case .signIn:
          try await signIn()
        case .signUp:
          let result = try await auth.signUp(
            firstName: firstName.trimmingCharacters(in: .whitespaces),
            lastName: lastName.trimmingCharacters(in: .whitespaces),
            email: trimmedEmail,
            password: password
          )
          if result == .confirmationRequired { showCodeScreen() }
        case .verify:
          try await auth.verifySignUpCode(email: trimmedEmail, code: code)
        }
      } catch {
        errorMessage = friendly(error)
        if mode == .verify { code = "" }
      }
    }
  }

  /// Signing in with an account that never confirmed its email sends a fresh code.
  private func signIn() async throws {
    do {
      try await auth.signIn(email: trimmedEmail, password: password)
    } catch {
      if error.localizedDescription.localizedCaseInsensitiveContains("not confirmed") {
        try await auth.resendSignUpCode(email: trimmedEmail)
        showCodeScreen()
        infoMessage = "Your email isn't confirmed yet. We've sent you a new code."
      } else {
        throw error
      }
    }
  }

  private func showCodeScreen() {
    mode = .verify
    code = ""
    startCooldown()
  }

  private func resend() async {
    errorMessage = nil
    infoMessage = nil
    do {
      try await auth.resendSignUpCode(email: trimmedEmail)
      infoMessage = "A new code is on its way."
      startCooldown()
    } catch {
      errorMessage = friendly(error)
    }
  }

  private func startCooldown() {
    resendCooldown = 60
    Task {
      while resendCooldown > 0 {
        try? await Task.sleep(for: .seconds(1))
        resendCooldown -= 1
      }
    }
  }

  private func friendly(_ error: Error) -> String {
    let text = error.localizedDescription
    if text.localizedCaseInsensitiveContains("invalid login") { return "That email and password don't match." }
    if text.localizedCaseInsensitiveContains("token has expired") || text.localizedCaseInsensitiveContains("invalid") && mode == .verify {
      return "That code is wrong or has expired. Request a new one."
    }
    if text.localizedCaseInsensitiveContains("rate limit") { return "Too many attempts. Please wait a minute and try again." }
    return text
  }
}

/// White rounded box with a thin border, used around the form fields.
private struct FieldBox: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(Color.white)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColors.border.opacity(1.2), lineWidth: 1.2))
  }
}
