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
    let geminiAvailable: Bool         // Gemini ACP backend reachable (FAZM_GEMINI_ENABLED on + probe ok)
    let onPickClaude: () -> Void      // dispatches to OAuth or direct-use depending on detection
    let onPickCodex: () -> Void       // dispatches to OAuth or direct-use depending on detection
    let onPickGemini: () -> Void      // switches active model to Gemini; no auth needed (built-in key)
    let onCancel: () -> Void

    private var sheetHeight: CGFloat {
        geminiAvailable ? 600 : 460
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keep Chatting")
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
                Text(geminiAvailable
                     ? "Switch to Gemini (free, no limit) or connect a personal Claude or ChatGPT subscription."
                     : "Pick a provider. You'll keep using your own subscription instead of Fazm's built-in credits.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if geminiAvailable {
                    geminiCard
                }
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
        .frame(width: 440, height: sheetHeight)
        .background(FazmColors.backgroundPrimary)
    }

    private var geminiCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .scaledFont(size: 16)
                    .foregroundColor(FazmColors.purplePrimary)
                Text("Google Gemini")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Free")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(FazmColors.purplePrimary))
                Spacer()
            }

            Text("Keep using Fazm with Gemini Flash or Pro. No account to connect, no usage cap.")
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onPickGemini) {
                Text("Switch to Gemini")
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

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .scaledFont(size: 16)
                    .foregroundColor(FazmColors.purplePrimary)
                Text("Claude Code")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
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

            Button(action: onPickClaude) {
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
                    Text("Detected from ~/.codex/auth.json — one click to use it")
                        .scaledFont(size: 11)
                        .foregroundColor(.green)
                }
            }

            Button(action: onPickCodex) {
                Text(detected ? "Use ChatGPT" : "Connect ChatGPT Account")
                    .scaledFont(size: 13, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color(red: 0.063, green: 0.639, blue: 0.498))
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
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

    /// Open the chooser. `source` is the analytics tag for where it opened
    /// from (e.g. "onboarding", "floating_bar", "popout", "debug_trigger").
    func show(chatProvider: ChatProvider, source: String) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        AnalyticsManager.shared.personalAccountChooserOpened(
            source: source,
            claudeDetected: chatProvider.isClaudeConnected,
            codexDetected: CodexBackendManager.shared.authMode == "chatgpt"
                || CodexBackendManager.shared.authMode == "api_key"
        )

        let controller = self
        let content = ChooserWindowContent(
            chatProvider: chatProvider,
            codexBackend: CodexBackendManager.shared,
            onDismiss: { controller.close() },
            onHeightChange: { [weak self] height in
                self?.resize(toContentHeight: height)
            }
        )

        // Size the window to match whichever sheet variant will render. Sheet
        // height grows when the Gemini card is offered.
        let geminiAvailable = ShortcutSettings.shared.availableModels.contains { $0.id.hasPrefix("gemini-") }
        let sheetHeight: CGFloat = geminiAvailable ? 600 : 460

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 440, height: sheetHeight))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 440, height: sheetHeight)),
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
            let y = sf.origin.y + (sf.height - sheetHeight) / 2
            window.setFrame(NSRect(x: x, y: y, width: 440, height: sheetHeight), display: true)
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

/// Observes ChatProvider + CodexBackendManager so detection badges re-render.
private struct ChooserWindowContent: View {
    @ObservedObject var chatProvider: ChatProvider
    @ObservedObject var codexBackend: CodexBackendManager
    @ObservedObject var shortcutSettings: ShortcutSettings = .shared
    let onDismiss: () -> Void
    let onHeightChange: (CGFloat) -> Void

    /// When the user picks Claude without existing creds, the OAuth flow renders
    /// inline (reusing `ClaudeAuthSheet`) instead of in a separate window.
    @State private var showingClaudeAuth = false

    /// Gemini is offered as a free-no-cap fallback only when the bridge has
    /// confirmed it's reachable (FAZM_GEMINI_ENABLED on + probe succeeded).
    private var geminiAvailable: Bool {
        shortcutSettings.availableModels.contains { $0.id.hasPrefix("gemini-") }
    }

    /// Pick the user's preferred Gemini model. When the user explicitly clicks
    /// "Switch to Gemini" from the chooser, default to Pro (smartest model);
    /// only Flash as a last resort if Pro isn't advertised by the probe.
    private var preferredGeminiModelId: String {
        if let pro = shortcutSettings.availableModels.first(where: { $0.id == "gemini-pro-latest" }) {
            return pro.id
        }
        if let flash = shortcutSettings.availableModels.first(where: { $0.id == "gemini-flash-latest" }) {
            return flash.id
        }
        return shortcutSettings.availableModels.first(where: { $0.id.hasPrefix("gemini-") })?.id
            ?? "gemini-pro-latest"
    }

