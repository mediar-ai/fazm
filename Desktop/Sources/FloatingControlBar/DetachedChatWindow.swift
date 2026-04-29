import Cocoa
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A normal macOS window that hosts the chat conversation after "popping out" from the floating bar.
/// Not always-on-top — behaves like a regular app window.
class DetachedChatWindow: NSWindow, NSWindowDelegate {
    static let defaultSize = NSSize(width: 624, height: 900)

    let state: FloatingControlBarState
    /// The session key for this window, used for per-window frame persistence.
    var sessionKey: String
    private var hostingView: NSHostingView<AnyView>?

    var onSendFollowUp: ((String, [ChatAttachment]) -> Void)?
    var onEnqueueMessage: ((String) -> Void)?
    var onSendNowQueued: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?
    var onStopAgent: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onChatObserverCardAction: ((Int64, String) -> Void)?
    var onChangeWorkspace: (() -> Void)?
    var onWindowClose: (() -> Void)?

    init(state: FloatingControlBarState, sessionKey: String, savedFrame: NSRect? = nil) {
        self.state = state
        self.sessionKey = sessionKey

        let size = savedFrame?.size ?? DetachedChatWindow.defaultSize
        let contentRect = NSRect(origin: .zero, size: size)

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
        self.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing

        // Restore saved position
        if let savedOrigin = savedFrame?.origin {
            let onScreen = NSScreen.screens.contains {
                $0.visibleFrame.contains(NSPoint(x: savedOrigin.x + 50, y: savedOrigin.y + 50))
            }
            if onScreen {
                setFrameOrigin(savedOrigin)
            } else {
                center()
            }
        } else {
            center()
        }
    }

    func setupViews() {
        let chatView = DetachedChatView(
            onSendFollowUp: { [weak self] msg, attachments in self?.onSendFollowUp?(msg, attachments) },
            onNewChat: { [weak self] in self?.onNewChat?() },
            onEnqueueMessage: { [weak self] msg in self?.onEnqueueMessage?(msg) },
            onSendNowQueued: { [weak self] item in self?.onSendNowQueued?(item) },
            onDeleteQueued: { [weak self] item in self?.onDeleteQueued?(item) },
            onClearQueue: { [weak self] in self?.onClearQueue?() },
            onReorderQueue: { [weak self] src, dst in self?.onReorderQueue?(src, dst) },
            onStopAgent: { [weak self] in self?.onStopAgent?() },
            onConnectClaude: { [weak self] in self?.onConnectClaude?() },
            onChatObserverCardAction: { [weak self] id, action in self?.onChatObserverCardAction?(id, action) },
            onChangeWorkspace: onChangeWorkspace != nil ? { [weak self] in self?.onChangeWorkspace?() } : nil
        ).environmentObject(state)

        let hosting = NSHostingView(rootView: AnyView(
            chatView
                .withFontScaling()
        ))
        // Use a container view with explicit Auto Layout constraints so the
        // hosting view fills the window content area. Without this, the default
        // sizingOptions (.intrinsicContentSize) lets the hosting view expand
        // beyond the window to fit its SwiftUI content, causing text overflow.
        let container = NSView()
        self.contentView = container

        hosting.sizingOptions = [.maxSize]
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
        onWindowClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DetachedChatWindowController.shared.lastActiveWindow = self
    }

    func windowDidResize(_ notification: Notification) {
        DetachedChatWindowController.shared.saveWindowRegistry()
    }

    func windowDidMove(_ notification: Notification) {
        DetachedChatWindowController.shared.saveWindowRegistry()
    }
}

// MARK: - DetachedChatView

/// SwiftUI view for the detached chat window. Reuses AIResponseView with the shared state.
struct DetachedChatView: View {
    @EnvironmentObject var state: FloatingControlBarState

