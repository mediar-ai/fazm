import Cocoa
import Combine
import SwiftUI

/// A normal macOS window that hosts the chat conversation after "popping out" from the floating bar.
/// Not always-on-top — behaves like a regular app window.
class DetachedChatWindow: NSWindow, NSWindowDelegate {
    private static let sizeKey = "DetachedChatWindowSize"
    private static let positionKey = "DetachedChatWindowPosition"
    private static let defaultSize = NSSize(width: 624, height: 900)

    let state: FloatingControlBarState
    private var hostingView: NSHostingView<AnyView>?

    var onSendFollowUp: ((String) -> Void)?
    var onEnqueueMessage: ((String) -> Void)?
    var onSendNowQueued: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?
    var onStopAgent: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onObserverCardAction: ((Int64, String) -> Void)?
    var onWindowClose: (() -> Void)?

    init(state: FloatingControlBarState) {
        self.state = state

        let savedSize = UserDefaults.standard.string(forKey: DetachedChatWindow.sizeKey)
            .map(NSSizeFromString) ?? DetachedChatWindow.defaultSize
        let contentRect = NSRect(origin: .zero, size: savedSize)

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Put the first prompt in the actual macOS title bar
        let firstPrompt = state.chatHistory.first?.question ?? state.displayedQuery
        self.title = firstPrompt.isEmpty ? "Fazm Chat" : firstPrompt
        self.minSize = NSSize(width: 360, height: 300)
        self.isReleasedWhenClosed = false
        self.delegate = self
        self.appearance = NSAppearance(named: .vibrantDark)
        self.titlebarAppearsTransparent = false
        self.titleVisibility = .visible
        self.backgroundColor = NSColor(white: 0.1, alpha: 1.0)

        // Restore saved position
        if let savedPos = UserDefaults.standard.string(forKey: DetachedChatWindow.positionKey) {
            let origin = NSPointFromString(savedPos)
            let onScreen = NSScreen.screens.contains {
                $0.visibleFrame.contains(NSPoint(x: origin.x + 50, y: origin.y + 50))
            }
            if onScreen {
                setFrameOrigin(origin)
            } else {
                center()
            }
        } else {
            center()
        }
    }

    func setupViews() {
        let chatView = DetachedChatView(
            onSendFollowUp: { [weak self] msg in self?.onSendFollowUp?(msg) },
            onNewChat: { [weak self] in self?.onNewChat?() },
            onEnqueueMessage: { [weak self] msg in self?.onEnqueueMessage?(msg) },
            onSendNowQueued: { [weak self] item in self?.onSendNowQueued?(item) },
            onDeleteQueued: { [weak self] item in self?.onDeleteQueued?(item) },
            onClearQueue: { [weak self] in self?.onClearQueue?() },
            onReorderQueue: { [weak self] src, dst in self?.onReorderQueue?(src, dst) },
            onStopAgent: { [weak self] in self?.onStopAgent?() },
            onConnectClaude: { [weak self] in self?.onConnectClaude?() },
            onObserverCardAction: { [weak self] id, action in self?.onObserverCardAction?(id, action) }
        ).environmentObject(state)

        let hosting = NSHostingView(rootView: AnyView(
            chatView
                .withFontScaling()
                .preferredColorScheme(ColorScheme.dark)
                .environment(\.colorScheme, ColorScheme.dark)
        ))
        hosting.appearance = NSAppearance(named: .vibrantDark)
        self.contentView = hosting
        self.hostingView = hosting
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
            return
        }
        // Cmd+N for new chat
        if event.keyCode == 45 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onNewChat?()
            return
        }
        super.keyDown(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: DetachedChatWindow.sizeKey)
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: DetachedChatWindow.positionKey)
        onWindowClose?()
    }

    func windowDidResize(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromSize(frame.size), forKey: DetachedChatWindow.sizeKey)
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: DetachedChatWindow.positionKey)
    }
}

// MARK: - DetachedChatView

/// SwiftUI view for the detached chat window. Reuses AIResponseView with the shared state.
struct DetachedChatView: View {
    @EnvironmentObject var state: FloatingControlBarState

