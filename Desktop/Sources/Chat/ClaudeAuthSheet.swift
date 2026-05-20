import SwiftUI
import AppKit

private struct ClaudeAuthSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 460
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Unified "Connect Personal Account" sheet. Doubles as:
///   1. The provider chooser (Claude Code vs ChatGPT/Codex) when opened idle
///   2. The Claude OAuth in-progress UI (retry, timeout, failure cooldown)
///      once the user picks Claude.
///
/// ChatGPT picks dismiss this sheet and hand off to `CodexAuthSheet` via
/// the bridge's existing `codex_login_url` flow.
struct ClaudeAuthSheet: View {
    // Chooser inputs
    let isClaudeConnected: Bool          // green badge: Claude Code CLI creds in keychain
    let codexAuthMode: String            // "chatgpt" | "api_key" | "none"
    let codexLoginInProgress: Bool
    let onClaudeSelected: () -> Void     // starts Claude OAuth
    let onCodexSelected: () -> Void      // starts Codex OAuth + dismisses

    // Claude OAuth in-progress inputs (existing)
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
    private var inClaudeFlow: Bool { isConnecting || hasFailed || hasTimedOut }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(inClaudeFlow ? "Connect Your Claude Account" : "Connect Personal Account")
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

            Divider().foregroundColor(FazmColors.border)

            if inClaudeFlow {
                claudeProgressBody
            } else {
                chooserBody
            }

            Spacer()

            actionsArea
        }
        .frame(width: 440, height: sheetHeight)
        .background(FazmColors.backgroundPrimary)
        .preference(key: ClaudeAuthSheetHeightKey.self, value: sheetHeight)
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

    // MARK: - Chooser body (two provider cards)

    private var chooserBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick a provider. You'll keep using your own subscription instead of Fazm's built-in credits.")
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            claudeOption
            codexOption
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var claudeOption: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .scaledFont(size: 16)
                    .foregroundColor(FazmColors.purplePrimary)
                Text("Claude Code")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Recommended")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(FazmColors.purplePrimary))
                Spacer()
            }

            Text("Use your Claude Pro or Max subscription. Best for tool use, file editing, and long sessions.")
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isClaudeConnected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                    Text("Detected from Claude Code CLI — one click to use it")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                }
            }

            Button(action: {
                isConnecting = true
                showRetryOption = false
                onClaudeSelected()
                // After 5 seconds, surface "Open Sign-in Again" so the user
                // isn't stuck if the browser tab got swallowed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if isConnecting && !hasTimedOut && !hasFailed {
                        withAnimation(.easeIn(duration: 0.2)) {
                            showRetryOption = true
                        }
                    }
                }
            }) {
                Text(isClaudeConnected ? "Use Existing Claude Session" : "Connect Claude Account")
                    .scaledFont(size: 13, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(FazmColors.purplePrimary)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(FazmColors.backgroundSecondary))
    }

    private var codexOption: some View {
        let detected = codexAuthMode == "chatgpt" || codexAuthMode == "api_key"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 16)
                    .foregroundColor(Color(red: 0.063, green: 0.639, blue: 0.498))
                Text("ChatGPT (Codex)")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Spacer()
            }

            Text("Use your ChatGPT subscription via the OpenAI Codex backend. GPT-5 family models, text-first.")
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if detected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                    Text("Detected from ~/.codex/auth.json — pick a GPT model in the picker")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                }
            }

            Button(action: onCodexSelected) {
                HStack(spacing: 6) {
                    if codexLoginInProgress {
                        ProgressView().controlSize(.mini)
                        Text("Connecting…")
                    } else {
                        Text(detected ? "Already Connected" : "Connect ChatGPT Account")
                    }
                }
                .scaledFont(size: 13, weight: .semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(detected ? FazmColors.backgroundTertiary : Color(red: 0.063, green: 0.639, blue: 0.498))
                .foregroundColor(detected ? FazmColors.textSecondary : .white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(codexLoginInProgress || detected)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(FazmColors.backgroundSecondary))
    }

    // MARK: - Claude OAuth in-progress body (existing)

    private var claudeProgressBody: some View {
        VStack(spacing: 20) {
            Image(systemName: errorIcon)
                .scaledFont(size: 40)
                .foregroundColor(errorIconColor)
                .padding(.top, 8)

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
                    Text("Waiting for sign-in in your browser…")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundColor(FazmColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("Complete sign-in in your browser, then return to Fazm.")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)

            if isConnecting && !hasTimedOut && !hasFailed {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Footer actions

    private var actionsArea: some View {
        VStack(spacing: 12) {
            if inClaudeFlow {
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
                    Button(action: {
                        onClaudeSelected()
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
                }
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

    // MARK: - Helpers

    private var sheetHeight: CGFloat {
        if !inClaudeFlow { return 480 }
        if hasFailed { return 400 }
        if isConnecting && showRetryOption && !hasTimedOut { return 490 }
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

/// Wrapper view that observes ChatProvider + CodexBackendManager so the
/// sheet re-renders when auth/detection state changes.
private struct ClaudeAuthWindowContent: View {
    @ObservedObject var chatProvider: ChatProvider
    @ObservedObject var codexBackend: CodexBackendManager
    let onDismiss: () -> Void
    let onSheetHeightChange: (CGFloat) -> Void

    var body: some View {
        ClaudeAuthSheet(
            isClaudeConnected: chatProvider.isClaudeConnected,
            codexAuthMode: codexBackend.authMode,
            codexLoginInProgress: codexBackend.loginInProgress,
            onClaudeSelected: {
                // If creds already in keychain, flip to personal mode and dismiss;
                // the bridge adopts them on the next session/new. Otherwise kick
                // off the OAuth flow.
                if chatProvider.isClaudeConnected {
                    Task { await chatProvider.switchBridgeMode(to: "personal") }
                    onDismiss()
                } else {
                    chatProvider.startClaudeAuth()
                }
            },
            onCodexSelected: {
                chatProvider.startCodexLogin()
                onDismiss()
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
        .onAppear {
            // Refresh detection in case the user installed claude or codex CLI
            // mid-session (the startup probe wouldn't have seen them).
            chatProvider.checkClaudeConnectionStatus(autoSwitchToPersonal: false)
        }
        .onPreferenceChange(ClaudeAuthSheetHeightKey.self) { height in
            onSheetHeightChange(height)
        }
        .onReceive(chatProvider.$isClaudeAuthRequired.dropFirst()) { required in
            if !required {
                onDismiss()
            }
        }
    }
}

/// Manages a standalone floating window for the unified "Connect Personal
/// Account" sheet (chooser + Claude OAuth progress).
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
        let initialHeight: CGFloat = 480
        let content = ClaudeAuthWindowContent(
            chatProvider: chatProvider,
            codexBackend: CodexBackendManager.shared,
            onDismiss: { controller.close() },
            onSheetHeightChange: { [weak self] height in
                self?.resize(toContentHeight: height)
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 440, height: initialHeight))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 440, height: initialHeight)),
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
            let x = sf.origin.x + (sf.width - 440) / 2
            let y = sf.origin.y + (sf.height - initialHeight) / 2
            window.setFrame(NSRect(x: x, y: y, width: 440, height: initialHeight), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.hostingView = hostingView
    }

    private func resize(toContentHeight height: CGFloat) {
        guard let window = window, abs(window.frame.size.height - height) > 0.5 else { return }
        var frame = window.frame
        let delta = height - frame.size.height
        frame.size.height = height
        // Keep the top edge of the window in place so content doesn't appear to jump down.
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: true)
        hostingView?.setFrameSize(NSSize(width: 440, height: height))
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