    var onSendFollowUp: (String, [ChatAttachment]) -> Void
    var onNewChat: () -> Void
    var onEnqueueMessage: (String) -> Void
    var onSendNowQueued: (QueuedMessage) -> Void
    var onDeleteQueued: (QueuedMessage) -> Void
    var onClearQueue: () -> Void
    var onReorderQueue: (IndexSet, Int) -> Void
    var onStopAgent: () -> Void
    var onConnectClaude: () -> Void
    var onChatObserverCardAction: (Int64, String) -> Void
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
            localModel: Binding(
                get: { state.selectedModel },
                set: { state.selectedModel = $0 }
            ),
            onClose: nil,
            onNewChat: onNewChat,
            onSendFollowUp: { message, attachments in
                state.suggestedReplies = []
                state.suggestedReplyQuestion = ""
                let currentQuery = state.displayedQuery
                if !currentQuery.isEmpty {
                    let aiMessage = state.currentAIMessage ?? ChatMessage(
                        id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                        isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
                    )
                    log("[DetachedChat] onSendFollowUp: archiving exchange question='\(currentQuery.prefix(40))' aiMessage.id=\(aiMessage.id) historyCount=\(state.chatHistory.count)")
                    state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: aiMessage))
                }
                state.flushPendingChatObserverExchanges()
                state.displayedQuery = message
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.isAILoading = true
                    state.currentAIMessage = nil
                }
                onSendFollowUp(message, attachments)
            },
            onEnqueueMessage: { message in
                guard state.messageQueue.count < FloatingControlBarState.maxQueueSize else { return }
                state.enqueue(message)
                onEnqueueMessage(message)
            },
            onSendNow: { item in
                state.dequeue(item.id)
                let currentQuery = state.displayedQuery
                if !currentQuery.isEmpty {
                    var aiMessage = state.currentAIMessage ?? ChatMessage(
                        id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                        isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
                    )
                    aiMessage.contentBlocks = aiMessage.contentBlocks.map { block in
                        if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                            return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                        }
                        return block
                    }
                    state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: aiMessage))
                }
                state.flushPendingChatObserverExchanges()
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
            onChatObserverCardAction: onChatObserverCardAction,
            onChangeWorkspace: onChangeWorkspace
        )
        .overlay {
            if state.isDragOverChat {
                ChatDragOverlay()
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $state.isDragOverChat) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        // loadItem may return URL, Data, or NSSecureCoding depending on source app
                        let resolvedURL: URL?
                        if let url = item as? URL {
                            resolvedURL = url
                        } else if let data = item as? Data,
                                  let urlStr = String(data: data, encoding: .utf8),
                                  let url = URL(string: urlStr) {
                            resolvedURL = url
                        } else {
                            NSLog("[Attachment] Drop failed: could not resolve file URL (item=%@, error=%@)", "\(type(of: item))", "\(String(describing: error))")
                            resolvedURL = nil
                        }
                        guard let url = resolvedURL else { return }
                        DispatchQueue.main.async {
                            ChatAttachmentHelper.addFiles(from: [url], to: &state.pendingAttachments)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.png.identifier, options: nil) { item, error in
                        let imageData: Data?
                        if let data = item as? Data {
                            imageData = data
                        } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                            imageData = data
                        } else {
                            NSLog("[Attachment] Drop failed: could not resolve image data (item=%@, error=%@)", "\(type(of: item))", "\(String(describing: error))")
                            imageData = nil
                        }
                        guard let data = imageData else { return }
                        DispatchQueue.main.async {
                            ChatAttachmentHelper.addPastedImage(data, to: &state.pendingAttachments)
                        }
                    }
                }
            }
            return true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingBackground(cornerRadius: 0)
    }
}

// MARK: - DetachedChatWindowController

/// Manages multiple detached chat windows, each with its own ACP session.
@MainActor
class DetachedChatWindowController {
    static let shared = DetachedChatWindowController()

    /// UserDefaults key for the list of open detached windows.
    private static let registryKey = "DetachedWindowRegistry"

    /// Per-window state: the window, its ACP session key, and Combine subscriptions.
    private struct WindowEntry {
        let window: DetachedChatWindow
        var sessionKey: String
        var chatCancellable: AnyCancellable?
        var sharedProviderCancellables: [AnyCancellable] = []
        var dequeueCancellable: AnyCancellable?
    }

    /// Serializable snapshot of a detached window for persistence.
    private struct WindowSnapshot: Codable {
        let sessionKey: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        /// Per-window workspace directory (empty = global default). Added in v0.3+; older snapshots decode as "".
        var workspace: String = ""
        /// Per-window model selection. Added in a later version; older snapshots decode as the current global model.
        var selectedModel: String = UserDefaults.standard.string(forKey: "shortcut_selectedModel") ?? "claude-sonnet-4-6"
    }

