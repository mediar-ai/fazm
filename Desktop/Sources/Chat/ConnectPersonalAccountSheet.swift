import SwiftUI
import AppKit

/// Sheet shown when the user is asked to connect a personal AI account.
/// Surfaces both supported providers side-by-side so the user picks one:
///   1. Claude Code (Anthropic) — primary, recommended
///   2. ChatGPT (OpenAI Codex) — secondary
///
/// Each card shows a "Detected" hint when existing credentials are already
/// present locally (Claude Code CLI keychain entry or ~/.codex/auth.json).
struct ConnectPersonalAccountSheet: View {
    @ObservedObject var chatProvider: ChatProvider
    @ObservedObject var codexBackend: CodexBackendManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Personal Account")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: onClose) {
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

            Spacer()

            Button(action: onClose) {
                Text("Cancel")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
        }
        .frame(width: 440, height: 460)
        .background(FazmColors.backgroundPrimary)
        .onAppear {
            // Refresh detection in case the user installed claude or codex CLI
            // mid-session (the startup probe wouldn't have seen them).
            chatProvider.checkClaudeConnectionStatus(autoSwitchToPersonal: false)
        }
    }

    // MARK: - Claude (primary)

    private var claudeOption: some View {
        let detected = chatProvider.isClaudeConnected
        return VStack(alignment: .leading, spacing: 10) {
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

            if detected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                    Text("Detected from Claude Code CLI — one click to use it")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                }
            }

            Button(action: connectClaude) {
                Text(detected ? "Use Existing Claude Session" : "Connect Claude Account")
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

    // MARK: - Codex / ChatGPT (secondary)

    private var codexOption: some View {
        let detected = codexBackend.authMode == "chatgpt" || codexBackend.authMode == "api_key"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .scaledFont(size: 16)
                    .foregroundColor(Color(red: 0.063, green: 0.639, blue: 0.498))
                Text("ChatGPT / OpenAI")
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

            Button(action: connectCodex) {
                HStack(spacing: 6) {
                    if codexBackend.loginInProgress {
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
            .disabled(codexBackend.loginInProgress || detected)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(FazmColors.backgroundSecondary))
    }

    // MARK: - Actions

    private func connectClaude() {
        if chatProvider.isClaudeConnected {
            // Credentials already in keychain — just flip bridgeMode; the bridge
            // adopts them on the next session/new and the user is done.
            Task { await chatProvider.switchBridgeMode(to: "personal") }
            onClose()
        } else {
            // No creds yet — hand off to the existing Claude OAuth flow.
            onClose()
            ClaudeAuthWindowController.shared.show(chatProvider: chatProvider)
        }
    }

    private func connectCodex() {
        // The Codex auth window auto-opens via ChatProvider.setCodexLoginHandlers
        // once the bridge emits codex_login_url.
        chatProvider.startCodexLogin()
        onClose()
    }
}

// MARK: - Window Controller

@MainActor
final class ConnectPersonalAccountWindowController {
    static let shared = ConnectPersonalAccountWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show(chatProvider: ChatProvider) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = self
        let sheet = ConnectPersonalAccountSheet(
            chatProvider: chatProvider,
            codexBackend: CodexBackendManager.shared,
            onClose: { controller.close() }
        )

        let hostingView = NSHostingView(rootView: AnyView(sheet))
        hostingView.setFrameSize(NSSize(width: 440, height: 460))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 440, height: 460)),
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
        window.applyCrashWorkarounds()

        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 440) / 2
            let y = sf.origin.y + (sf.height - 460) / 2
            window.setFrame(NSRect(x: x, y: y, width: 440, height: 460), display: true)
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