    var onSendFollowUp: (String) -> Void
    var onNewChat: () -> Void
    var onEnqueueMessage: (String) -> Void
    var onSendNowQueued: (QueuedMessage) -> Void
    var onDeleteQueued: (QueuedMessage) -> Void
    var onClearQueue: () -> Void
    var onReorderQueue: (IndexSet, Int) -> Void
    var onStopAgent: () -> Void
    var onConnectClaude: () -> Void
    var onObserverCardAction: (Int64, String) -> Void

    var body: some View {
        AIResponseView(
            isLoading: Binding(
                get: { state.isAILoading },
                set: { state.isAILoading = $0 }
            ),
            currentMessage: state.currentAIMessage,
            userInput: state.displayedQuery,
            chatHistory: state.chatHistory,
            isVoiceFollowUp: Binding(
                get: { state.isVoiceFollowUp },
                set: { state.isVoiceFollowUp = $0 }
            ),
            voiceFollowUpTranscript: Binding(
                get: { state.voiceFollowUpTranscript },
                set: { state.voiceFollowUpTranscript = $0 }
            ),
            suggestedReplies: Binding(
                get: { state.suggestedReplies },
                set: { state.suggestedReplies = $0 }
            ),
            suggestedReplyQuestion: Binding(
                get: { state.suggestedReplyQuestion },
                set: { state.suggestedReplyQuestion = $0 }
            ),
            onClose: nil,
            onNewChat: onNewChat,
            onSendFollowUp: { message in
                state.suggestedReplies = []
                state.suggestedReplyQuestion = ""
                let currentQuery = state.displayedQuery
                if let currentMessage = state.currentAIMessage, !currentQuery.isEmpty, !currentMessage.text.isEmpty {
                    state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                }
                state.flushPendingObserverExchanges()
                state.displayedQuery = message
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.isAILoading = true
                    state.currentAIMessage = nil
                }
                onSendFollowUp(message)
            },
            onEnqueueMessage: { message in
                guard state.messageQueue.count < FloatingControlBarState.maxQueueSize else { return }
                state.enqueue(message)
                onEnqueueMessage(message)
            },
            onSendNow: { item in
                state.dequeue(item.id)
                let currentQuery = state.displayedQuery
                if var currentMessage = state.currentAIMessage, !currentQuery.isEmpty {
                    currentMessage.contentBlocks = currentMessage.contentBlocks.map { block in
                        if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                            return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                        }
                        return block
                    }
                    state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                }
                state.flushPendingObserverExchanges()
                state.displayedQuery = item.text
                state.isAILoading = true
                state.currentAIMessage = nil
                onSendNowQueued(item)
            },
            onDeleteQueued: { item in
                state.dequeue(item.id)
                onDeleteQueued(item)
            },
            onClearQueue: {
                state.clearQueue()
                onClearQueue()
            },
            onReorderQueue: { source, dest in
                state.messageQueue.move(fromOffsets: source, toOffset: dest)
                onReorderQueue(source, dest)
            },
            onStopAgent: onStopAgent,
            onConnectClaude: onConnectClaude,
            onObserverCardAction: onObserverCardAction
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingBackground(cornerRadius: 0)
    }
}

// MARK: - DetachedChatWindowController

/// Singleton that manages the detached chat window lifecycle.
@MainActor
class DetachedChatWindowController {
    static let shared = DetachedChatWindowController()

    private var window: DetachedChatWindow?
    private var chatCancellable: AnyCancellable?
    private var compactCancellable: AnyCancellable?

    var isShowing: Bool { window?.isVisible ?? false }

