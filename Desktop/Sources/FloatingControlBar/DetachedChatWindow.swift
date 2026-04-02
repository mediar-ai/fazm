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
    var onChangeWorkspace: (() -> Void)?
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
        self.titlebarAppearsTransparent = false
        self.titleVisibility = .visible
        self.backgroundColor = NSColor(FazmColors.backgroundPrimary)

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
            onObserverCardAction: { [weak self] id, action in self?.onObserverCardAction?(id, action) },
            onChangeWorkspace: onChangeWorkspace != nil ? { [weak self] in self?.onChangeWorkspace?() } : nil
        ).environmentObject(state)

        let hosting = NSHostingView(rootView: AnyView(
            chatView
                .withFontScaling()
        ))
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

    /// Focus the first editable text field (follow-up input or main input).
    @discardableResult
    func focusInputField() -> Bool {
        guard let contentView = self.contentView else { return false }
        func findTextField(in view: NSView) -> NSView? {
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            if let textField = view as? NSTextField, textField.isEditable { return textField }
            for subview in view.subviews {
                if let found = findTextField(in: subview) { return found }
            }
            return nil
        }
        if let field = findTextField(in: contentView) {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(field)
            return true
        }
        return false
    }

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
    var onChangeWorkspace: (() -> Void)?

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
                if let currentMessage = state.currentAIMessage, !currentQuery.isEmpty,
                   !currentMessage.text.isEmpty || !currentMessage.contentBlocks.isEmpty {
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
            onObserverCardAction: onObserverCardAction,
            onChangeWorkspace: onChangeWorkspace
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingBackground(cornerRadius: 0)
    }
}

// MARK: - DetachedChatWindowController

/// Manages multiple detached chat windows, each with its own ACP session.
@MainActor
class DetachedChatWindowController {
    static let shared = DetachedChatWindowController()

    /// Per-window state: the window, its ACP session key, and Combine subscriptions.
    private struct WindowEntry {
        let window: DetachedChatWindow
        var sessionKey: String
        var chatCancellable: AnyCancellable?
        var compactCancellable: AnyCancellable?
        var dequeueCancellable: AnyCancellable?
    }

    private var entries: [ObjectIdentifier: WindowEntry] = [:]

    var isShowing: Bool { entries.values.contains { $0.window.isVisible } }

