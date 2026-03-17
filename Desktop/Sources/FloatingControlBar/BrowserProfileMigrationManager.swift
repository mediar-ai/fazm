import Combine
import Foundation
import MarkdownUI
import SwiftUI

// MARK: - Manager

/// Manages the one-time browser profile extraction popup for existing users
/// who completed onboarding before the feature was introduced.
@MainActor
class BrowserProfileMigrationManager {
    static let shared = BrowserProfileMigrationManager()

    private let userDefaultsKey = "hasCompletedBrowserProfileExtraction"
    private var window: NSWindow?

    private init() {}

    // MARK: - Public

    /// Show the migration popup if needed. Called from FloatingControlBarManager.show().
    func showIfNeeded() {
        guard needsMigration() else { return }
        guard window == nil else { return }

        log("BrowserProfileMigration: Showing popup")

        let chatProvider = FloatingControlBarManager.shared.chatProvider
        guard let chatProvider else {
            log("BrowserProfileMigration: No chat provider available")
            return
        }

        let view = BrowserProfileMigrationView(
            chatProvider: chatProvider,
            onComplete: { [weak self] in self?.complete() },
            onSkip: { [weak self] in self?.skip() }
        )

        let hostingView = NSHostingView(rootView: view)
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        popupWindow.contentView = hostingView
        popupWindow.title = "Browser Profile Import"
        popupWindow.titlebarAppearsTransparent = true
        popupWindow.isMovableByWindowBackground = true
        popupWindow.appearance = NSAppearance(named: .darkAqua)
        popupWindow.backgroundColor = NSColor(FazmColors.backgroundPrimary)
        popupWindow.minSize = NSSize(width: 420, height: 400)
        popupWindow.center()
        popupWindow.level = .floating
        popupWindow.delegate = WindowCloseDelegate { [weak self] in
            self?.skip()
        }

        self.window = popupWindow
        popupWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called on app launch to pre-set the flag for users who already have browser profile data.
    func markCompleteIfAlreadyExtracted() {
        guard !UserDefaults.standard.bool(forKey: userDefaultsKey) else { return }
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }

        let memoriesDb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ai-browser-profile/memories.db")
        if FileManager.default.fileExists(atPath: memoriesDb.path) {
            UserDefaults.standard.set(true, forKey: userDefaultsKey)
            log("BrowserProfileMigration: memories.db already exists, marking complete")
        }
    }

    // MARK: - Private

    private func needsMigration() -> Bool {
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let alreadyDone = UserDefaults.standard.bool(forKey: userDefaultsKey)
        guard hasOnboarded && !alreadyDone else { return false }

        let memoriesDb = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ai-browser-profile/memories.db")
        return !FileManager.default.fileExists(atPath: memoriesDb.path)
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        dismissWindow()

        Task {
            if let provider = FloatingControlBarManager.shared.chatProvider {
                await provider.resetSession(key: "browser-migration")
                log("BrowserProfileMigration: Reset session")
            }
        }
        log("BrowserProfileMigration: Completed")
    }

    private func skip() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        dismissWindow()
        log("BrowserProfileMigration: Skipped")
    }

    private func dismissWindow() {
        window?.close()
        window = nil
    }
}

// MARK: - Window Close Delegate

/// Detects when the user closes the window via the title bar button.
private class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - Migration Chat View

struct BrowserProfileMigrationView: View {
    @ObservedObject var chatProvider: ChatProvider
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var inputText = ""
    @State private var hasStarted = false
    @State private var quickReplyQuestion = ""
    @State private var quickReplyOptions: [String] = []
    @State private var doneMarkerSeen = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Browser Profile Import")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 36) // extra top padding for titlebar
            .padding(.bottom, 12)

            Divider()
                .background(FazmColors.backgroundTertiary)

            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(chatProvider.messages) { message in
                            OnboardingChatBubble(message: message)
                                .id(message.id)
                        }