    var body: some View {
        Group {
            if showingClaudeAuth {
                claudeAuthView
            } else {
                pickerView
            }
        }
        .onAppear {
            // Refresh detection in case the user installed claude or codex CLI
            // mid-session (the startup probe wouldn't have seen them).
            chatProvider.checkClaudeConnectionStatus(autoSwitchToPersonal: false)
            reportPickerHeight()
        }
        .onChange(of: geminiAvailable) { reportPickerHeight() }
        .onReceive(chatProvider.$isClaudeConnected.dropFirst()) { connected in
            // OAuth completed successfully — close the chooser entirely.
            if connected && showingClaudeAuth {
                onDismiss()
            }
        }
    }

    /// Inline Claude OAuth, reusing the same view the standalone window used to host.
    private var claudeAuthView: some View {
        ClaudeAuthSheet(
            onConnect: { chatProvider.startClaudeAuth() },
            onCancel: {
                // Return to the picker rather than closing the whole chooser, so
                // the user can still choose Gemini or ChatGPT.
                chatProvider.cancelClaudeAuth()
                showingClaudeAuth = false
                reportPickerHeight()
            },
            hasTimedOut: chatProvider.claudeAuthTimedOut,
            hasFailed: chatProvider.claudeAuthFailed,
            retryCooldownEnd: chatProvider.claudeAuthRetryCooldownEnd,
            onRetry: { chatProvider.retryClaudeAuth() }
        )
        .onPreferenceChange(ClaudeAuthSheetHeightKey.self) { height in
            onHeightChange(height)
        }
    }

    private func reportPickerHeight() {
        onHeightChange(geminiAvailable ? 600 : 460)
    }

    private var pickerView: some View {
        PersonalAccountChooserSheet(
            isClaudeConnected: chatProvider.isClaudeConnected,
            codexAuthMode: codexBackend.authMode,
            geminiAvailable: geminiAvailable,
            onPickClaude: {
                let alreadyAuthed = chatProvider.isClaudeConnected
                AnalyticsManager.shared.personalAccountChooserPicked(
                    provider: "claude", alreadyAuthed: alreadyAuthed
                )
                if alreadyAuthed {
                    // Creds already in keychain — just flip to personal; the
                    // bridge adopts them on the next session/new. No OAuth.
                    onDismiss()
                    Task { await chatProvider.switchBridgeMode(to: "personal") }
                } else {
                    // No creds — run the Claude OAuth flow inline within this
                    // same window (no separate auth window).
                    showingClaudeAuth = true
                    chatProvider.startClaudeAuth()
                }
            },
            onPickCodex: {
                let detected = codexBackend.authMode == "chatgpt"
                                || codexBackend.authMode == "api_key"
                AnalyticsManager.shared.personalAccountChooserPicked(
                    provider: "codex", alreadyAuthed: detected
                )
                onDismiss()
                if detected {
                    // Already authed — switch active model to a GPT one so
                    // the next query routes through Codex instead of the
                    // capped built-in Claude path. Prefer the user's last
                    // picker selection or the first eligible GPT model.
                    let target = codexBackend.currentModelId
                        ?? codexBackend.modelsForPicker.first?.modelId
                        ?? "gpt-5.5/high"
                    chatProvider.selectModel(target)
                } else {
                    // Not yet authed — seed pendingPickerModelId so the
                    // existing post-OAuth handler auto-promotes the model
                    // once the user signs in. CodexAuthWindowController is
                    // opened by the bridge's codex_login_url callback.
                    if codexBackend.pendingPickerModelId == nil {
                        codexBackend.pendingPickerModelId =
                            codexBackend.currentModelId
                            ?? codexBackend.modelsForPicker.first?.modelId
                            ?? "gpt-5.5/high"
                    }
                    chatProvider.startCodexLogin()
                }
            },
            onPickGemini: {
                AnalyticsManager.shared.personalAccountChooserPicked(
                    provider: "gemini", alreadyAuthed: true
                )
                onDismiss()
                // Gemini uses the bundled GEMINI_API_KEY (no OAuth). Switching
                // model is enough; selectModel clears showCreditExhaustedAlert
                // for any non-Anthropic provider, so the next query proceeds.
                chatProvider.selectModel(preferredGeminiModelId)
            },
            onCancel: {
                AnalyticsManager.shared.personalAccountChooserCancelled()
                onDismiss()
            }
        )
    }
}
