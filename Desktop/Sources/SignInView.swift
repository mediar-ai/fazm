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

struct SignInView: View {
    @ObservedObject var authState: AuthState
    @State private var isHoveringGoogle = false

    var body: some View {
        ZStack {
            FazmColors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 32) {
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
                    Text("Welcome to Fazm")
                        .scaledFont(size: 28, weight: .bold)
                        .foregroundColor(FazmColors.textPrimary)

                    Text("Sign in to get started")
                        .scaledFont(size: 15, weight: .regular)
                        .foregroundColor(FazmColors.textTertiary)
                }

                // Error message
                if let error = authState.error {
                    Text(error)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundColor(FazmColors.error)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.error.opacity(0.1))
                        )
                        .transition(.opacity)
                }

                // Sign-in buttons
                VStack(spacing: 12) {
                    // Google Sign In
                    Button(action: {
                        performGoogleSignIn()
                    }) {
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
                    .onHover { hovering in
                        isHoveringGoogle = hovering
                    }
                    .disabled(authState.isLoading)
                }

                // Loading indicator
                if authState.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(FazmColors.textTertiary)
                }

                Spacer()

                // Footer
                Text("By signing in, you agree to the Terms of Service and Privacy Policy.")
                    .scaledFont(size: 11, weight: .regular)
                    .foregroundColor(FazmColors.textQuaternary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 40)
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    // MARK: - Sign In Methods

    private func performGoogleSignIn() {
        Task { @MainActor in
            authState.isLoading = true
            authState.error = nil
            do {
                try await AuthService.shared.signInWithGoogle()
                UserDefaults.standard.set(true, forKey: "signInJustCompleted")
                authState.update(isSignedIn: true, userEmail: AuthService.shared.userEmail)
                authState.isLoading = false
            } catch AuthError.cancelled {
                authState.isLoading = false
            } catch {
                authState.error = "Google Sign-In failed: \(error.localizedDescription)"
                authState.isLoading = false
            }
        }
    }
}
