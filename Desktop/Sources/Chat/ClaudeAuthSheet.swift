import SwiftUI

/// Sheet shown when ACP bridge (Mode B) requires the user to authenticate
/// with their Claude account via OAuth.
struct ClaudeAuthSheet: View {
    let onConnect: () -> Void
    let onCancel: () -> Void
    let hasTimedOut: Bool
    let onRetry: () -> Void

    @State private var isConnecting = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connect Your Claude Account")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(FazmColors.backgroundTertiary.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .foregroundColor(FazmColors.border)

            // Content
            VStack(spacing: 20) {
                // Icon
                Image(systemName: hasTimedOut ? "exclamationmark.triangle" : "person.badge.key")
                    .scaledFont(size: 40)
                    .foregroundColor(hasTimedOut ? .orange : FazmColors.textSecondary)
                    .padding(.top, 8)

                // Description
                VStack(spacing: 8) {
                    if hasTimedOut {
                        Text("Sign-in didn't complete")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("If you just signed in to Claude, try again — the authorization step may have been missed.")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Use your own Claude Pro or Max subscription")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Your browser will open to sign in with Claude. After authenticating, return to Fazm.")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)

                if isConnecting && !hasTimedOut {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)

                        Text("Complete sign-in in your browser...")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Spacer()

            // Actions
            VStack(spacing: 12) {
                if hasTimedOut {
                    Button(action: {
                        isConnecting = false
                        onRetry()
                    }) {
                        Text("Try Again")
                            .scaledFont(size: 14, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        isConnecting = true
                        onConnect()
                    }) {
                        HStack(spacing: 8) {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(isConnecting ? "Waiting for sign-in..." : "Connect Claude Account")
                                .scaledFont(size: 14, weight: .semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isConnecting ? FazmColors.backgroundTertiary : Color.accentColor)
                        .foregroundColor(isConnecting ? FazmColors.textSecondary : .white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnecting)
                }

                Button(action: onCancel) {
                    Text("Cancel")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 400, height: 380)
        .background(FazmColors.backgroundPrimary)
        .onChange(of: hasTimedOut) {
            if hasTimedOut {
                isConnecting = false
            }
        }
    }
}
