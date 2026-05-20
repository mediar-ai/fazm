import SwiftUI
import AppKit

/// Thin provider-chooser sheet. Asks the user which personal account to
/// connect (Claude Code or ChatGPT/Codex), then dismisses itself and hands
/// off to the existing OAuth sheet for the chosen provider — `ClaudeAuthSheet`
/// for Claude, `CodexAuthSheet` for ChatGPT. The chooser owns NO OAuth UI of
/// its own; it's pure routing.
struct PersonalAccountChooserSheet: View {
    let isClaudeConnected: Bool       // green badge when Claude Code CLI creds detected
    let codexAuthMode: String         // "chatgpt" | "api_key" | "none"
    let onPickClaude: () -> Void      // dispatches to OAuth or direct-use depending on detection
    let onPickCodex: () -> Void       // dispatches to OAuth or direct-use depending on detection
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Personal Account")
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

            VStack(alignment: .leading, spacing: 16) {
                Text("Pick a provider. You'll keep using your own subscription instead of Fazm's built-in credits.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                claudeCard
                codexCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
        }
        .frame(width: 440, height: 460)
        .background(FazmColors.backgroundPrimary)
    }

    private var claudeCard: some View {
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
                    Text("Detected from Claude Code CLI")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                }
            }

            Button(action: onPickClaude) {
                Text("Connect Claude Account")
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

    private var codexCard: some View {
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
                    Text("Detected from ~/.codex/auth.json")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                }
            }

            Button(action: onPickCodex) {
                Text(detected ? "Already Connected" : "Connect ChatGPT Account")
                    .scaledFont(size: 13, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(detected ? FazmColors.backgroundTertiary : Color(red: 0.063, green: 0.639, blue: 0.498))
                    .foregroundColor(detected ? FazmColors.textSecondary : .white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(detected)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(FazmColors.backgroundSecondary))
    }
}

// MARK: - Window Controller

@MainActor
final class PersonalAccountChooserWindowController {
    static let shared = PersonalAccountChooserWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show(chatProvider: ChatProvider) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = self
        let content = ChooserWindowContent(
            chatProvider: chatProvider,
            codexBackend: CodexBackendManager.shared,
            onDismiss: { controller.close() }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
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

/// Observes ChatProvider + CodexBackendManager so detection badges re-render.
private struct ChooserWindowContent: View {
    @ObservedObject var chatProvider: ChatProvider
    @ObservedObject var codexBackend: CodexBackendManager
    let onDismiss: () -> Void

    var body: some View {
        PersonalAccountChooserSheet(
            isClaudeConnected: chatProvider.isClaudeConnected,
            codexAuthMode: codexBackend.authMode,
            onPickClaude: {
                onDismiss()
                ClaudeAuthWindowController.shared.show(chatProvider: chatProvider)
            },
            onPickCodex: {
                onDismiss()
                chatProvider.startCodexLogin()
                // CodexAuthWindowController is opened automatically by the
                // bridge's codex_login_url callback wired in ChatProvider.
            },
            onCancel: onDismiss
        )
        .onAppear {
            // Refresh detection in case the user installed claude or codex CLI
            // mid-session (the startup probe wouldn't have seen them).
            chatProvider.checkClaudeConnectionStatus(autoSwitchToPersonal: false)
        }
    }
}
