import Cocoa
import Combine
import SwiftUI

/// A normal macOS window that hosts the chat conversation after "popping out" from the floating bar.
/// Not always-on-top — behaves like a regular app window.
class DetachedChatWindow: NSWindow, NSWindowDelegate {
    private static let sizeKey = "DetachedChatWindowSize"
    private static let positionKey = "DetachedChatWindowPosition"
    private static let defaultSize = NSSize(width: 480, height: 600)

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

        self.title = "Fazm Chat"
        self.minSize = NSSize(width: 360, height: 300)
        self.isReleasedWhenClosed = false
        self.delegate = self
        self.appearance = NSAppearance(named: .vibrantDark)
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
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
        // Save position and size
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

    /// The first user prompt in this chat session.
    private var sessionTitle: String {
        if let first = state.chatHistory.first, !first.question.isEmpty {
            return first.question
        }
        if !state.displayedQuery.isEmpty {
            return state.displayedQuery
        }
        return "Chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session title bar
            HStack(spacing: 0) {
                Text(sessionTitle)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

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
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
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

    var isShowing: Bool { window?.isVisible ?? false }

    /// Pop out the current floating bar conversation into a detached window.
    func show(
        state: FloatingControlBarState,
        chatProvider: ChatProvider,
        onSendQuery: @escaping (String) -> Void
    ) {
        // Reuse or create the window
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = DetachedChatWindow(state: state)

        win.onSendFollowUp = { message in
            onSendQuery(message)
        }

        win.onNewChat = { [weak state, weak chatProvider] in
            guard let state, let provider = chatProvider else { return }
            state.chatHistory = []
            state.displayedQuery = ""
            state.currentAIMessage = nil
            state.isAILoading = false
            state.showingAIResponse = false
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

        win.onWindowClose = { [weak self, weak state] in
            // Snapshot conversation so floating bar can restore it
            guard let state else { return }
            if let msg = state.currentAIMessage, !msg.text.isEmpty {
                var fullHistory = state.chatHistory
                if !state.displayedQuery.isEmpty {
                    fullHistory.append(FloatingChatExchange(question: state.displayedQuery, aiMessage: msg))
                }
                if !fullHistory.isEmpty {
                    let last = fullHistory.last!
                    state.lastConversation = (
                        history: Array(fullHistory.dropLast()),
                        lastQuestion: last.question,
                        lastMessage: last.aiMessage
                    )
                }
            }
            self?.window = nil
        }

        win.setupViews()
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
