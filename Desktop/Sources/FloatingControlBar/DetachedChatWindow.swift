import Cocoa
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted whenever a detached chat window is opened or closed, so observers
    /// (e.g. the Conversations tab badge) can refresh their open-window count.
    static let detachedChatWindowsDidChange = Notification.Name("detachedChatWindowsDidChange")
}

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
    var onFork: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onCodexLogin: (() -> Void)?
    var onChatObserverCardAction: ((Int64, String) -> Void)?
    /// Workspace selection callback. Pass `nil` to open the directory picker
    /// (NSOpenPanel). Pass a path to switch directly to that workspace.
    var onChangeWorkspace: ((String?) -> Void)?
    /// Edit a previous user message and resubmit (truncates conversation here).
    var onEditMessage: ((_ exchangeId: String, _ newText: String) -> Void)?
    var onWindowClose: (() -> Void)?

    init(state: FloatingControlBarState, sessionKey: String, savedFrame: NSRect? = nil) {
        self.state = state
        self.sessionKey = sessionKey

        // Always init with the default content size. When restoring a saved frame,
        // we apply it via setFrame(_:display:) below — that method takes a full
        // window frame (content + titlebar), so we must NOT use savedFrame.size as
        // the contentRect here (doing so adds the titlebar height a second time,
        // making the window grow by ~28pt on every restart).
        let contentRect = NSRect(origin: .zero, size: DetachedChatWindow.defaultSize)

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Put the first prompt in the actual macOS title bar
        let firstPrompt = state.streaming.chatHistory.first?.question ?? state.streaming.displayedQuery
        self.title = firstPrompt.isEmpty ? "Fazm Chat" : firstPrompt
        self.minSize = NSSize(width: 360, height: 300)
        self.isReleasedWhenClosed = false
        self.delegate = self
        self.titlebarAppearsTransparent = false
        self.titleVisibility = .visible
        self.backgroundColor = NSColor(FazmColors.backgroundPrimary)
        self.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing

        // Restore saved frame (full window frame including titlebar) directly.
        // setFrame(_:display:) expects the full frame, so the saved height is used as-is.
        if let saved = savedFrame {
            let onScreen = NSScreen.screens.contains {
                $0.visibleFrame.contains(NSPoint(x: saved.origin.x + 50, y: saved.origin.y + 50))
            }
            if onScreen {
                setFrame(saved, display: false)
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
            onFork: { [weak self] in self?.onFork?() },
            onEnqueueMessage: { [weak self] msg in self?.onEnqueueMessage?(msg) },
            onSendNowQueued: { [weak self] item in self?.onSendNowQueued?(item) },
            onDeleteQueued: { [weak self] item in self?.onDeleteQueued?(item) },
            onClearQueue: { [weak self] in self?.onClearQueue?() },
            onReorderQueue: { [weak self] src, dst in self?.onReorderQueue?(src, dst) },
            onStopAgent: { [weak self] in self?.onStopAgent?() },
            onConnectClaude: { [weak self] in self?.onConnectClaude?() },
            onCodexLogin: { [weak self] in self?.onCodexLogin?() },
            onChatObserverCardAction: { [weak self] id, action in self?.onChatObserverCardAction?(id, action) },
            onChangeWorkspace: onChangeWorkspace != nil ? { [weak self] path in self?.onChangeWorkspace?(path) } : nil,
            onEditMessage: { [weak self] messageId, newText in self?.onEditMessage?(messageId, newText) }
        )
        .environmentObject(state)
        .environmentObject(state.streaming)
        .environmentObject(state.input)
        .environmentObject(state.voice)
        .environmentObject(state.workspace)
        .environmentObject(state.tutorial)

        let hosting = NSHostingView(rootView: AnyView(
            chatView
                .withFontScaling()
                .trackWindowVisibility()
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
    @EnvironmentObject var streaming: StreamingResponseState
    @EnvironmentObject var input: InputState
    @EnvironmentObject var voice: VoiceState
    @EnvironmentObject var workspace: WorkspaceSettingsState

    var onSendFollowUp: (String, [ChatAttachment]) -> Void
    var onNewChat: () -> Void
    var onFork: (() -> Void)?
    var onEnqueueMessage: (String) -> Void
    var onSendNowQueued: (QueuedMessage) -> Void
    var onDeleteQueued: (QueuedMessage) -> Void
    var onClearQueue: () -> Void
    var onReorderQueue: (IndexSet, Int) -> Void
    var onStopAgent: () -> Void
    var onConnectClaude: () -> Void
    var onCodexLogin: (() -> Void)?
    var onChatObserverCardAction: (Int64, String) -> Void
    var onChangeWorkspace: ((String?) -> Void)?
    /// Edit a previous user message and resubmit (truncates conversation here).
    var onEditMessage: ((_ exchangeId: String, _ newText: String) -> Void)?

    var body: some View {
        AIResponseView(
            isLoading: Binding(
                get: { streaming.isAILoading },
                set: { streaming.isAILoading = $0 }
            ),
            currentMessage: streaming.currentAIMessage,
            userInput: streaming.displayedQuery,
            chatHistory: streaming.chatHistory,
            isVoiceFollowUp: Binding(
                get: { voice.isVoiceFollowUp },
                set: { voice.isVoiceFollowUp = $0 }
            ),
            voiceFollowUpTranscript: Binding(
                get: { voice.voiceFollowUpTranscript },
                set: { voice.voiceFollowUpTranscript = $0 }
            ),
            suggestedReplies: Binding(
                get: { streaming.suggestedReplies },
                set: { streaming.suggestedReplies = $0 }
            ),
            suggestedReplyQuestion: Binding(
                get: { streaming.suggestedReplyQuestion },
                set: { streaming.suggestedReplyQuestion = $0 }
            ),
            localModel: Binding(
                get: { workspace.selectedModel },
                set: { workspace.selectedModel = $0 }
            ),
            onClose: nil,
            onNewChat: onNewChat,
            onFork: onFork,
            onSendFollowUp: { message, attachments in
                // Optimistic UI (archive previous exchange, set displayedQuery,
                // flip isAILoading) lives in the controller's sendQuery so it
                // only fires when the message is actually being sent. If we did
                // it here and the controller decided to queue (zombie
                // sendingSessionKeys after a bridge-side abort), displayedQuery
                // and the queue chip would both show the same text.
                streaming.suggestedReplies = []
                streaming.suggestedReplyQuestion = ""
                onSendFollowUp(message, attachments)
            },
            onEnqueueMessage: { message in
                guard input.messageQueue.count < FloatingControlBarState.maxQueueSize else { return }
                state.enqueue(message)
                onEnqueueMessage(message)
            },
            onSendNow: { item in
                state.dequeue(item.id)
                let currentQuery = streaming.displayedQuery
                if !currentQuery.isEmpty {
                    var aiMessage = streaming.currentAIMessage ?? ChatMessage(
                        id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                        isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
                    )
                    aiMessage.contentBlocks = aiMessage.contentBlocks.map { block in
                        if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                            return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                        }
                        return block
                    }
                    streaming.chatHistory.append(FloatingChatExchange(question: currentQuery, aiMessage: aiMessage))
                }
                state.flushPendingChatObserverExchanges()
                streaming.displayedQuery = item.text
                streaming.isAILoading = true
                streaming.currentAIMessage = nil
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
                input.messageQueue.move(fromOffsets: source, toOffset: dest)
                onReorderQueue(source, dest)
            },
            onStopAgent: onStopAgent,
            onConnectClaude: onConnectClaude,
            onCodexLogin: onCodexLogin,
            onChatObserverCardAction: onChatObserverCardAction,
            onChangeWorkspace: onChangeWorkspace,
            onEditMessage: onEditMessage
        )
        .overlay {
            if input.isDragOverChat {
                ChatDragOverlay()
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { input.isDragOverChat }, set: { input.isDragOverChat = $0 })) { providers in
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
                            ChatAttachmentHelper.addFiles(from: [url], to: &input.pendingAttachments)
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
                            ChatAttachmentHelper.addPastedImage(data, to: &input.pendingAttachments)
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
    struct WindowEntry {
        let window: DetachedChatWindow
        var sessionKey: String
        var chatCancellable: AnyCancellable?
        /// Per-message @Observable tracker. Drives `state.streaming.isAILoading` and the
        /// streaming-completion handler. Token deltas no longer fire
        /// `provider.$messages`, so this is the only signal for those.
        var messageObserver: MessageObserver?
        var sharedProviderCancellables: [AnyCancellable] = []
        var dequeueCancellable: AnyCancellable?
        /// Backstop timer: if the spinner has been on with no message mutations for
        /// `safetyWatchdogIntervalSeconds`, force-clear it. Guards against tool-hang
        /// cancel events that fail to propagate (e.g. bridge crash mid-cancel) or any
        /// other path that leaves `isStreaming = true` after the agent loop is dead.
        var safetyWatchdog: Task<Void, Never>?
    }

    /// Inactivity ceiling for the per-pop-out safety watchdog. The Playwright MCP
    /// tool watchdog auto-interrupts at 120s; this gives a 10s grace window for the
    /// cancel to propagate and the message to mutate (system card, isStreaming flip)
    /// before we conclude the pipeline is dead and clear the spinner ourselves.
    private static let safetyWatchdogIntervalSeconds: UInt64 = 130

    /// Read-only snapshot of open pop-out entries. Exposed so ChatProvider can route
    /// tool-hang cancel events to the right window state without exposing the mutable
    /// per-window storage. Returned as an array of value copies — the contained
    /// `window` reference is what callers need.
    func entriesSnapshot() -> [WindowEntry] {
        return Array(entries.values)
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
    /// Global observer for `chatProviderDidDequeue` — keeps detached windows in sync
    /// when a queued message is auto-chained by ChatProvider after the previous
    /// response completes. Without this, sending a follow-up while a response is
    /// streaming (which routes through `onEnqueueMessage`, never through `sendQuery`)
    /// leaves `state.streaming.displayedQuery` stuck on the previous question and the new
    /// answer ends up paired with the wrong question.
    private var globalDequeueObserver: NSObjectProtocol?

    private init() {
        globalDequeueObserver = NotificationCenter.default.addObserver(
            forName: .chatProviderDidDequeue, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleProviderDequeue(notification: notification)
            }
        }
    }

    var isShowing: Bool { entries.values.contains { $0.window.isVisible } }

    /// Number of detached chat windows currently open. Read this synchronously,
    /// or observe `Notification.Name.detachedChatWindowsDidChange` for change events.
    var openWindowCount: Int { entries.count }

    /// Apply a model id to every open detached window's per-window selection.
    /// Used after the Codex OAuth flow promotes a pending GPT pick so the visible
    /// dropdowns flip to the requested model immediately.
    func applyModelToAllWindows(_ modelId: String) {
        for entry in entries.values {
            entry.window.state.workspace.selectedModel = modelId
        }
    }

    // MARK: - Programmatic control (com.fazm.control)

    /// One-row summary of an open pop-out, serializable to JSON. Mirrors the
    /// `WindowEntry` storage but with only the fields a caller needs.
    struct PopOutSummary {
        let sessionKey: String
        let title: String
        let workspace: String
        let selectedModel: String
        let isVisible: Bool
        let isMinimized: Bool
        let isAILoading: Bool
        let chatHistoryCount: Int
        let frameX: Double
        let frameY: Double
        let frameWidth: Double
        let frameHeight: Double

        var asDictionary: [String: Any] {
            return [
                "sessionKey": sessionKey,
                "title": title,
                "workspace": workspace,
                "selectedModel": selectedModel,
                "isVisible": isVisible,
                "isMinimized": isMinimized,
                "isAILoading": isAILoading,
                "chatHistoryCount": chatHistoryCount,
                "frame": [
                    "x": frameX, "y": frameY,
                    "width": frameWidth, "height": frameHeight
                ]
            ]
        }
    }

    /// Snapshot of every open pop-out, safe to serialize and emit to /tmp.
    /// Used by the `listPopOuts` control command for external testing and
    /// regression A/B harnesses.
    func popOutsSummary() -> [PopOutSummary] {
        return entries.values.map { entry in
            let win = entry.window
            let state = win.state
            let f = win.frame
            return PopOutSummary(
                sessionKey: entry.sessionKey,
                title: win.title,
                workspace: state.workspace.workspaceDirectory,
                selectedModel: state.workspace.selectedModel,
                isVisible: win.isVisible,
                isMinimized: win.isMiniaturized,
                isAILoading: state.streaming.isAILoading,
                chatHistoryCount: state.streaming.chatHistory.count,
                frameX: f.origin.x, frameY: f.origin.y,
                frameWidth: f.size.width, frameHeight: f.size.height
            )
        }
    }

    /// Close every open detached chat window. Used by the `closeAllPopOuts`
    /// control command for automated test cleanup so the ACP bridge tears
    /// down all per-session claude subprocesses.
    /// - Returns: the number of windows actually closed.
    @discardableResult
    func closeAllWindows() -> Int {
        // Snapshot first because `entries` mutates via `windowWillClose` as we close each.
        let windowsToClose = entries.values.map { $0.window }
        for win in windowsToClose {
            win.close()
        }
        return windowsToClose.count
    }

    /// Close a single detached chat window matching the given session key.
    /// - Returns: true if a window was found and closed, false otherwise.
    @discardableResult
    func closeWindow(sessionKey: String) -> Bool {
        guard let entry = entries.values.first(where: { $0.sessionKey == sessionKey }) else {
            return false
        }
        entry.window.close()
        return true
    }

    /// Programmatically deliver a message to a specific pop-out by session key.
    /// Drives the same code path as a user typing into that pop-out's input field.
    /// Used by the `sendQueryToWindow` control command for per-session testing
    /// (e.g. measuring per-subprocess CPU under controlled load).
    /// - Returns: true if a matching pop-out was found and the query was dispatched.
    @discardableResult
    func sendQuery(toSessionKey sessionKey: String, message: String) -> Bool {
        guard let entry = entries.values.first(where: { $0.sessionKey == sessionKey }) else {
            return false
        }
        // Ensure the window is visible so its streaming UI is wired up before the message lands.
        if !entry.window.isVisible {
            entry.window.makeKeyAndOrderFront(nil)
        }
        sendQuery(message, for: entry.window)
        return true
    }

    /// Post a notification on the main queue so SwiftUI views can refresh their
    /// open-window count. Call this after every mutation of `entries`.
    private func notifyWindowsChanged() {
        NotificationCenter.default.post(name: .detachedChatWindowsDidChange, object: nil)
    }

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
                workspace: entry.window.state.workspace.workspaceDirectory,
                selectedModel: entry.window.state.workspace.selectedModel
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
        detachedState.streaming.chatHistory = chatHistory
        detachedState.streaming.displayedQuery = displayedQuery
        detachedState.streaming.currentAIMessage = currentAIMessage
        detachedState.streaming.isAILoading = isAILoading
        detachedState.streaming.showingAIConversation = true
        detachedState.streaming.showingAIResponse = true

        // Workspace: prefer inherited (from currently focused pop-out) over shared provider,
        // so Cmd+Shift+N from a per-window-workspace pop-out keeps that same workspace.
        if let source = inheritWorkspaceFrom {
            detachedState.workspace.workspaceDirectory = source.workspace.workspaceDirectory
            detachedState.workspace.projectClaudeMdContent = source.workspace.projectClaudeMdContent
            detachedState.workspace.projectClaudeMdPath = source.workspace.projectClaudeMdPath
            detachedState.workspace.projectDiscoveredSkills = source.workspace.projectDiscoveredSkills
        } else {
            detachedState.workspace.workspaceDirectory = chatProvider.aiChatWorkingDirectory
            detachedState.workspace.projectClaudeMdContent = chatProvider.projectClaudeMdContent
            detachedState.workspace.projectClaudeMdPath = chatProvider.projectClaudeMdPath
            detachedState.workspace.projectDiscoveredSkills = chatProvider.projectDiscoveredSkills
        }

        // Anchor the pop-out's cwd at creation. An empty workspaceDirectory used
        // to mean "follow the global aiChatWorkingDirectory", but that global
        // fluctuates, so the cwd sent to the ACP bridge flapped between turns —
        // each flap tore down the upstream session and lost conversation memory.
        // Pop-outs now get an explicit, sticky cwd from the moment they exist.
        if detachedState.workspace.workspaceDirectory.isEmpty {
            detachedState.workspace.workspaceDirectory = NSHomeDirectory()
        }

        let win = DetachedChatWindow(state: detachedState, sessionKey: sessionKey)
        let winId = ObjectIdentifier(win)

        wireUpCallbacks(win: win, detachedState: detachedState, chatProvider: chatProvider)

        win.setupViews()

        entries[winId] = WindowEntry(window: win, sessionKey: sessionKey)
        notifyWindowsChanged()
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
                        guard state.streaming.isAILoading else { return } // already handled by subscription
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
                detachedState.streaming.showingAIConversation = true
                detachedState.streaming.showingAIResponse = true
                detachedState.streaming.isAILoading = false

                // Restore per-window model selection and workspace.
                // Old snapshots (saved before per-window workspace existed) have an
                // empty workspace; resolve those to $HOME so the pop-out has an
                // explicit, sticky cwd instead of silently following the global
                // (which flaps and tears down the ACP session between turns).
                detachedState.workspace.selectedModel = snapshot.selectedModel
                let restoredWorkspace = snapshot.workspace.isEmpty ? NSHomeDirectory() : snapshot.workspace
                detachedState.workspace.workspaceDirectory = restoredWorkspace
                // Only discover project config for a real project dir. $HOME has no
                // project CLAUDE.md, so discovery there is wasted work.
                if !snapshot.workspace.isEmpty && snapshot.workspace != NSHomeDirectory() {
                    Task {
                        let config = await ChatProvider.discoverProjectConfig(workspace: snapshot.workspace)
                        await MainActor.run {
                            detachedState.workspace.projectClaudeMdContent = config.claudeMdContent
                            detachedState.workspace.projectClaudeMdPath = config.claudeMdPath
                            detachedState.workspace.projectDiscoveredSkills = config.skills
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

                // Re-assert workspace after the hosting view exists and provider
                // subscriptions are wired. Defends against a SwiftUI observation
                // race (assignment lands before NSHostingView subscribes) AND any
                // async resetter that might clobber per-window workspace later.
                DispatchQueue.main.async {
                    if detachedState.workspace.workspaceDirectory != restoredWorkspace {
                        log("DetachedChatWindowController: workspace drifted after setupViews — re-asserting \(restoredWorkspace) for \(sessionKey) (was '\(detachedState.workspace.workspaceDirectory)')")
                        detachedState.workspace.workspaceDirectory = restoredWorkspace
                    }
                }

                self.notifyWindowsChanged()
                restoredCount += 1
                log("DetachedChatWindowController: Restored window for \(sessionKey) workspace=\(restoredWorkspace) with \(savedMessages.count) messages")
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
                        workspace: entry.window.state.workspace.workspaceDirectory,
                        selectedModel: entry.window.state.workspace.selectedModel
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
            state.streaming.chatHistory = []
            state.streaming.displayedQuery = ""
            state.streaming.currentAIMessage = nil
            state.streaming.isAILoading = false
            state.input.aiInputText = ""
            state.streaming.suggestedReplies = []
            state.streaming.suggestedReplyQuestion = ""
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

        // Fork: branch the current detached session into a NEW pop-out window.
        // The source pop-out stays exactly as it is (still bound to its
        // sessionKey, conversation still rendered). A new detached window is
        // opened bound to a fresh sessionKey, with the source's chat history
        // copied in so the user can see the prior context that was forked
        // from. The bridge fork registers the new branch under the new key
        // while leaving the source key live.
        win.onFork = { [weak win, weak detachedState, weak chatProvider] in
            guard let win, let state = detachedState, let provider = chatProvider else { return }

            let sourceKey = win.sessionKey
            let newKey = "detached-\(UUID().uuidString)"

            // Snapshot the source pop-out's visible state for the new window.
            let chatHistory = state.streaming.chatHistory
            let displayedQuery = state.streaming.displayedQuery
            let currentAIMessage = state.streaming.currentAIMessage
            // In-flight messages belong to the source session; the new
            // window starts idle.
            let isAILoading = false
            let messageCountBefore = provider.messages.count
            let inheritState = state

            Task { @MainActor in
                await provider.forkSession(fromKey: sourceKey, toKey: newKey)

                DetachedChatWindowController.shared.show(
                    chatHistory: chatHistory,
                    displayedQuery: displayedQuery,
                    currentAIMessage: currentAIMessage,
                    isAILoading: isAILoading,
                    chatProvider: provider,
                    messageCountBefore: messageCountBefore,
                    sessionKey: newKey,
                    inheritWorkspaceFrom: inheritState
                )
            }
        }

        win.onEnqueueMessage = { [weak self, weak win, weak chatProvider] message in
            guard let win else { return }
            let key = self?.entries[ObjectIdentifier(win)]?.sessionKey
            // Capture per-window context so the dequeue path doesn't fall
            // back to the global aiChatWorkingDirectory / selectedModel and
            // tear down the bridge's ACP session on cwd change. See
            // ChatProvider.QueuedChatMessage doc.
            let cwd = win.state.workspace.workspaceDirectory.isEmpty ? nil : win.state.workspace.workspaceDirectory
            chatProvider?.enqueueMessage(
                message,
                sessionKey: key,
                cwd: cwd,
                model: win.state.workspace.selectedModel,
                systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent
            )
        }

        win.onSendNowQueued = { [weak self, weak win, weak chatProvider] item in
            guard let provider = chatProvider, let win else { return }
            // Scope to THIS pop-out's session so the message lands in the right
            // window. Without this, ChatProvider falls back to activeSessionKey
            // (whichever session last started a query) — when two pop-outs are
            // both streaming, the message ends up in the wrong window and the
            // bare interrupt() call cancels both responses instead of just one.
            let key = self?.entries[ObjectIdentifier(win)]?.sessionKey
            let cwd = win.state.workspace.workspaceDirectory.isEmpty ? nil : win.state.workspace.workspaceDirectory
            let model = win.state.workspace.selectedModel
            Task { @MainActor in
                await provider.interruptAndSend(
                    item.text,
                    sessionKey: key,
                    cwd: cwd,
                    model: model,
                    systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent
                )
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
            // Eagerly clear loading state AND flip the streaming message off so the
            // UI feels responsive. The spinner is driven by `isLoading || message.isStreaming`
            // (AIResponseView.swift:820), so we have to clear both — clearing only
            // isAILoading leaves the spinner visible while the in-progress AI message
            // still has isStreaming=true. Without this, if the bridge cancellation
            // result is dropped or delayed, the spinner spins for the full 180s
            // inactivity timeout. Bridge cleanup still runs async; any partial
            // response that arrives later is handled by the existing $messages
            // subscriber and merely overwrites our eager clear.
            win.state.streaming.isAILoading = false
            if win.state.streaming.currentAIMessage?.isStreaming == true {
                win.state.streaming.currentAIMessage?.isStreaming = false
            }
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

        win.onCodexLogin = { [weak chatProvider] in
            chatProvider?.startCodexLogin()
        }

        win.onChatObserverCardAction = { [weak chatProvider] activityId, action in
            chatProvider?.handleChatObserverCardAction(activityId: activityId, action: action)
        }

        win.onEditMessage = { [weak self, weak win, weak chatProvider] exchangeId, newText in
            guard let self, let win, let provider = chatProvider else { return }
            let key = self.entries[ObjectIdentifier(win)]?.sessionKey ?? win.sessionKey
            Task { @MainActor in
                let ok = await provider.truncateForEdit(exchangeId: exchangeId, sessionKey: key)
                guard ok else { return }
                self.sendQuery(newText, for: win)
            }
        }

        win.onChangeWorkspace = { [weak self, weak win, weak detachedState, weak chatProvider] requestedPath in
            guard let self, let win, let state = detachedState, let provider = chatProvider else { return }

            // Resolve the destination path. nil → open NSOpenPanel; non-nil →
            // jump directly to the chosen recent workspace (no intermediate UI).
            let newPath: String
            if let requestedPath, !requestedPath.isEmpty {
                newPath = requestedPath
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.message = "Select a project directory"
                panel.prompt = "Select"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                newPath = url.path
            }

            // No-op if the user picked the workspace we're already on.
            guard newPath != state.workspace.workspaceDirectory else { return }

            // Store workspace on per-window state (not the shared provider)
            state.workspace.workspaceDirectory = newPath
            RecentWorkspaces.add(newPath)

            // Discover project CLAUDE.md for this window's workspace
            Task {
                let projConfig = await ChatProvider.discoverProjectConfig(workspace: newPath)
                await MainActor.run {
                    state.workspace.projectClaudeMdContent = projConfig.claudeMdContent
                    state.workspace.projectClaudeMdPath = projConfig.claudeMdPath
                    state.workspace.projectDiscoveredSkills = projConfig.skills
                }
            }

            let id = ObjectIdentifier(win)
            state.streaming.chatHistory = []
            state.streaming.displayedQuery = ""
            state.streaming.currentAIMessage = nil
            state.streaming.isAILoading = false
            state.input.aiInputText = ""
            state.streaming.suggestedReplies = []
            state.streaming.suggestedReplyQuestion = ""
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
            // Interrupt any in-flight ACP query so the bridge doesn't hang for 600s
            // and fire a stray chat_agent_error after the window is gone.
            if let provider = FloatingControlBarManager.shared.chatProvider,
               provider.isSending(sessionKey: sessionKey) {
                provider.stopAgent(sessionKey: sessionKey)
            }
            // Tear the session down in the bridge so its claude subprocess
            // dies (otherwise the warm session leaks ~25-30% CPU per pop-out
            // forever — root cause of the 2026-05-14 CPU regression). Skipped
            // during app termination because the bridge is shutting down on
            // its own and the session_close request would race with bridge exit.
            if !self.isTerminating, sessionKey != "unknown",
               let provider = FloatingControlBarManager.shared.chatProvider {
                provider.endSession(sessionKey: sessionKey)
            }
            // Drop this pop-out's persisted ACP session IDs so user-closed
            // windows don't leave dead `acpSessionId_detached-*` keys in
            // UserDefaults forever. Skipped during termination — windows closed
            // on quit are restored from the registry and still need their
            // resume session IDs.
            if !self.isTerminating, sessionKey != "unknown" {
                ChatProvider.purgeDetachedSession(sessionKey: sessionKey)
            }
            // Clean up per-session tool executor callbacks to prevent stale references
            ChatToolExecutor.unregisterCallbacks(sessionKey: sessionKey)
            self.entries[id]?.chatCancellable?.cancel()
            self.entries[id]?.messageObserver?.cancel()
            self.entries[id]?.safetyWatchdog?.cancel()
            self.entries[id]?.sharedProviderCancellables.forEach { $0.cancel() }
            self.entries[id]?.dequeueCancellable?.cancel()
            self.entries.removeValue(forKey: id)
            self.notifyWindowsChanged()
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
            // Mirror the message into the visible UI queue. Without this, the
            // functional queue holds it but no chip renders, so the user thinks
            // their submit was dropped.
            state.enqueue(message)
            // Capture per-window context so the dequeue path doesn't fall back
            // to globals (see ChatProvider.QueuedChatMessage doc + bug fix
            // 2026-05-15: pop-out sessions were torn down on cwd flap because
            // the queue stripped per-call cwd).
            let queuedCwd = state.workspace.workspaceDirectory.isEmpty ? nil : state.workspace.workspaceDirectory
            provider.enqueueMessage(
                message,
                sessionKey: sessionKey,
                cwd: queuedCwd,
                model: state.workspace.selectedModel,
                systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent
            )
            // Cancel the old response subscription immediately so it doesn't keep
            // re-setting currentAIMessage to the previous (completed) response while
            // the follow-up is queued. It gets re-established in the dequeue handler below.
            entries[winId]?.chatCancellable?.cancel()
            entries[winId]?.chatCancellable = nil
            entries[winId]?.messageObserver?.cancel()
            entries[winId]?.messageObserver = nil
            entries[winId]?.safetyWatchdog?.cancel()
            entries[winId]?.safetyWatchdog = nil
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
                    let currentQuery = state.streaming.displayedQuery
                    var aiMessage = state.streaming.currentAIMessage
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
                        state.streaming.chatHistory.append(FloatingChatExchange(
                            question: currentQuery,
                            aiMessage: resolved,
                            userMessageCreatedAt: provider.mostRecentUserMessageCreatedAt(text: currentQuery, scope: sessionKey)
                        ))
                    }
                    state.flushPendingChatObserverExchanges()
                    if let text = dequeuedText {
                        state.streaming.displayedQuery = text
                    }
                    state.streaming.isAILoading = true
                    state.streaming.currentAIMessage = nil
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

        // Not-busy path: apply optimistic UI here (moved out of the SwiftUI
        // wrapper) so the busy branch above doesn't double-render the message
        // as both displayedQuery and a queue chip.
        let currentQuery = state.streaming.displayedQuery
        if !currentQuery.isEmpty {
            let aiMessage = state.streaming.currentAIMessage ?? ChatMessage(
                id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
            )
            log("[DetachedChat] sendQuery: archiving exchange question='\(currentQuery.prefix(40))' aiMessage.id=\(aiMessage.id) historyCount=\(state.streaming.chatHistory.count)")
            state.streaming.chatHistory.append(FloatingChatExchange(
                question: currentQuery,
                aiMessage: aiMessage,
                userMessageCreatedAt: provider.mostRecentUserMessageCreatedAt(text: currentQuery, scope: sessionKey)
            ))
        }
        state.flushPendingChatObserverExchanges()
        state.streaming.displayedQuery = message
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.streaming.isAILoading = true
            state.streaming.currentAIMessage = nil
        }

        startQuery(message: message, attachments: attachments, for: win, winId: winId, sessionKey: sessionKey, state: state, provider: provider)
    }

    /// Start sending a query immediately (provider is not busy).
    private func startQuery(message: String, attachments: [ChatAttachment] = [], for win: DetachedChatWindow, winId: ObjectIdentifier, sessionKey: String, state: FloatingControlBarState, provider: ChatProvider) {
        let messageCountBefore = provider.messages.count
        log("[DetachedChat] startQuery: messageCountBefore=\(messageCountBefore) session=\(sessionKey) chatHistory=\(state.streaming.chatHistory.count)")

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

        let windowCwd = state.workspace.workspaceDirectory.isEmpty ? nil : state.workspace.workspaceDirectory
        Task { @MainActor in
            let bridgeAttachments: [[String: String]]? = attachments.isEmpty ? nil : attachments.map { $0.bridgeDict }
            await provider.sendMessage(
                message,
                model: state.workspace.selectedModel,
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
            self.entries[winId]?.messageObserver?.cancel()
            self.entries[winId]?.messageObserver = nil
            self.entries[winId]?.safetyWatchdog?.cancel()
            self.entries[winId]?.safetyWatchdog = nil

            // Shared post-query: error handling, credit exhaustion, auth, paywall, etc.
            ChatQueryLifecycle.handlePostQuery(provider: provider, state: state, sessionKey: sessionKey, messageCountBefore: messageCountBefore)
        }
    }

    /// Subscribe to ChatProvider messages for streaming response updates.
    ///
    /// Pre-filter pipeline: extract only the latest AI message for THIS window's
    /// session (returns nil for unrelated changes), then dedupe so we don't
    /// re-fire on every text mutation if nothing relevant changed.
    ///
    /// This kills the N×M render storm when many detached windows are open and
    /// one session is streaming. Without it, every streaming token in any
    /// session caused all open detached windows to hop onto main, scan the
    /// messages array, log, and return — producing 6× fan-out per token in
    /// production logs and freezing hover/copy-button UI on the main thread.
    private func subscribeToResponse(provider: ChatProvider, state: FloatingControlBarState, winId: ObjectIdentifier, messageCountBefore: Int) {
        let initialKey = entries[winId]?.sessionKey
        log("[DetachedChat] subscribeToResponse: messageCountBefore=\(messageCountBefore) session=\(initialKey ?? "?")")
        entries[winId]?.chatCancellable?.cancel()
        entries[winId]?.messageObserver?.cancel()
        entries[winId]?.messageObserver = nil
        entries[winId]?.safetyWatchdog?.cancel()
        entries[winId]?.safetyWatchdog = nil
        // Build the chain into a local first; assigning directly into
        // entries[winId]?.chatCancellable holds an exclusive (_modify) access on
        // `entries` while the RHS evaluates. `.sink` subscribes synchronously and
        // @Published delivers its current value to the new subscriber immediately,
        // firing `.compactMap` — which then re-reads `entries[winId]?.sessionKey`
        // and trips Swift's exclusivity check (crash: swift_beginAccess / SIGABRT).
        let cancellable = provider.$messages
            // Filter BEFORE the main-queue hop so unrelated streaming events
            // never reach `.sink`. With ChatMessage as a reference type the
            // array publisher only fires on add/remove (element refs unchanged
            // by token writes), so this sink fires once per new AI message
            // rather than once per token. Per-token granular updates flow via
            // MessageObserver below, which uses @Observable tracking.
            .compactMap { [weak self] messages -> ChatMessage? in
                let currentKey = self?.entries[winId]?.sessionKey ?? initialKey
                guard messages.count > messageCountBefore else { return nil }
                // Only examine messages added since this subscription was created.
                // Searching ALL messages would cause the prior AI response to be
                // re-set as currentAIMessage when a user follow-up message is
                // added (which increments messages.count) before the new AI
                // response has arrived, producing a duplicate bubble.
                let newMessages = messages[messageCountBefore...]
                return newMessages.last(where: { $0.sender == .ai && $0.sessionKey == currentKey })
            }
            // ChatMessage Equatable is identity-based, so this drops re-emissions
            // of the same instance (no spurious double-fires when an unrelated
            // message is appended). Genuinely new message instances pass through.
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state, weak provider] aiMessage in
                guard let state, let self else { return }
                let currentKey = self.entries[winId]?.sessionKey ?? initialKey
                log("[DetachedChat] subscribeToResponse: new AI message id=\(aiMessage.id) streaming=\(aiMessage.isStreaming) session=\(currentKey ?? "?")")
                state.streaming.currentAIMessage = aiMessage
                // Reveal the response surface on first arrival. Subsequent
                // mutations to the same message instance flow via MessageObserver.
                if !state.streaming.showingAIResponse {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        state.streaming.showingAIResponse = true
                    }
                }
                // Tear down any previous observer (covers re-subscription).
                self.entries[winId]?.messageObserver?.cancel()
                // Track this message's mutable fields. The closure fires once
                // immediately to sync `isAILoading` with the current state, then
                // re-fires whenever the message mutates (token append, tool
                // block append, isStreaming flip). It's the per-token signal
                // for the controller; SwiftUI views that read `aiMessage.text`
                // already get their own per-property invalidations from
                // @Observable and don't need this.
                let observer = MessageObserver(message: aiMessage) { [weak self, weak state, weak provider] msg in
                    guard let state else { return }
                    // OR with sendingSessionKeys so the indicator stays on during
                    // the gap between agent turns (tool result roundtrips), where
                    // msg.isStreaming briefly looks false but the query is still
                    // live in ChatProvider. See pop-out "ball-on-AI" regression.
                    let key = self?.entries[winId]?.sessionKey ?? currentKey
                    let isSessionSending = key.flatMap { provider?.isSending(sessionKey: $0) } ?? false
                    let newLoading = msg.isStreaming || isSessionSending
                    if state.streaming.isAILoading != newLoading {
                        state.streaming.isAILoading = newLoading
                    }
                    // Safety watchdog: any mutation while streaming resets the
                    // inactivity timer. When isStreaming flips false (normal
                    // completion or forced-cancel from ChatProvider), cancel it.
                    self?.scheduleSafetyWatchdog(winId: winId, isStreaming: msg.isStreaming, messageId: msg.id)
                    if !msg.isStreaming {
                        // Ensure the response is visible even if we never saw
                        // isStreaming=true (e.g., response completed before this
                        // observer landed).
                        if !state.streaming.showingAIResponse {
                            log("[DetachedChat] setting showingAIResponse=true for non-streaming message id=\(msg.id)")
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                state.streaming.showingAIResponse = true
                            }
                        }
                        // Clear stale messages from provider now that streaming
                        // is done. These were kept alive during pop-out so the
                        // in-flight query could continue writing; the floating
                        // bar doesn't need them anymore.
                        provider?.clearTransferredMessages()
                    }
                }
                self.entries[winId]?.messageObserver = observer
            }
        entries[winId]?.chatCancellable = cancellable

        // Independent subscription on sendingSessionKeys. MessageObserver only
        // fires on message mutations, so a session-state flip with no message
        // mutation (e.g. final completion when isStreaming was already false)
        // would leave isAILoading stale. This sink recomputes the flag whenever
        // the set changes.
        let sendingSub = provider.$sendingSessionKeys
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak state] keys in
                guard let self, let state else { return }
                let key = self.entries[winId]?.sessionKey ?? initialKey
                let isSessionSending = key.map { keys.contains($0) } ?? false
                let msgStreaming = state.streaming.currentAIMessage?.isStreaming ?? false
                let newLoading = msgStreaming || isSessionSending
                if state.streaming.isAILoading != newLoading {
                    state.streaming.isAILoading = newLoading
                }
            }
        entries[winId]?.sharedProviderCancellables.append(sendingSub)
    }

    /// Reset the per-window safety watchdog.
    ///
    /// Disabled May 12 2026: the 130s timer interrupted healthy streams when
    /// the bridge had been quiet for natural reasons (long tool calls, session
    /// resumes), force-clearing the spinner and firing a bridge interrupt that
    /// killed in-flight queries. Re-enable by restoring the timer body.
    fileprivate func scheduleSafetyWatchdog(winId: ObjectIdentifier, isStreaming: Bool, messageId: String) {
        entries[winId]?.safetyWatchdog?.cancel()
        entries[winId]?.safetyWatchdog = nil
        _ = isStreaming
        _ = messageId
    }

    /// Handle `chatProviderDidDequeue` for any detached session.
    ///
    /// When the user enqueues a follow-up while the previous response is streaming,
    /// `AIResponseView.sendFollowUp` routes the message through `onEnqueueMessage`
    /// (not through `sendQuery`'s busy path), so no per-window dequeue listener gets
    /// installed. This global handler picks up the chain notification, finds the
    /// matching detached window, archives the previous exchange, and rewires the
    /// streaming subscription so the new answer pairs with the new question.
    private func handleProviderDequeue(notification: Notification) {
        guard let dequeuedSessionKey = notification.userInfo?["sessionKey"] as? String,
              dequeuedSessionKey.hasPrefix("detached-"),
              let dequeuedText = notification.userInfo?["text"] as? String else { return }
        guard let (winId, entry) = entries.first(where: { $0.value.sessionKey == dequeuedSessionKey }) else { return }
        guard let provider = FloatingControlBarManager.shared.chatProvider else { return }
        let state = entry.window.state

        log("[DetachedChat] global dequeue: session=\(dequeuedSessionKey) text='\(dequeuedText.prefix(40))' historyCount=\(state.streaming.chatHistory.count) queue=\(state.input.messageQueue.count)")

        // Drop the matching item from the per-window queue UI.
        if let idx = state.input.messageQueue.firstIndex(where: { $0.text == dequeuedText }) {
            state.input.messageQueue.remove(at: idx)
        }

        // Archive the previous exchange. If the per-window dequeue listener (busy
        // path of sendQuery) already ran first, displayedQuery will already match
        // and we skip the archive — same guard as that listener.
        let currentQuery = state.streaming.displayedQuery
        var aiMessage = state.streaming.currentAIMessage
        if aiMessage == nil,
           let latestAI = provider.messages.last(where: { $0.sender == .ai && $0.sessionKey == dequeuedSessionKey }),
           !latestAI.text.isEmpty {
            aiMessage = latestAI
        }
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
            state.streaming.chatHistory.append(FloatingChatExchange(
                question: currentQuery,
                aiMessage: resolved,
                userMessageCreatedAt: provider.mostRecentUserMessageCreatedAt(text: currentQuery, scope: dequeuedSessionKey)
            ))
        }
        state.flushPendingChatObserverExchanges()
        state.streaming.displayedQuery = dequeuedText
        state.streaming.isAILoading = true
        state.streaming.currentAIMessage = nil
        state.showUpgradeClaudeButton = false

        // Re-anchor streaming for the chained query. Capture countBefore now,
        // before ChatProvider.sendMessage (which is awaited on the same main-actor
        // task that posted this notification synchronously) appends the new
        // user/AI placeholder. The subscriber will then see them when @Published fires.
        let countBefore = provider.messages.count
        subscribeToResponse(provider: provider, state: state, winId: winId, messageCountBefore: countBefore)
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
