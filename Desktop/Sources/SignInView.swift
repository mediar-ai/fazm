import SwiftUI

struct GoogleIcon: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: size, height: size)
            Text("G")
                .font(.system(size: size * 0.65, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.26, green: 0.52, blue: 0.96))
        }
    }
}

/// The local UI step of the magic-link flow.
private enum MagicLinkStep {
    /// Idle / not started; user can pick any provider.
    case idle
    /// User typed an email and we asked the backend to send a code.
    case emailEntry
    /// Code was sent and we're waiting for the user to type it in.
    case codeEntry
}

struct SignInView: View {
    @ObservedObject var authState: AuthState
    /// When non-nil, this screen is a soft re-auth ("session expired") for a
    /// known user rather than a first-time sign-in. Changes the copy so a
    /// returning user isn't greeted with "Welcome to Fazm".
    var reauthEmail: String? = nil
    @State private var isHoveringGoogle = false
    @State private var isHoveringEmail = false
    @State private var isHoveringPrimary = false
    @State private var isHoveringBack = false
    @State private var showPrivacySheet = false

    // Magic-link state.
    @State private var magicLinkStep: MagicLinkStep = .idle
    @State private var emailInput: String = ""
    @State private var codeInput: String = ""
    @State private var infoMessage: String?

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case email, code }

    var body: some View {
        ZStack {
            FazmColors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Logo
                if let iconURL = Bundle.resourceBundle.url(forResource: "fazm_app_icon", withExtension: "png"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                // Title
                VStack(spacing: 8) {
                    Text(titleText)
                        .scaledFont(size: 28, weight: .bold)
                        .foregroundColor(FazmColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(subtitleText)
                        .scaledFont(size: 15, weight: .regular)
                        .foregroundColor(FazmColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                // Error / info messages
                if let error = authState.error {
                    statusBanner(text: error, color: FazmColors.error)
                        .transition(.opacity)
                } else if let info = infoMessage {
                    statusBanner(text: info, color: FazmColors.purplePrimary)
                        .transition(.opacity)
                }

                // Primary content depends on the step
                Group {
                    switch magicLinkStep {
                    case .idle:
                        providerPicker
                    case .emailEntry:
                        emailEntryForm
                    case .codeEntry:
                        codeEntryForm
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: magicLinkStep)

                // Waiting status + Cancel (visible while Google OAuth is in flight)
                if authState.isLoading && magicLinkStep == .idle {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .tint(FazmColors.textTertiary)
                            Text("Continue sign-in in your browser…")
                                .scaledFont(size: 13, weight: .regular)
                                .foregroundColor(FazmColors.textTertiary)
                        }
                        Button(action: {
                            AuthService.shared.cancelGoogleSignIn()
                        }) {
                            Text("Cancel")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundColor(FazmColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.opacity)
                }

                Spacer()

                // Footer
                HStack(spacing: 0) {
                    Text("By signing in, you agree to the ")
                        .scaledFont(size: 11, weight: .regular)
                        .foregroundColor(FazmColors.textQuaternary)
                    Button(action: {
                        PostHogManager.shared.track("terms_of_service_clicked", properties: ["source": "sign_in"])
                        if let url = URL(string: "https://fazm.ai/terms") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Text("Terms of Service")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                    }
                    .buttonStyle(.plain)
                    Text(" and ")
                        .scaledFont(size: 11, weight: .regular)
                        .foregroundColor(FazmColors.textQuaternary)
                    Button(action: {
                        PostHogManager.shared.track("privacy_policy_clicked", properties: ["source": "sign_in"])
                        showPrivacySheet = true
                    }) {
                        Text("Privacy Policy")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                    }
                    .buttonStyle(.plain)
                    Text(".")
                        .scaledFont(size: 11, weight: .regular)
                        .foregroundColor(FazmColors.textQuaternary)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 40)
        }
        .frame(minWidth: 400, minHeight: 540)
        .onAppear {
            // Prefill the known email for a returning (re-auth) user so the
            // magic-link path is one tap away.
            if let e = reauthEmail, !e.isEmpty, emailInput.isEmpty {
                emailInput = e
            }
        }
        .sheet(isPresented: $showPrivacySheet) {
            OnboardingPrivacySheet(isPresented: $showPrivacySheet)
        }
    }

    // MARK: - Step subviews

    private var providerPicker: some View {
        VStack(spacing: 12) {
            // Google Sign In
            Button(action: { performGoogleSignIn() }) {
                HStack(spacing: 10) {
                    GoogleIcon(size: 18)
                    Text("Sign in with Google")
                        .scaledFont(size: 15, weight: .medium)
                }
                .foregroundColor(.white)
                .frame(maxWidth: 280)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHoveringGoogle ? Color.white.opacity(0.15) : Color.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FazmColors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringGoogle = $0 }
            .disabled(authState.isLoading)

            // "or" divider
            HStack(spacing: 10) {
                Rectangle()
                    .fill(FazmColors.border)
                    .frame(height: 1)
                Text("or")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(FazmColors.textQuaternary)
                Rectangle()
                    .fill(FazmColors.border)
                    .frame(height: 1)
            }
            .frame(maxWidth: 280)
            .padding(.vertical, 2)

            // Email magic-link entry point
            Button(action: { startMagicLink() }) {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sign in with email")
                        .scaledFont(size: 15, weight: .medium)
                }
                .foregroundColor(.white)
                .frame(maxWidth: 280)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHoveringEmail ? Color.white.opacity(0.15) : Color.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FazmColors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringEmail = $0 }
            .disabled(authState.isLoading)
        }
    }

    private var emailEntryForm: some View {
        VStack(spacing: 12) {
            TextField("you@example.com", text: $emailInput)
                .textFieldStyle(.plain)
                .scaledFont(size: 15, weight: .regular)
                .foregroundColor(FazmColors.textPrimary)
                .padding(.horizontal, 14)
                .frame(maxWidth: 280)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FazmColors.border, lineWidth: 1)
                )
                .focused($focusedField, equals: .email)
                .onSubmit { sendMagicLinkCode() }
                .disableAutocorrection(true)

            Button(action: { sendMagicLinkCode() }) {
                HStack(spacing: 8) {
                    if authState.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(authState.isLoading ? "Sending…" : "Send code")
                        .scaledFont(size: 15, weight: .semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: 280)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(primaryButtonColor)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringPrimary = $0 }
            .disabled(authState.isLoading || !isLikelyValidEmail(emailInput))

            backButton(label: "Back to all options") { resetMagicLink() }
        }
        .onAppear { focusedField = .email }
    }

    private var codeEntryForm: some View {
        VStack(spacing: 12) {
            TextField("123456", text: $codeInput)
                .textFieldStyle(.plain)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .frame(maxWidth: 280)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FazmColors.border, lineWidth: 1)
                )
                .focused($focusedField, equals: .code)
                .onChange(of: codeInput) { _, newValue in
                    // Keep only digits, max 6.
                    let filtered = newValue.filter(\.isNumber).prefix(6)
                    if filtered != newValue {
                        codeInput = String(filtered)
                    }
                    if codeInput.count == 6 {
                        verifyMagicLinkCode()
                    }
                }

            Button(action: { verifyMagicLinkCode() }) {
                HStack(spacing: 8) {
                    if authState.isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(authState.isLoading ? "Verifying…" : "Verify & sign in")
                        .scaledFont(size: 15, weight: .semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: 280)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(primaryButtonColor)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringPrimary = $0 }
            .disabled(authState.isLoading || codeInput.count != 6)

            HStack(spacing: 16) {
                Button(action: { resendCode() }) {
                    Text("Resend code")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(FazmColors.purplePrimary)
                }
                .buttonStyle(.plain)
                .disabled(authState.isLoading)

                Text("·")
                    .scaledFont(size: 12, weight: .regular)
                    .foregroundColor(FazmColors.textQuaternary)

                Button(action: { magicLinkStep = .emailEntry; codeInput = ""; infoMessage = nil; authState.error = nil }) {
                    Text("Change email")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(FazmColors.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(authState.isLoading)
            }

            backButton(label: "Back to all options") { resetMagicLink() }
        }
        .onAppear { focusedField = .code }
    }

    // MARK: - Subview helpers

    private var isReauth: Bool { reauthEmail != nil }

    private var titleText: String {
        switch magicLinkStep {
        case .idle:       return isReauth ? "Session expired" : "Welcome to Fazm"
        case .emailEntry: return "Sign in with email"
        case .codeEntry:  return "Check your email"
        }
    }

    private var subtitleText: String {
        switch magicLinkStep {
        case .idle:
            if isReauth {
                let who = (reauthEmail?.isEmpty == false) ? reauthEmail! : "your account"
                return "Sign back in to \(who) to keep going. Your data and subscription are safe."
            }
            return "Sign in to get started"
        case .emailEntry: return "We'll send you a 6-digit code to sign in"
        case .codeEntry:  return "We sent a 6-digit code to \(emailInput.isEmpty ? "your email" : emailInput)"
        }
    }

    private var primaryButtonColor: Color {
        if authState.isLoading {
            return FazmColors.purplePrimary.opacity(0.6)
        }
        return isHoveringPrimary ? FazmColors.purplePrimary.opacity(0.85) : FazmColors.purplePrimary
    }

    private func statusBanner(text: String, color: Color) -> some View {
        Text(text)
            .scaledFont(size: 13, weight: .medium)
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.1))
            )
    }

    private func backButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 12, weight: .medium)
                .foregroundColor(isHoveringBack ? FazmColors.textPrimary : FazmColors.textTertiary)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringBack = $0 }
        .disabled(authState.isLoading)
        .padding(.top, 8)
    }

    // MARK: - Email validation

    private func isLikelyValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.contains("@"), trimmed.contains(".") else { return false }
        return !trimmed.hasPrefix("@") && !trimmed.hasSuffix("@")
    }

    // MARK: - Actions

    private func startMagicLink() {
        authState.error = nil
        infoMessage = nil
        magicLinkStep = .emailEntry
    }

    private func resetMagicLink() {
        authState.error = nil
        infoMessage = nil
        emailInput = ""
        codeInput = ""
        magicLinkStep = .idle
    }

    private func sendMagicLinkCode() {
        let email = emailInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard isLikelyValidEmail(email) else {
            authState.error = "Please enter a valid email address."
            return
        }
        emailInput = email

        Task { @MainActor in
            authState.isLoading = true
            authState.error = nil
            infoMessage = nil
            do {
                try await AuthService.shared.requestMagicLinkCode(email: email)
                authState.isLoading = false
                magicLinkStep = .codeEntry
                infoMessage = "Code sent. Check your inbox (and spam folder)."
            } catch {
                authState.isLoading = false
                authState.error = error.localizedDescription
            }
        }
    }

    private func resendCode() {
        sendMagicLinkCode()
    }

    private func verifyMagicLinkCode() {
        let code = codeInput.trimmingCharacters(in: .whitespaces)
        guard code.count == 6 else { return }

        Task { @MainActor in
            authState.isLoading = true
            authState.error = nil
            infoMessage = nil
            do {
                try await AuthService.shared.verifyMagicLinkCode(email: emailInput, code: code)
                UserDefaults.standard.set(true, forKey: "signInJustCompleted")
                authState.update(isSignedIn: true, userEmail: AuthService.shared.userEmail)
                authState.isLoading = false
                magicLinkStep = .idle
                // Refresh subscription status for the newly signed-in user
                Task { await SubscriptionService.shared.refreshStatus() }
            } catch {
                authState.isLoading = false
                // Clear the code so the user can try again without manually deleting digits.
                codeInput = ""
                authState.error = error.localizedDescription
            }
        }
    }

    // MARK: - Google Sign-In

    private func performGoogleSignIn() {
        Task { @MainActor in
            authState.isLoading = true
            authState.error = nil
            do {
                try await AuthService.shared.signInWithGoogle()
                UserDefaults.standard.set(true, forKey: "signInJustCompleted")
                authState.update(isSignedIn: true, userEmail: AuthService.shared.userEmail)
                authState.isLoading = false
                // Refresh subscription status for the newly signed-in user
                Task { await SubscriptionService.shared.refreshStatus() }
            } catch AuthError.cancelled {
                authState.isLoading = false
            } catch {
                authState.error = "Google Sign-In failed: \(error.localizedDescription)"
                authState.isLoading = false
            }
        }
    }
}