                        if chatProvider.isSending {
                            TypingIndicator()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 44)
                                .id("typing")
                        }

                        // Quick reply buttons
                        if !quickReplyOptions.isEmpty && !chatProvider.isSending {
                            if !quickReplyQuestion.isEmpty {
                                Text(quickReplyQuestion)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(FazmColors.textSecondary.opacity(0.8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 44)
                                    .padding(.bottom, -4)
                            }

                            HStack(spacing: 8) {
                                ForEach(quickReplyOptions, id: \.self) { option in
                                    Button(action: { handleQuickReply(option) }) {
                                        Text(option)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(FazmColors.purplePrimary)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(FazmColors.purplePrimary.opacity(0.1))
                                            .cornerRadius(20)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 20)
                                                    .stroke(FazmColors.purplePrimary.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 44)
                        }

                        // Done button
                        if doneMarkerSeen && !chatProvider.isSending {
                            Button(action: onComplete) {
                                Text("Done")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: 160)
                                    .padding(.vertical, 10)
                                    .background(FazmColors.purplePrimary)
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                        }

                        Spacer().frame(height: 20)
                    }
                    .padding(20)

                    Color.clear.frame(height: 1).id("bottom-anchor")
                }
                .onChange(of: chatProvider.messages.count) { _, _ in scrollToBottom(proxy: proxy) }
                .onChange(of: chatProvider.messages.last?.text) { _, _ in scrollToBottom(proxy: proxy) }
                .onChange(of: chatProvider.messages.last?.contentBlocks.count) { _, _ in
                    scrollToBottom(proxy: proxy, delay: 0.15)
                }
                .onChange(of: chatProvider.isSending) { _, _ in scrollToBottom(proxy: proxy) }
                .onChange(of: quickReplyOptions) { _, _ in scrollToBottom(proxy: proxy, delay: 0.1) }
            }

            // Input area
            HStack(spacing: 12) {
                TextField("Type your message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(FazmColors.textPrimary)
                    .focused($isInputFocused)
                    .padding(12)
                    .lineLimit(1...3)
                    .onSubmit { sendMessage() }
                    .frame(maxWidth: .infinity)
                    .background(FazmColors.backgroundSecondary)
                    .cornerRadius(20)

                if chatProvider.isSending {
                    Button(action: { chatProvider.stopAgent() }) {
                        Image(systemName: chatProvider.isStopping ? "ellipsis.circle" : "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(FazmColors.purplePrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(chatProvider.isStopping)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(canSend ? FazmColors.purplePrimary : FazmColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(FazmColors.backgroundPrimary)
        .onAppear { startChat() }
    }

    // MARK: - Logic

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatProvider.isSending
    }

    private func startChat() {
        guard !hasStarted else { return }
        hasStarted = true

        // Wire up quick replies
        ChatToolExecutor.onQuickReplyOptions = { [self] question, options in
            Task { @MainActor in
                self.quickReplyOptions = options
                self.quickReplyQuestion = question
            }
        }

        // Observe for done marker
        observeForDoneMarker()

        // Send initial message to kick off the migration flow
        Task {
            await chatProvider.sendMessage(
                "Hi, I'd like to set up browser profile import.",
                model: "claude-sonnet-4-6",
                systemPromptSuffix: ChatPrompts.browserProfileMigration,
                systemPromptPrefix: nil,
                sessionKey: "browser-migration"
            )
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        quickReplyOptions = []
        quickReplyQuestion = ""

        Task {
            await chatProvider.sendMessage(
                text,
                model: "claude-sonnet-4-6",
                systemPromptSuffix: ChatPrompts.browserProfileMigration,
                systemPromptPrefix: nil,
                sessionKey: "browser-migration"
            )
        }
    }

    private func handleQuickReply(_ option: String) {
        inputText = ""
        quickReplyOptions = []
        quickReplyQuestion = ""

        Task {
            await chatProvider.sendMessage(
                option,
                model: "claude-sonnet-4-6",
                systemPromptSuffix: ChatPrompts.browserProfileMigration,
                systemPromptPrefix: nil,
                sessionKey: "browser-migration"
            )
        }
    }

    private func observeForDoneMarker() {
        // Poll the latest message for the marker (simple approach)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            Task { @MainActor in
                guard let lastMessage = chatProvider.messages.last,
                      lastMessage.sender == .ai else { return }

                let marker = "[[BROWSER_MIGRATION_DONE]]"
                if lastMessage.text.contains(marker) {
                    // Strip it
                    if let idx = chatProvider.messages.indices.last {
                        chatProvider.messages[idx].text = lastMessage.text
                            .replacingOccurrences(of: marker, with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    doneMarkerSeen = true
                    timer.invalidate()
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, delay: TimeInterval = 0.05) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }
}