    /// Pop out the current floating bar conversation into a detached window.
    /// Creates its own FloatingControlBarState so the floating bar can reset to new chat.
    func show(
        chatHistory: [FloatingChatExchange],
        displayedQuery: String,
        currentAIMessage: ChatMessage?,
        isAILoading: Bool,
        chatProvider: ChatProvider,
        messageCountBefore: Int
    ) {
        // Reuse or create the window
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create a fresh state for the detached window, copying conversation data
        let detachedState = FloatingControlBarState()
        detachedState.chatHistory = chatHistory
        detachedState.displayedQuery = displayedQuery
        detachedState.currentAIMessage = currentAIMessage
        detachedState.isAILoading = isAILoading
        detachedState.showingAIConversation = true
        detachedState.showingAIResponse = true

        let win = DetachedChatWindow(state: detachedState)

        win.onSendFollowUp = { [weak self] message in
            self?.sendQuery(message)
        }

        win.onNewChat = { [weak detachedState, weak chatProvider] in
            guard let state = detachedState, let provider = chatProvider else { return }
            state.chatHistory = []
            state.displayedQuery = ""
            state.currentAIMessage = nil
            state.isAILoading = false
            state.aiInputText = ""
            state.clearQueue()
            Task { @MainActor in
                await provider.resetSession(key: "floating")
            }
        }

        win.onEnqueueMessage = { [weak chatProvider] message in
            chatProvider?.enqueueMessage(message)
        }

        win.onSendNowQueued = { [weak chatProvider] item in
            guard let provider = chatProvider else { return }
            Task { @MainActor in
                await provider.interruptAndSend(item.text)
            }
        }

        win.onDeleteQueued = { [weak chatProvider] item in
            guard let provider = chatProvider else { return }
            if let idx = provider.pendingMessageTexts.firstIndex(of: item.text) {
                provider.removePendingMessage(at: idx)
            }
        }

        win.onClearQueue = { [weak chatProvider] in
            chatProvider?.clearPendingMessages()
        }

        win.onReorderQueue = { [weak chatProvider] source, dest in
            chatProvider?.reorderPendingMessages(from: source, to: dest)
        }

        win.onStopAgent = { [weak chatProvider] in
            chatProvider?.stopAgent()
        }

        win.onConnectClaude = { [weak chatProvider] in
            guard let provider = chatProvider else { return }
            ClaudeAuthWindowController.shared.show(chatProvider: provider)
        }

        win.onObserverCardAction = { [weak chatProvider] activityId, action in
            chatProvider?.handleObserverCardAction(activityId: activityId, action: action)
        }

        win.onWindowClose = { [weak self] in
            self?.chatCancellable?.cancel()
            self?.chatCancellable = nil
            self?.compactCancellable?.cancel()
            self?.compactCancellable = nil
            self?.window = nil
        }

        win.setupViews()
        self.window = win

        // Subscribe to ChatProvider messages for streaming updates in the detached window
        subscribeToChatProvider(chatProvider, state: detachedState, messageCountBefore: messageCountBefore)

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Send a follow-up query from the detached window.
    private func sendQuery(_ message: String) {
        guard let win = window else { return }
        let state = win.state
        let provider = FloatingControlBarManager.shared.chatProvider
        guard let provider else { return }

        if provider.isSending {
            provider.enqueueMessage(message)
            return
        }

        let messageCountBefore = provider.messages.count
        state.suggestedReplies = []
        state.suggestedReplyQuestion = ""

        ChatToolExecutor.onQuickReplyOptions = { [weak state] question, options in
            Task { @MainActor in
                state?.suggestedReplyQuestion = question
                state?.suggestedReplies = options
            }
        }

        subscribeToChatProvider(provider, state: state, messageCountBefore: messageCountBefore)

        Task { @MainActor in
            await provider.sendMessage(
                message,
                model: ShortcutSettings.shared.selectedModel,
                systemPromptSuffix: nil,
                systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent,
                sessionKey: "floating"
            )
            state.isAILoading = false
        }
    }

    /// Subscribe to ChatProvider.$messages for streaming response updates.
    private func subscribeToChatProvider(_ provider: ChatProvider, state: FloatingControlBarState, messageCountBefore: Int) {
        chatCancellable?.cancel()
        chatCancellable = provider.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak state] messages in
                guard let state else { return }
                guard messages.count > messageCountBefore,
                      let aiMessage = messages.last,
                      aiMessage.sender == .ai else { return }

                state.currentAIMessage = aiMessage
                if aiMessage.isStreaming {
                    state.isAILoading = false
                    if !state.showingAIResponse {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            state.showingAIResponse = true
                        }
                    }
                } else {
                    state.isAILoading = false
                }
            }

        compactCancellable?.cancel()
        compactCancellable = provider.$isCompacting
            .receive(on: DispatchQueue.main)
            .sink { [weak state] isCompacting in
                state?.isCompacting = isCompacting
            }
    }

    func close() {
        window?.close()
        window = nil
    }
}