    /// Pop out the current floating bar conversation into a new detached window.
    /// Each call creates a separate window with its own ACP session.
    func show(
        chatHistory: [FloatingChatExchange],
        displayedQuery: String,
        currentAIMessage: ChatMessage?,
        isAILoading: Bool,
        chatProvider: ChatProvider,
        messageCountBefore: Int,
        sessionKey: String
    ) {
        // Create a fresh state for the detached window, copying conversation data
        let detachedState = FloatingControlBarState()
        detachedState.chatHistory = chatHistory
        detachedState.displayedQuery = displayedQuery
        detachedState.currentAIMessage = currentAIMessage
        detachedState.isAILoading = isAILoading
        detachedState.showingAIConversation = true
        detachedState.showingAIResponse = true

        let win = DetachedChatWindow(state: detachedState)
        let winId = ObjectIdentifier(win)

        win.onSendFollowUp = { [weak self, weak win] message in
            guard let win else { return }
            self?.sendQuery(message, for: win)
        }

        win.onNewChat = { [weak self, weak win, weak detachedState, weak chatProvider] in
            guard let self, let win, let state = detachedState, let provider = chatProvider else { return }
            state.chatHistory = []
            state.displayedQuery = ""
            state.currentAIMessage = nil
            state.isAILoading = false
            state.aiInputText = ""
            state.clearQueue()
            let id = ObjectIdentifier(win)
            let oldKey = self.entries[id]?.sessionKey
            self.entries[id]?.sessionKey = "detached-\(UUID().uuidString)"
            Task { @MainActor in
                if let oldKey {
                    await provider.resetSession(key: oldKey)
                }
            }
        }

        win.onEnqueueMessage = { [weak self, weak win, weak chatProvider] message in
            guard let win else { return }
            let key = self?.entries[ObjectIdentifier(win)]?.sessionKey
            chatProvider?.enqueueMessage(message, sessionKey: key)
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

        win.onChangeWorkspace = { [weak self, weak win, weak detachedState, weak chatProvider] in
            guard let self, let win, let state = detachedState, let provider = chatProvider else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Select a project directory"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let newPath = url.path
            // Update the workspace
            provider.aiChatWorkingDirectory = newPath
            provider.workingDirectory = newPath
            Task { await provider.discoverClaudeConfig() }

            // Reset session for this detached window
            let id = ObjectIdentifier(win)
            state.chatHistory = []
            state.displayedQuery = ""
            state.currentAIMessage = nil
            state.isAILoading = false
            state.aiInputText = ""
            state.clearQueue()
            let oldKey = self.entries[id]?.sessionKey
            self.entries[id]?.sessionKey = "detached-\(UUID().uuidString)"
            Task { @MainActor in
                if let oldKey {
                    await provider.resetSession(key: oldKey)
                }
            }
        }

        win.onWindowClose = { [weak self, weak win] in
            guard let self, let win else { return }
            let id = ObjectIdentifier(win)
            self.entries[id]?.chatCancellable?.cancel()
            self.entries[id]?.compactCancellable?.cancel()
            self.entries[id]?.dequeueCancellable?.cancel()
            self.entries.removeValue(forKey: id)
        }

        win.setupViews()

        var entry = WindowEntry(window: win, sessionKey: sessionKey)
        entries[winId] = entry
        // Subscribe to ChatProvider messages for streaming updates
        subscribeToResponse(provider: chatProvider, state: detachedState, winId: winId, messageCountBefore: messageCountBefore)
        // Subscribe to compacting state
        entries[winId]?.compactCancellable?.cancel()
        entries[winId]?.compactCancellable = chatProvider.$isCompacting
            .receive(on: DispatchQueue.main)
            .sink { [weak detachedState] isCompacting in
                detachedState?.isCompacting = isCompacting
            }

        // Offset new windows so they don't stack directly on top of each other
        if entries.count > 1 {
            let offset = CGFloat((entries.count - 1) * 30)
            var frame = win.frame
            frame.origin.x += offset
            frame.origin.y -= offset
            win.setFrame(frame, display: false)
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Send a follow-up query from a specific detached window.
    private func sendQuery(_ message: String, for win: DetachedChatWindow) {
        let winId = ObjectIdentifier(win)
        guard let sessionKey = entries[winId]?.sessionKey else { return }
        let state = win.state
        let provider = FloatingControlBarManager.shared.chatProvider
        guard let provider else { return }

        if provider.isSending {
            provider.enqueueMessage(message, sessionKey: sessionKey)
            // Listen for when this message is dequeued so we can set up the response subscriber
            entries[winId]?.dequeueCancellable?.cancel()
            entries[winId]?.dequeueCancellable = NotificationCenter.default
                .publisher(for: .chatProviderDidDequeue)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak state, weak win] notification in
                    guard let self, let state, let win else { return }
                    let id = ObjectIdentifier(win)
                    // Archive the current exchange before the new query replaces it
                    let currentQuery = state.displayedQuery
                    var aiMessage = state.currentAIMessage
                    if aiMessage == nil,
                       let currentKey = self.entries[id]?.sessionKey,
                       let latestAI = provider.messages.last(where: { $0.sender == .ai && $0.sessionKey == currentKey }),
                       !latestAI.text.isEmpty {
                        aiMessage = latestAI
                    }
                    if var currentMessage = aiMessage, !currentQuery.isEmpty {
                        currentMessage.contentBlocks = currentMessage.contentBlocks.map { block in
                            if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                                return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                            }
                            return block
                        }
                        state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: currentMessage))
                    }
                    state.flushPendingObserverExchanges()
                    if let text = notification.userInfo?["text"] as? String {
                        state.displayedQuery = text
                    }
                    state.isAILoading = true
                    state.currentAIMessage = nil
                    // Set up the response subscriber now that our message is being sent
                    let countBefore = provider.messages.count
                    self.subscribeToResponse(provider: provider, state: state, winId: id, messageCountBefore: countBefore)
                    // One-shot: cancel after first dequeue
                    self.entries[id]?.dequeueCancellable?.cancel()
                    self.entries[id]?.dequeueCancellable = nil
                }
            return
        }

        startQuery(message: message, for: win, winId: winId, sessionKey: sessionKey, state: state, provider: provider)
    }

    /// Start sending a query immediately (provider is not busy).
    private func startQuery(message: String, for win: DetachedChatWindow, winId: ObjectIdentifier, sessionKey: String, state: FloatingControlBarState, provider: ChatProvider) {
        let messageCountBefore = provider.messages.count
        state.suggestedReplies = []
        state.suggestedReplyQuestion = ""

        ChatToolExecutor.onQuickReplyOptions = { [weak state] question, options in
            Task { @MainActor in
                state?.suggestedReplyQuestion = question
                state?.suggestedReplies = options
            }
        }

        subscribeToResponse(provider: provider, state: state, winId: winId, messageCountBefore: messageCountBefore)

        Task { @MainActor in
            await provider.sendMessage(
                message,
                model: ShortcutSettings.shared.selectedModel,
                systemPromptSuffix: nil,
                systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent,
                sessionKey: sessionKey
            )
            state.isAILoading = false

            // Sync the latest AI message directly from provider.messages to close the
            // race window where sendMessage has returned but the Combine $messages sink
            // (scheduled via .receive(on: .main)) hasn't fired yet.
            if let latestAI = provider.messages.last(where: { $0.sender == .ai && $0.sessionKey == sessionKey }),
               !latestAI.text.isEmpty || !latestAI.contentBlocks.isEmpty {
                state.currentAIMessage = latestAI
            }
        }
    }

    /// Subscribe to ChatProvider messages for streaming response updates.
    private func subscribeToResponse(provider: ChatProvider, state: FloatingControlBarState, winId: ObjectIdentifier, messageCountBefore: Int) {
        let sessionKey = entries[winId]?.sessionKey
        entries[winId]?.chatCancellable?.cancel()
        entries[winId]?.chatCancellable = provider.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state, weak provider] messages in
                guard let state else { return }
                // Filter to messages belonging to this detached window's session
                let currentKey = self?.entries[winId]?.sessionKey ?? sessionKey
                guard messages.count > messageCountBefore,
                      let aiMessage = messages.last(where: { $0.sender == .ai && $0.sessionKey == currentKey })
                      else { return }
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
                    // Clear stale messages from provider now that streaming is done.
                    // These were kept alive during pop-out so the in-flight query could
                    // continue writing to them. The floating bar doesn't need them anymore.
                    provider?.clearTransferredMessages()
                }
            }
    }


    /// Focus the input field of the detached window that owns the given state.
    func focusInputField(for state: FloatingControlBarState) {
        for entry in entries.values where entry.window.state === state {
            entry.window.focusInputField()
            return
        }
    }

    func close() {
        for entry in entries.values {
            entry.window.close()
        }
        entries.removeAll()
    }
}