    private var entries: [ObjectIdentifier: WindowEntry] = [:]
    /// Tracks the most recently focused detached window for size/position inheritance.
    fileprivate(set) weak var lastActiveWindow: DetachedChatWindow?
    /// Set during app termination so window-close handlers preserve the registry.
    private var isTerminating = false

    var isShowing: Bool { entries.values.contains { $0.window.isVisible } }

    /// Called from applicationWillTerminate to freeze the registry before windows tear down.
    func prepareForTermination() {
        isTerminating = true
        saveWindowRegistry()
    }

    /// Persist the current set of open detached windows (session keys + frames) to UserDefaults.
    func saveWindowRegistry() {
        let snapshots: [WindowSnapshot] = entries.values.map { entry in
            let f = entry.window.frame
            return WindowSnapshot(
                sessionKey: entry.sessionKey,
                x: f.origin.x, y: f.origin.y,
                width: f.size.width, height: f.size.height,
                workspace: entry.window.state.workspaceDirectory,
                selectedModel: entry.window.state.selectedModel
            )
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.registryKey)
        }
    }

    /// Remove all saved window state (called when user explicitly closes all windows or starts new chat).
    private func clearWindowRegistry() {
        UserDefaults.standard.removeObject(forKey: Self.registryKey)
    }

    /// Pop out the current floating bar conversation into a new detached window.
    /// Each call creates a separate window with its own ACP session.
    /// - Parameter inheritWorkspaceFrom: optional source state whose workspace + project config
    ///   should be copied onto the new window (instead of using the shared provider's workspace).
    ///   Used by Cmd+Shift+N so a new pop-out inherits the workspace of the currently focused pop-out.
    func show(
        chatHistory: [FloatingChatExchange],
        displayedQuery: String,
        currentAIMessage: ChatMessage?,
        isAILoading: Bool,
        chatProvider: ChatProvider,
        messageCountBefore: Int,
        sessionKey: String,
        skipPersist: Bool = false,
        inheritWorkspaceFrom: FloatingControlBarState? = nil
    ) {
        // Create a fresh state for the detached window, copying conversation data
        let detachedState = FloatingControlBarState()
        detachedState.chatHistory = chatHistory
        detachedState.displayedQuery = displayedQuery
        detachedState.currentAIMessage = currentAIMessage
        detachedState.isAILoading = isAILoading
        detachedState.showingAIConversation = true
        detachedState.showingAIResponse = true

        // Workspace: prefer inherited (from currently focused pop-out) over shared provider,
        // so Cmd+Shift+N from a per-window-workspace pop-out keeps that same workspace.
        if let source = inheritWorkspaceFrom {
            detachedState.workspaceDirectory = source.workspaceDirectory
            detachedState.projectClaudeMdContent = source.projectClaudeMdContent
            detachedState.projectClaudeMdPath = source.projectClaudeMdPath
            detachedState.projectDiscoveredSkills = source.projectDiscoveredSkills
        } else {
            detachedState.workspaceDirectory = chatProvider.aiChatWorkingDirectory
            detachedState.projectClaudeMdContent = chatProvider.projectClaudeMdContent
            detachedState.projectClaudeMdPath = chatProvider.projectClaudeMdPath
            detachedState.projectDiscoveredSkills = chatProvider.projectDiscoveredSkills
        }

        let win = DetachedChatWindow(state: detachedState, sessionKey: sessionKey)
        let winId = ObjectIdentifier(win)

        wireUpCallbacks(win: win, detachedState: detachedState, chatProvider: chatProvider)

        win.setupViews()

        entries[winId] = WindowEntry(window: win, sessionKey: sessionKey)
        // Subscribe to ChatProvider messages for streaming updates
        subscribeToResponse(provider: chatProvider, state: detachedState, winId: winId, messageCountBefore: messageCountBefore)
        // Subscribe to shared provider state (auth, suggested replies, compaction)
        entries[winId]?.sharedProviderCancellables = ChatQueryLifecycle.subscribeToProviderState(
            provider: chatProvider, state: detachedState,
            sessionKeyProvider: { [weak self] in self?.entries[winId]?.sessionKey }
        )

        // If a query was in-flight when we popped out, the floating bar's handlePostQuery
        // will return early (showingAIConversation is false on its reset state). We need
        // to detect when the query finishes and run error handling on our detached state.
        if isAILoading {
            entries[winId]?.sharedProviderCancellables.append(
                chatProvider.$isSending
                    .dropFirst() // skip the current value
                    .filter { !$0 } // only when sending finishes
                    .first() // one-shot
                    .receive(on: DispatchQueue.main)
                    .sink { [weak detachedState, weak chatProvider] _ in
                        guard let state = detachedState, let provider = chatProvider else { return }
                        guard state.isAILoading else { return } // already handled by subscription
                        ChatQueryLifecycle.handlePostQuery(provider: provider, state: state, sessionKey: sessionKey, messageCountBefore: messageCountBefore)
                    }
            )
        }

        // Position new pop-out relative to the last active pop-out (or floating bar):
        // inherit size, try right → below → left → above, then fall back to center.
        // Also check other existing detached windows as potential anchors.
        let anchor: NSWindow? = {
            if let active = lastActiveWindow, active !== win { return active }
            // Fall back to any other open detached window
            for entry in entries.values where entry.window !== win {
                return entry.window
            }
            // No other detached windows available; skip floating bar anchor
            // since it's a different window type with different sizing
            return nil
        }()

        if let anchor = anchor {
            let anchorFrame = anchor.frame
            let sz = (lastActiveWindow != nil && lastActiveWindow !== win) ? anchorFrame.size : DetachedChatWindow.defaultSize
            let gap: CGFloat = 8

            // Candidate positions in priority order: right, below, left, above
            let candidates: [NSRect] = [
                NSRect(x: anchorFrame.maxX + gap, y: anchorFrame.origin.y, width: sz.width, height: sz.height),
                NSRect(x: anchorFrame.origin.x, y: anchorFrame.origin.y - sz.height - gap, width: sz.width, height: sz.height),
                NSRect(x: anchorFrame.origin.x - sz.width - gap, y: anchorFrame.origin.y, width: sz.width, height: sz.height),
                NSRect(x: anchorFrame.origin.x, y: anchorFrame.maxY + gap, width: sz.width, height: sz.height),
            ]

            let fitsOnScreen: (NSRect) -> Bool = { rect in
                NSScreen.screens.contains {
                    let visible = $0.visibleFrame
                    // The candidate must fit mostly within a single screen's visible area
                    return visible.contains(NSPoint(x: rect.minX + 50, y: rect.minY + 50))
                        && visible.contains(NSPoint(x: rect.maxX - 50, y: rect.maxY - 50))
                }
            }

            if let placed = candidates.first(where: fitsOnScreen) {
                win.setFrame(placed, display: false)
            } else {
                // Nothing fits: keep inherited size, center on screen
                win.setContentSize(sz)
                win.center()
            }
        } else {
            // No anchor at all: use default size and center
            win.setContentSize(DetachedChatWindow.defaultSize)
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        saveWindowRegistry()

        // Persist the initial conversation to the detached session's DB context
        // so it can be restored on next launch. The floating bar already saved these
        // under __floating__, but we need them under the detached key.
        // Skip if reopening an existing detached session (messages already persisted).
        if !skipPersist {
            let context = "__\(sessionKey)__"
            // Carry over the ACP session ID from the source conversation (e.g. floating bar)
            // so this detached session can be resumed from history later.
            let sourceSessionId = UserDefaults.standard.string(forKey: "acpSessionId_floating_\(chatProvider.bridgeMode)")
            Task {
                for exchange in chatHistory {
                    // Skip empty AI placeholder messages (from unpaired consecutive user messages)
                    guard !exchange.aiMessage.text.isEmpty else {
                        // Still save the user message
                        let userDate = exchange.aiMessage.createdAt.addingTimeInterval(-0.1)
                        let userMsg = ChatMessage(text: exchange.question, createdAt: userDate, sender: .user, sessionKey: sessionKey)
                        await ChatMessageStore.saveMessage(userMsg, context: context, sessionId: sourceSessionId)
                        continue
                    }
                    // Use a timestamp just before the AI message so ordering is correct
                    let userDate = exchange.aiMessage.createdAt.addingTimeInterval(-0.1)
                    let userMsg = ChatMessage(text: exchange.question, createdAt: userDate, sender: .user, sessionKey: sessionKey)
                    await ChatMessageStore.saveMessage(userMsg, context: context, sessionId: sourceSessionId)
                    await ChatMessageStore.saveMessage(exchange.aiMessage, context: context, sessionId: sourceSessionId)
                }
                if !displayedQuery.isEmpty {
                    let userDate = currentAIMessage?.createdAt.addingTimeInterval(-0.1) ?? Date()
                    let userMsg = ChatMessage(text: displayedQuery, createdAt: userDate, sender: .user, sessionKey: sessionKey)
                    await ChatMessageStore.saveMessage(userMsg, context: context, sessionId: sourceSessionId)
                }
                if let aiMsg = currentAIMessage, !aiMsg.text.isEmpty {
                    await ChatMessageStore.saveMessage(aiMsg, context: context, sessionId: sourceSessionId)
                }
            }
        }
    }

    /// Restore detached windows that were open when the app last quit.
    /// Loads conversation history from the local DB and recreates each window at its saved position.
    func restoreWindows(chatProvider: ChatProvider) {
        guard let data = UserDefaults.standard.data(forKey: Self.registryKey),
              let snapshots = try? JSONDecoder().decode([WindowSnapshot].self, from: data),
              !snapshots.isEmpty else { return }

        log("DetachedChatWindowController: Restoring \(snapshots.count) detached window(s)")

        // Keep the registry intact until all restore tasks finish.
        // Failed entries stay persisted so the next launch can retry.
        let totalCount = snapshots.count
        var restoredCount = 0
        var failedSnapshots: [WindowSnapshot] = []
        let group = DispatchGroup()

        for snapshot in snapshots {
            let sessionKey = snapshot.sessionKey
            let savedFrame = NSRect(
                x: snapshot.x, y: snapshot.y,
                width: snapshot.width, height: snapshot.height
            )

            group.enter()
            Task { @MainActor in
                defer { group.leave() }
                var savedMessages: [ChatMessage] = []
                for attempt in 0..<10 {
                    savedMessages = await ChatMessageStore.loadMessages(
                        context: "__\(sessionKey)__",
                        limit: 100
                    )
                    if !savedMessages.isEmpty { break }
                    if attempt < 9 {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    }
                }
                guard !savedMessages.isEmpty else {
                    log("DetachedChatWindowController: No messages for \(sessionKey) after 10 retries, keeping in registry for next launch")
                    failedSnapshots.append(snapshot)
                    return
                }

                let detachedState = FloatingControlBarState()
                detachedState.loadHistory(from: savedMessages)
                detachedState.showingAIConversation = true
                detachedState.showingAIResponse = true
                detachedState.isAILoading = false

                // Restore per-window model selection and workspace
                detachedState.selectedModel = snapshot.selectedModel
                detachedState.workspaceDirectory = snapshot.workspace
                if !snapshot.workspace.isEmpty {
                    Task {
                        let config = await ChatProvider.discoverProjectConfig(workspace: snapshot.workspace)
                        await MainActor.run {
                            detachedState.projectClaudeMdContent = config.claudeMdContent
                            detachedState.projectClaudeMdPath = config.claudeMdPath
                            detachedState.projectDiscoveredSkills = config.skills
                        }
                    }
                }

                let win = DetachedChatWindow(state: detachedState, sessionKey: sessionKey, savedFrame: savedFrame)
                let winId = ObjectIdentifier(win)

                self.wireUpCallbacks(win: win, detachedState: detachedState, chatProvider: chatProvider)

                win.setupViews()

                self.entries[winId] = WindowEntry(window: win, sessionKey: sessionKey)
                self.entries[winId]?.sharedProviderCancellables = ChatQueryLifecycle.subscribeToProviderState(
                    provider: chatProvider, state: detachedState,
                    sessionKeyProvider: { [weak self] in self?.entries[winId]?.sessionKey }
                )

                win.makeKeyAndOrderFront(nil)
                restoredCount += 1
                log("DetachedChatWindowController: Restored window for \(sessionKey) with \(savedMessages.count) messages")
            }
        }

        group.notify(queue: .main) {
            if failedSnapshots.isEmpty {
                // All restored successfully; registry will be kept up-to-date by saveWindowRegistry
                self.saveWindowRegistry()
            } else {
                // Re-persist failed entries so they survive to the next launch
                let allSnapshots = self.entries.values.map { entry in
                    let f = entry.window.frame
                    return WindowSnapshot(
                        sessionKey: entry.sessionKey,
                        x: f.origin.x, y: f.origin.y,
                        width: f.size.width, height: f.size.height,
                        workspace: entry.window.state.workspaceDirectory,
                        selectedModel: entry.window.state.selectedModel
                    )
                } + failedSnapshots
                if let data = try? JSONEncoder().encode(allSnapshots) {
                    UserDefaults.standard.set(data, forKey: Self.registryKey)
                }
            }
            log("DetachedChatWindowController: Restore complete — \(restoredCount)/\(totalCount) succeeded, \(failedSnapshots.count) deferred")
        }
    }

    /// Wire up all callbacks for a detached window. Shared between show() and restoreWindows().
    private func wireUpCallbacks(win: DetachedChatWindow, detachedState: FloatingControlBarState, chatProvider: ChatProvider) {
        win.onSendFollowUp = { [weak self, weak win] message, attachments in
            guard let win else { return }
            self?.sendQuery(message, attachments: attachments, for: win)
        }

        win.onNewChat = { [weak self, weak win, weak detachedState, weak chatProvider] in
            guard let self, let win, let state = detachedState, let provider = chatProvider else { return }
            state.chatHistory = []
            state.displayedQuery = ""
            state.currentAIMessage = nil
            state.isAILoading = false
            state.aiInputText = ""
            state.suggestedReplies = []
            state.suggestedReplyQuestion = ""
            state.clearQueue()
            let id = ObjectIdentifier(win)
            let oldKey = self.entries[id]?.sessionKey
            let newKey = "detached-\(UUID().uuidString)"
            self.entries[id]?.sessionKey = newKey
            win.sessionKey = newKey
            self.saveWindowRegistry()
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

        win.onClearQueue = { [weak self, weak win, weak chatProvider] in
            guard let win else { return }
            let key = self?.entries[ObjectIdentifier(win)]?.sessionKey
            if let key {
                chatProvider?.clearPendingMessages(forSession: key)
            } else {
                chatProvider?.clearPendingMessages()
            }
        }

        win.onReorderQueue = { [weak chatProvider] source, dest in
            chatProvider?.reorderPendingMessages(from: source, to: dest)
        }

        win.onStopAgent = { [weak self, weak win, weak chatProvider] in
            guard let win else { return }
            // Eagerly clear loading state so the UI feels responsive. Without this,
            // the spinner and "Not Responding" banner stay until the bridge finishes
            // aborting, which can be never if the SDK promise is stuck after a hang.
            // Bridge cleanup still runs async; any partial response that arrives later
            // is handled by the existing $messages subscriber.
            win.state.isAILoading = false
            let key = self?.entries[ObjectIdentifier(win)]?.sessionKey
            if let key {
                chatProvider?.stopAgent(sessionKey: key)
            } else {
                chatProvider?.stopAgent()
            }
        }

        win.onConnectClaude = { [weak chatProvider] in
            guard let provider = chatProvider else { return }
            ClaudeAuthWindowController.shared.show(chatProvider: provider)
        }

        win.onChatObserverCardAction = { [weak chatProvider] activityId, action in
            chatProvider?.handleChatObserverCardAction(activityId: activityId, action: action)
        }

        win.onChangeWorkspace = { [weak self, weak win, weak detachedState, weak chatProvider] in
            guard let self, let win, let state = detachedState, let provider = chatProvider else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Select a project directory"
            panel.prompt = "Select"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let newPath = url.path

            // Store workspace on per-window state (not the shared provider)
            state.workspaceDirectory = newPath

            // Discover project CLAUDE.md for this window's workspace
            Task {
                let projConfig = await ChatProvider.discoverProjectConfig(workspace: newPath)
                await MainActor.run {
                    state.projectClaudeMdContent = projConfig.claudeMdContent
                    state.projectClaudeMdPath = projConfig.claudeMdPath
                    state.projectDiscoveredSkills = projConfig.skills
                }
            }

            let id = ObjectIdentifier(win)
            state.chatHistory = []
            state.displayedQuery = ""
            state.currentAIMessage = nil
            state.isAILoading = false
            state.aiInputText = ""
            state.suggestedReplies = []
            state.suggestedReplyQuestion = ""
            state.clearQueue()
            let oldKey = self.entries[id]?.sessionKey
            let newKey = "detached-\(UUID().uuidString)"
            self.entries[id]?.sessionKey = newKey
            win.sessionKey = newKey
            self.saveWindowRegistry()
            Task { @MainActor in
                if let oldKey {
                    await provider.resetSession(key: oldKey)
                }
            }
        }

        win.onWindowClose = { [weak self, weak win] in
            guard let self, let win else { return }
            let id = ObjectIdentifier(win)
            let sessionKey = self.entries[id]?.sessionKey ?? "unknown"
            // Clean up per-session tool executor callbacks to prevent stale references
            ChatToolExecutor.unregisterCallbacks(sessionKey: sessionKey)
            self.entries[id]?.chatCancellable?.cancel()
            self.entries[id]?.sharedProviderCancellables.forEach { $0.cancel() }
            self.entries[id]?.dequeueCancellable?.cancel()
            self.entries.removeValue(forKey: id)
            if self.isTerminating {
                log("DetachedChatWindowController: Window closed during termination (\(sessionKey)), registry preserved")
            } else if self.entries.isEmpty {
                self.clearWindowRegistry()
                log("DetachedChatWindowController: Last window closed (\(sessionKey)), registry cleared")
            } else {
                self.saveWindowRegistry()
                log("DetachedChatWindowController: Window closed (\(sessionKey)), \(self.entries.count) remaining")
            }
        }
    }

    /// Send a follow-up query from a specific detached window.
    private func sendQuery(_ message: String, attachments: [ChatAttachment] = [], for win: DetachedChatWindow) {
        let winId = ObjectIdentifier(win)
        guard let sessionKey = entries[winId]?.sessionKey else { return }
        let state = win.state
        let provider = FloatingControlBarManager.shared.chatProvider
        guard let provider else { return }

        if provider.isSending(sessionKey: sessionKey) {
            log("[DetachedChat] sendQuery: enqueuing (this session busy) session=\(sessionKey) text='\(message.prefix(40))'")
            provider.enqueueMessage(message, sessionKey: sessionKey)
            // Cancel the old response subscription immediately so it doesn't keep
            // re-setting currentAIMessage to the previous (completed) response while
            // the follow-up is queued. It gets re-established in the dequeue handler below.
            entries[winId]?.chatCancellable?.cancel()
            entries[winId]?.chatCancellable = nil
            // Listen for when this message is dequeued so we can set up the response subscriber
            entries[winId]?.dequeueCancellable?.cancel()
            entries[winId]?.dequeueCancellable = NotificationCenter.default
                .publisher(for: .chatProviderDidDequeue)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak state, weak win] notification in
                    guard let self, let state, let win else { return }
                    let id = ObjectIdentifier(win)
                    // Only react to dequeue events for this window's session
                    let dequeuedSessionKey = notification.userInfo?["sessionKey"] as? String
                    guard dequeuedSessionKey == self.entries[id]?.sessionKey else { return }
                    // Archive the current exchange before the new query replaces it
                    let currentQuery = state.displayedQuery
                    var aiMessage = state.currentAIMessage
                    if aiMessage == nil,
                       let currentKey = self.entries[id]?.sessionKey,
                       let latestAI = provider.messages.last(where: { $0.sender == .ai && $0.sessionKey == currentKey }),
                       !latestAI.text.isEmpty {
                        aiMessage = latestAI
                    }
                    let dequeuedText = notification.userInfo?["text"] as? String
                    // Skip archiving if onSendNow already set displayedQuery to this
                    // message. Otherwise a race with the $messages subscriber causes
                    // the same exchange to be archived twice (duplicate bubble).
                    if currentQuery != dequeuedText, !currentQuery.isEmpty {
                        var resolved = aiMessage ?? ChatMessage(
                            id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                            isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
                        )
                        resolved.contentBlocks = resolved.contentBlocks.map { block in
                            if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                                return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                            }
                            return block
                        }
                        state.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: resolved))
                    }
                    state.flushPendingChatObserverExchanges()
                    if let text = dequeuedText {
                        state.displayedQuery = text
                    }
                    state.isAILoading = true
                    state.currentAIMessage = nil
                    state.showUpgradeClaudeButton = false
                    // Set up the response subscriber now that our message is being sent
                    let countBefore = provider.messages.count
                    self.subscribeToResponse(provider: provider, state: state, winId: id, messageCountBefore: countBefore)
                    // One-shot: cancel after first dequeue
                    self.entries[id]?.dequeueCancellable?.cancel()
                    self.entries[id]?.dequeueCancellable = nil
                }
            return
        }

        startQuery(message: message, attachments: attachments, for: win, winId: winId, sessionKey: sessionKey, state: state, provider: provider)
    }

    /// Start sending a query immediately (provider is not busy).
    private func startQuery(message: String, attachments: [ChatAttachment] = [], for win: DetachedChatWindow, winId: ObjectIdentifier, sessionKey: String, state: FloatingControlBarState, provider: ChatProvider) {
        let messageCountBefore = provider.messages.count
        log("[DetachedChat] startQuery: messageCountBefore=\(messageCountBefore) session=\(sessionKey) chatHistory=\(state.chatHistory.count)")

        // Shared pre-query setup: suggested replies, callbacks, analytics, referral
        ChatQueryLifecycle.prepareForQuery(
            state: state,
            message: message,
            hasScreenshot: false,
            sendFollowUp: { [weak self, weak win] message in
                guard let self, let win else { return }
                Task { @MainActor in
                    log("Auto-sending follow-up (detached): \(message)")
                    self.sendQuery(message, for: win)
                }
            },
            sessionKey: sessionKey
        )

        subscribeToResponse(provider: provider, state: state, winId: winId, messageCountBefore: messageCountBefore)

        let windowCwd = state.workspaceDirectory.isEmpty ? nil : state.workspaceDirectory
        Task { @MainActor in
            let bridgeAttachments: [[String: String]]? = attachments.isEmpty ? nil : attachments.map { $0.bridgeDict }
            await provider.sendMessage(
                message,
                model: state.selectedModel,
                systemPromptSuffix: nil,
                systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent,
                sessionKey: sessionKey,
                cwd: windowCwd,
                attachments: bridgeAttachments
            )

            // Cancel the streaming subscription before post-query handling so the
            // Combine sink can't overwrite error text appended by handlePostQuery.
            log("[DetachedChat] cancelling response subscription before handlePostQuery session=\(sessionKey)")
            self.entries[winId]?.chatCancellable?.cancel()
            self.entries[winId]?.chatCancellable = nil

            // Shared post-query: error handling, credit exhaustion, auth, paywall, etc.
            ChatQueryLifecycle.handlePostQuery(provider: provider, state: state, sessionKey: sessionKey, messageCountBefore: messageCountBefore)
        }
    }

    /// Subscribe to ChatProvider messages for streaming response updates.
    private func subscribeToResponse(provider: ChatProvider, state: FloatingControlBarState, winId: ObjectIdentifier, messageCountBefore: Int) {
        let sessionKey = entries[winId]?.sessionKey
        log("[DetachedChat] subscribeToResponse: messageCountBefore=\(messageCountBefore) session=\(sessionKey ?? "?")")
        entries[winId]?.chatCancellable?.cancel()
        entries[winId]?.chatCancellable = provider.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state, weak provider] messages in
                guard let state else { return }
                // Filter to messages belonging to this detached window's session
                let currentKey = self?.entries[winId]?.sessionKey ?? sessionKey
                guard messages.count > messageCountBefore else { return }
                // Only examine messages added since this subscription was created.
                // Searching ALL messages would cause the prior AI response to be re-set
                // as currentAIMessage when a user follow-up message is added (which
                // increments messages.count) before the new AI response has arrived,
                // producing a duplicate bubble in the pop-out window.
                let newMessages = messages[messageCountBefore...]
                guard let aiMessage = newMessages.last(where: { $0.sender == .ai && $0.sessionKey == currentKey }) else {
                    let dump = newMessages.enumerated().map { i, m in
                        "[\(messageCountBefore + i):\(m.sender) key=\(m.sessionKey ?? "nil") text=\(m.text.prefix(20))]"
                    }.joined(separator: " ")
                    log("[DetachedChat] subscribeToResponse: \(messages.count - messageCountBefore) new message(s) but no new AI with session=\(currentKey ?? "?") — \(dump)")
                    return
                }
                log("[DetachedChat] subscribeToResponse: new AI message id=\(aiMessage.id) streaming=\(aiMessage.isStreaming) session=\(currentKey ?? "?")")
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
                    // Ensure the response is visible even if we never saw isStreaming=true
                    // (e.g., response completed before the Combine sink fired).
                    if !state.showingAIResponse {
                        log("[DetachedChat] setting showingAIResponse=true for non-streaming message id=\(aiMessage.id)")
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            state.showingAIResponse = true
                        }
                    }
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
        clearWindowRegistry()
    }
}
