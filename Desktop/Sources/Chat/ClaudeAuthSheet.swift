import SwiftUI
import AppKit

/// Sheet shown when ACP bridge (Mode B) requires the user to authenticate
/// with their Claude account via OAuth.
struct ClaudeAuthSheet: View {
    let onConnect: () -> Void
    let onCancel: () -> Void
    let hasTimedOut: Bool
    let hasFailed: Bool
    let retryCooldownEnd: Date?
    let onRetry: () -> Void

    @State private var isConnecting = false
    @State private var showRetryOption = false
    @State private var cooldownRemaining: Int = 0
    @State private var cooldownTimer: Timer?

    private var isCoolingDown: Bool { cooldownRemaining > 0 }

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
                Image(systemName: errorIcon)
                    .scaledFont(size: 40)
                    .foregroundColor(errorIconColor)
                    .padding(.top, 8)

                // Description
                VStack(spacing: 8) {
                    if hasFailed {
                        Text("Connection was rejected")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text("Claude's server rejected the connection. Make sure you have an active Claude Pro or Max subscription, then try again.")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if hasTimedOut {
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

                if isConnecting && !hasTimedOut && !hasFailed {
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
                if hasFailed {
                    Button(action: {
                        isConnecting = false
                        showRetryOption = false
                        onRetry()
                    }) {
                        Text(isCoolingDown ? "Try Again (\(cooldownRemaining)s)" : "Try Again")
                            .scaledFont(size: 14, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isCoolingDown ? FazmColors.backgroundTertiary : Color.accentColor)
                            .foregroundColor(isCoolingDown ? FazmColors.textTertiary : .white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCoolingDown)
                } else if hasTimedOut {
                    Button(action: {
                        isConnecting = false
                        showRetryOption = false
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
                } else if isConnecting && showRetryOption {
                    // User has been waiting — let them re-trigger or open browser again
                    Button(action: {
                        onConnect()
                    }) {
                        Text("Open Sign-in Again")
                            .scaledFont(size: 14, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        isConnecting = false
                        showRetryOption = false
                        onRetry()
                    }) {
                        Text("Start Over")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        isConnecting = true
                        showRetryOption = false
                        onConnect()
                        // After 5 seconds, show retry options so user isn't stuck
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if isConnecting && !hasTimedOut && !hasFailed {
                                withAnimation(.easeIn(duration: 0.2)) {
                                    showRetryOption = true
                                }
                            }
                        }
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
        .frame(width: 400, height: sheetHeight)
        .background(FazmColors.backgroundPrimary)
        .onChange(of: hasTimedOut) {
            if hasTimedOut {
                isConnecting = false
                showRetryOption = false
            }
        }
        .onChange(of: hasFailed) {
            if hasFailed {
                isConnecting = false
                showRetryOption = false
                startCooldownTimer()
            }
        }
        .onDisappear {
            cooldownTimer?.invalidate()
            cooldownTimer = nil
        }
    }

    private var sheetHeight: CGFloat {
        if hasFailed { return 400 }
        if isConnecting && showRetryOption && !hasTimedOut { return 430 }
        return 380
    }

    private var errorIcon: String {
        if hasFailed { return "xmark.shield" }
        if hasTimedOut { return "exclamationmark.triangle" }
        return "person.badge.key"
    }

    private var errorIconColor: Color {
        if hasFailed { return .red }
        if hasTimedOut { return .orange }
        return FazmColors.textSecondary
    }

    private func startCooldownTimer() {
        cooldownTimer?.invalidate()
        guard let end = retryCooldownEnd else {
            cooldownRemaining = 0
            return
        }
        let remaining = Int(ceil(end.timeIntervalSinceNow))
        guard remaining > 0 else {
            cooldownRemaining = 0
            return
        }
        cooldownRemaining = remaining
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            let r = Int(ceil(end.timeIntervalSinceNow))
            if r <= 0 {
                cooldownRemaining = 0
                timer.invalidate()
                cooldownTimer = nil
            } else {
                cooldownRemaining = r
            }
        }
    }
}

// MARK: - Standalone Window Controller

/// Wrapper view that observes ChatProvider so claudeAuthTimedOut updates propagate.
private struct ClaudeAuthWindowContent: View {
    @ObservedObject var chatProvider: ChatProvider
    let onDismiss: () -> Void

    var body: some View {
        ClaudeAuthSheet(
            onConnect: {
                chatProvider.startClaudeAuth()
            },
            onCancel: {
                chatProvider.cancelClaudeAuth()
                onDismiss()
            },
            hasTimedOut: chatProvider.claudeAuthTimedOut,
            hasFailed: chatProvider.claudeAuthFailed,
            retryCooldownEnd: chatProvider.claudeAuthRetryCooldownEnd,
            onRetry: {
                chatProvider.retryClaudeAuth()
                onDismiss()
            }
        )
        .onReceive(chatProvider.$isClaudeAuthRequired.dropFirst()) { required in
            if !required {
                onDismiss()
            }
        }
    }
}

/// Manages a standalone floating window for Claude OAuth sign-in.
/// Shown when auth is needed regardless of whether the main window is visible.
final class ClaudeAuthWindowController {
    static let shared = ClaudeAuthWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show(chatProvider: ChatProvider) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = self
        let content = ClaudeAuthWindowContent(
            chatProvider: chatProvider,
            onDismiss: { controller.close() }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 400, height: 430))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 430)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing
        // Center on the screen that contains the mouse pointer
        // (avoids placing on a secondary display the user isn't looking at)
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 400) / 2
            let y = sf.origin.y + (sf.height - 430) / 2
            window.setFrame(NSRect(x: x, y: y, width: 400, height: 430), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.hostingView = hostingView
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
