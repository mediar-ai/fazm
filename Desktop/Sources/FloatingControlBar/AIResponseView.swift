import SwiftUI

/// Persisted list of recently-used workspace directory paths (max 5, MRU order).
enum RecentWorkspaces {
    private static let key = "recentWorkspacePaths"
    private static let maxCount = 5

    static func list() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Records `path` as the most recently used workspace, deduplicating and
    /// capping the list to `maxCount`. No-op for empty paths or the home dir.
    static func add(_ path: String) {
        guard !path.isEmpty else { return }
        guard path != NSHomeDirectory() else { return }
        var current = list().filter { $0 != path }
        current.insert(path, at: 0)
        if current.count > maxCount { current = Array(current.prefix(maxCount)) }
        UserDefaults.standard.set(current, forKey: key)
    }
}

/// Streaming markdown response view for the floating control bar.
struct AIResponseView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @EnvironmentObject var streaming: StreamingResponseState
    @EnvironmentObject var input: InputState
    @EnvironmentObject var voice: VoiceState
    @EnvironmentObject var workspace: WorkspaceSettingsState
    @EnvironmentObject var tutorial: TutorialState
    @ObservedObject private var shortcutSettings = ShortcutSettings.shared
    @Environment(\.fazmWindowIsVisible) private var windowIsVisible
    @Environment(\.fontScale) private var fontScale
    @Binding var isLoading: Bool
    let currentMessage: ChatMessage?
    @State private var isQuestionExpanded = false
    @State private var isQuestionBarHovered = false
    @State private var followUpText: String = ""
    @State private var preVoiceFollowUpText: String = ""
    @State private var followUpTextHeight: CGFloat = 34
    @State private var isHanging = false
    @State private var hangTask: Task<Void, Never>?
    @State private var isStopping = false
    /// True when the hang state was triggered by a previous crash, not the 30s timer.
    /// Prevents the isLoading onChange from clearing it when a query completes.
    @State private var isHangingFromCrash = false
    @State private var shouldFollowContent = true
    @State private var isProgrammaticScroll = false
    /// Debounced version of isLoading — stays true for at least 600ms after loading ends
    /// to prevent the typing indicator from flickering during rapid API retries.
    @State private var debouncedIsLoading = false
    @State private var loadingHideTask: Task<Void, Never>? = nil

    /// Per-bubble geometry collected from chatExchangeView via PreferenceKey.
    @State private var bubbleInfos: [StackedBubbleInfo] = []
    /// Live scroll viewport bounds reported by ScrollBoundsObserver.
    @State private var scrollBounds = ScrollBoundsInfo(offsetY: 0, viewportHeight: 0)
    /// When true, the stacked past-prompts overlay is collapsed to a single show button.
    @State private var isStackHidden = false

    /// Named coordinate space for the chat content; user-bubble frames are reported here.
    static let chatScrollSpace = "fazmChatScrollContent"
    /// Visible height of one peeked bubble in the sticky stack at the top.
    /// Scales with the font setting so larger fonts don't clip inside the peek.
    private var bubblePeekHeight: CGFloat { round(22 * fontScale) }

    /// Bubbles whose top has scrolled above the current viewport, sorted oldest→newest.
    /// Capped to fit within 20% of viewport height; overflow drops the oldest (FIFO).
    private var stackedBubbles: [StackedBubbleInfo] {
        guard scrollBounds.viewportHeight > 0 else { return [] }
        let viewportTop = scrollBounds.offsetY
        let scrolledPast = bubbleInfos
            .filter { $0.height > 0 && $0.topY < viewportTop }
            .sorted { $0.topY < $1.topY }
        let peekUnit = bubblePeekHeight + 2 // matches VStack spacing in overlay
        let cap = max(2, Int((scrollBounds.viewportHeight * 0.2) / peekUnit))
        return Array(scrolledPast.suffix(cap))
    }

    private var stackedBubbleIDs: Set<UUID> {
        Set(stackedBubbles.map { $0.id })
    }

    let userInput: String
    let chatHistory: [FloatingChatExchange]
    @Binding var isVoiceFollowUp: Bool
    @Binding var voiceFollowUpTranscript: String
    @Binding var suggestedReplies: [String]
    @Binding var suggestedReplyQuestion: String

    /// Pre-filtered exchanges to avoid re-filtering in body on every render.
    private var regularExchanges: [FloatingChatExchange] {
        chatHistory.filter { !$0.question.isEmpty }
    }
    private var chatObserverOnlyExchanges: [FloatingChatExchange] {
        chatHistory.filter { $0.question.isEmpty }
    }

    /// When set, the model dropdown in this view reads/writes this binding instead of the global setting.
    /// Pass nil (the default) for the floating bar; pass the per-window binding for popout windows.
    var localModel: Binding<String>?

    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onFork: (() -> Void)?
    var onSendFollowUp: ((String, [ChatAttachment]) -> Void)?
    var onEnqueueMessage: ((String) -> Void)?
    var onSendNow: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?
    var onStopAgent: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onCodexLogin: (() -> Void)?
    var onChatObserverCardAction: ((Int64, String) -> Void)?
    /// Workspace selection callback. Pass `nil` to open the directory picker
    /// (NSOpenPanel). Pass a path to switch directly to that workspace.
    var onChangeWorkspace: ((String?) -> Void)?
    /// Edit a previous user message and resubmit. Truncates the conversation
    /// at the edited message and restarts with the new text. nil = no edit
    /// affordance shown on past bubbles.
    var onEditMessage: ((_ exchangeId: String, _ newText: String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tutorial.isTutorialChatActive {
                tutorialBanner
            }

            headerView
                .fixedSize(horizontal: false, vertical: true)

            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Previous chat exchanges — regular ones rendered individually
                            ForEach(regularExchanges) { exchange in
                                chatExchangeView(exchange)
                            }
                            // Chat observer-only exchanges consolidated into one stack
                            consolidatedHistoryChatObserverCards

                            // Current question (hidden when empty, e.g. tutorial guide messages or history-only mode)
                            if !userInput.isEmpty {
                                questionBar
                            }

                            // Current response (hidden when just showing history with no active query)
                            if !userInput.isEmpty || currentMessage != nil {
                                currentContentView
                            }

                            // Chat observer cards that arrived while the current query was streaming
                            consolidatedPendingChatObserverCards

                            // Voice follow-up indicator (shown inline when PTT is active during conversation)
                            if isVoiceFollowUp {
                                voiceFollowUpView
                                    .id("voiceFollowUp")
                            }

                            // Suggested replies live INSIDE the ScrollView so when they appear
                            // they extend the chat content downward; .defaultScrollAnchor(.bottom)
                            // smoothly keeps the bottom pinned. Rendering them outside the ScrollView
                            // would shrink the scroll viewport and make existing content visually
                            // jump up by the height of the chips.
                            if !isLoading && !suggestedReplies.isEmpty {
                                suggestedRepliesView
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                                        removal: .opacity
                                    ))
                            }

                            // Anchor for explicit scroll-to-bottom calls (new exchanges, etc.)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        // Smoothly animate the suggested-replies chip appearance.
                        // Either dependency can flip (isLoading→false at end of stream,
                        // or suggestedReplies populating); both must be in the value
                        // list so SwiftUI knows to run the transition.
                        .animation(.spring(response: 0.5, dampingFraction: 0.82),
                                   value: suggestedReplies.isEmpty)
                        .animation(.spring(response: 0.5, dampingFraction: 0.82),
                                   value: isLoading)
                        // Place detector inside the scroll content so its NSView
                        // is a descendant of NSScrollView.documentView and the
                        // superview walk finds the correct NSScrollView.
                        .background(
                            ScrollPositionDetector { atBottom in
                                if atBottom {
                                    shouldFollowContent = true
                                } else if !isProgrammaticScroll {
                                    shouldFollowContent = false
                                }
                            }
                        )
                        .background(
                            ScrollBoundsObserver { info in
                                scrollBounds = info
                            }
                        )
                        .coordinateSpace(name: Self.chatScrollSpace)
                    }
                    // Pin scroll to the bottom of content. When content grows or
                    // reflows (markdown re-layout during streaming), SwiftUI keeps
                    // the bottom edge of the content fixed to the bottom of the
                    // viewport in the same layout transaction — no scrollTo races,
                    // no scrollbar thumb jumping. If the user scrolls up manually,
                    // their offset-from-bottom stays stable, so they aren't yanked.
                    .defaultScrollAnchor(.bottom)
                    .onPreferenceChange(StackedBubblesPreferenceKey.self) { value in
                        // Dedupe by id (preferences accumulate across updates) and
                        // sort once so consumers can binary-search later if needed.
                        var byId: [UUID: StackedBubbleInfo] = [:]
                        for info in value { byId[info.id] = info }
                        bubbleInfos = byId.values.sorted { $0.topY < $1.topY }
                    }
                    .overlay(alignment: .top) {
                        StackedBubblesOverlay(
                            bubbles: stackedBubbles,
                            peekHeight: bubblePeekHeight,
                            isHidden: $isStackHidden,
                            onTap: { id in
                                isProgrammaticScroll = true
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    isProgrammaticScroll = false
                                }
                            }
                        )
                    }
                    .onChange(of: chatHistory.count) {
                        shouldFollowContent = true
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: streaming.pendingChatObserverExchanges.count) {
                        shouldFollowContent = true
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: isLoading) {
                        if !isLoading {
                            state.flushPendingChatObserverExchanges()
                        }
                    }
                    .onChange(of: isVoiceFollowUp) {
                        if isVoiceFollowUp {
                            shouldFollowContent = true
                            scrollToBottom(proxy: proxy, anchor: "voiceFollowUp")
                        }
                    }

                    // Scroll-to-bottom overlay button
                    if !shouldFollowContent && !chatHistory.isEmpty {
                        Button {
                            shouldFollowContent = true
                            scrollToBottom(proxy: proxy)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(FazmColors.purplePrimary)
                                .background(
                                    Circle()
                                        .fill(FazmColors.backgroundPrimary)
                                        .frame(width: 24, height: 24)
                                )
                                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: shouldFollowContent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !input.messageQueue.isEmpty {
                MessageQueueView(
                    queue: Binding(
                        get: { input.messageQueue },
                        set: { input.messageQueue = $0 }
                    ),
                    onSendNow: { item in onSendNow?(item) },
                    onDelete: { item in onDeleteQueued?(item) },
                    onClearAll: { onClearQueue?() },
                    onReorder: { source, dest in onReorderQueue?(source, dest) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: input.messageQueue.count)
            }

            // Chat observer thinking indicator — only when no cards have arrived yet
            if streaming.isChatObserverRunning && !hasAnyChatObserverCards {
                chatObserverThinkingIndicator
            }

            if !isVoiceFollowUp {
                followUpInputView
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            onClose?()
        }
        .onAppear {
            let key = "fazm_didCrashLastSession"
            if UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.removeObject(forKey: key)
                isHanging = true
                isHangingFromCrash = true
            }
        }
        .onChange(of: isLoading) {
            // Debounce the typing indicator: show immediately, but delay hiding by 600ms
            // so rapid API retries don't cause the dots to flicker on and off.
            if isLoading {
                loadingHideTask?.cancel()
                loadingHideTask = nil
                debouncedIsLoading = true
                // A new query is actively processing. isHanging is only ever set
                // true by the crash detector in onAppear, so a value still set
                // here is stale: it would falsely render "not responding" over a
                // perfectly healthy query. Clear it the moment real work resumes.
                isHanging = false
                isHangingFromCrash = false
            } else {
                loadingHideTask?.cancel()
                loadingHideTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { debouncedIsLoading = false }
                }
            }

            if !isLoading {
                // Cleanup on response completion. The 60s auto-cancel hang detector
                // that used to live here was removed (May 3 2026): it was killing
                // legitimate slow Opus thinking turns at exactly 60s, after which
                // the bridge's priorContext-replay recovery would silently return
                // an empty bubble (because the trailing assistant turn in the
                // replayed transcript made the model think the work was done).
                // Net result: paid for the call, got "Failed to get a response."
                // The bridge already enforces real timeouts (tool watchdogs,
                // 600s ACPBridge inactivity timeout); we don't need a second one.
                hangTask?.cancel()
                hangTask = nil
                isStopping = false
                // Clear hanging state after any successful response, including crash-triggered hangs.
                // Once the user gets a response, the previous crash is no longer worth flagging.
                isHanging = false
                isHangingFromCrash = false
            }
        }
    }

    @AppStorage("aiChatWorkingDirectory") private var globalWorkspaceDirectory: String = ""
    @State private var connectClaudePulse = false
    @State private var showWorkspaceInfo = false

    /// The effective workspace for this view: per-window state if set, otherwise global default.
    private var aiChatWorkingDirectory: String {
        workspace.workspaceDirectory.isEmpty ? globalWorkspaceDirectory : workspace.workspaceDirectory
    }

    private func scrollToBottom(proxy: ScrollViewProxy, anchor: String = "bottom") {
        isProgrammaticScroll = true
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isProgrammaticScroll = false
        }
    }

    private var isHomeDirectory: Bool {
        let home = NSHomeDirectory()
        return aiChatWorkingDirectory.isEmpty || aiChatWorkingDirectory == home
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            if streaming.isCompacting {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("compacting context…")
                    .scaledFont(size: 14)
                    .foregroundColor(.orange)
            } else if isLoading {
                if isHanging {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 12)
                        .foregroundColor(.orange)
                    Text("not responding")
                        .scaledFont(size: 14)
                        .foregroundColor(.orange)
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    let hasRunningTools = currentMessage?.contentBlocks.contains(where: {
                        if case .toolCall(_, _, .running, _, _, _) = $0 { return true }
                        return false
                    }) ?? false
                    // A query queued behind first-launch warmup would otherwise
                    // show a bare "thinking" spinner that looks stuck — name the
                    // actual wait so the user knows it's cold-starting, not hung.
                    let headerLabel = streaming.isBridgeWarmingUp
                        ? "preparing assistant…"
                        : (hasRunningTools ? "using tools" : "thinking")
                    Text(headerLabel)
                        .scaledFont(size: 14)
                        .foregroundColor(.secondary)
                }
            } else {
                workspaceLabel
            }

            if state.showConnectClaudeButton {
                connectClaudeButton
            }

            if state.showUpgradeClaudeButton {
                upgradeClaudeButton
            }

            Spacer()

            ModelToggleButton(localModel: localModel, onCodexLogin: onCodexLogin)

            VoiceMuteButton()

            ReportIssueButton(isHanging: isHanging)

            CopyConversationButton(
                chatHistory: chatHistory,
                userInput: userInput,
                currentMessage: currentMessage
            )

            if let onPopOut {
                PopOutButton(action: onPopOut)
            }

            if let onFork, !chatHistory.isEmpty {
                ForkChatButton(action: onFork)
            }

            if let onNewChat {
                NewChatButton(action: onNewChat)
            }
        }
    }

    /// Recents to surface in the workspace dropdown: most-recent-first, with
    /// the current workspace filtered out and stale paths dropped.
    private var availableRecentWorkspaces: [String] {
        let current = aiChatWorkingDirectory
        let home = NSHomeDirectory()
        return RecentWorkspaces.list().filter { path in
            guard !path.isEmpty, path != current, path != home else { return false }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    @ViewBuilder
    private var workspaceLabel: some View {
        if onChangeWorkspace != nil {
            HStack(spacing: 6) {
                Menu {
                    let recents = availableRecentWorkspaces
                    if !recents.isEmpty {
                        ForEach(recents, id: \.self) { path in
                            Button {
                                onChangeWorkspace?(path)
                            } label: {
                                Label((path as NSString).lastPathComponent, systemImage: "folder")
                            }
                        }
                        Divider()
                    }
                    Button {
                        onChangeWorkspace?(nil)
                    } label: {
                        Label("Browse…", systemImage: "folder.badge.plus")
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isHomeDirectory {
                            Image(systemName: "plus.rectangle.on.folder.fill")
                                .scaledFont(size: 10)
                            Text("Create project")
                                .scaledFont(size: 14)
                                .lineLimit(1)
                        } else {
                            Image(systemName: "folder.fill")
                                .scaledFont(size: 10)
                            Text((aiChatWorkingDirectory as NSString).lastPathComponent)
                                .scaledFont(size: 14)
                                .lineLimit(1)
                        }
                    }
                    .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // horizontal: false lets the Text's lineLimit(1) truncate when the
                // workspace folder name is long, instead of forcing the header to
                // overflow the window edges. vertical: true keeps the menu from
                // stretching tall.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220, alignment: .leading)
                .help(isHomeDirectory ? "Select a project folder" : aiChatWorkingDirectory)
                .onAppear {
                    // Seed recents with the current workspace so it persists as
                    // a "previous" entry the next time the user switches.
                    if !isHomeDirectory {
                        RecentWorkspaces.add(aiChatWorkingDirectory)
                    }
                }

                Button(action: { showWorkspaceInfo = true }) {
                    Image(systemName: "info.circle")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showWorkspaceInfo, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Projects")
                            .scaledFont(size: 13, weight: .semibold)
                        Text("Set a project directory to give Fazm context about your codebase. It will read CLAUDE.md and other config files to understand your project.")
                            .scaledFont(size: 12)
                            .foregroundColor(.secondary)
                        Text("Changing the project starts a new session.")
                            .scaledFont(size: 11)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(12)
                    .frame(width: 260)
                }
            }
        } else {
            Text("Fazm says")
                .scaledFont(size: 14)
                .foregroundColor(.secondary)
        }
    }

    private var connectClaudeButton: some View {
        Button(action: { onConnectClaude?() }) {
            HStack(spacing: 5) {
                Image(systemName: "person.badge.key")
                    .scaledFont(size: 10)
                Text("Connect Claude")
                    .scaledFont(size: 11, weight: .medium)
            }
            .foregroundColor(FazmColors.overlayForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(FazmColors.purplePrimary)
                    .shadow(color: FazmColors.purplePrimary.opacity(connectClaudePulse ? 0.6 : 0.2), radius: connectClaudePulse ? 8 : 2)
            )
        }
        .buttonStyle(.plain)
        .onAppear { startConnectClaudePulseIfVisible() }
        .onChange(of: windowIsVisible) { _, visible in
            if visible {
                startConnectClaudePulseIfVisible()
            } else {
                // Snap to the static value without an animation so the
                // repeatForever loop releases the display cycle.
                withAnimation(.default) { connectClaudePulse = false }
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func startConnectClaudePulseIfVisible() {
        guard windowIsVisible else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            connectClaudePulse = true
        }
    }

    @State private var upgradePulse = false

    private var upgradeClaudeButton: some View {
        Button(action: {
            if let url = URL(string: "https://claude.ai/upgrade") {
                NSWorkspace.shared.open(url)
            }
            state.showUpgradeClaudeButton = false
        }) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.circle")
                    .scaledFont(size: 10)
                Text("Upgrade Plan")
                    .scaledFont(size: 11, weight: .medium)
            }
            .foregroundColor(FazmColors.overlayForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(FazmColors.purplePrimary)
                    .shadow(color: FazmColors.purplePrimary.opacity(upgradePulse ? 0.6 : 0.2), radius: upgradePulse ? 8 : 2)
            )
        }
        .buttonStyle(.plain)
        .onAppear { startUpgradePulseIfVisible() }
        .onChange(of: windowIsVisible) { _, visible in
            if visible {
                startUpgradePulseIfVisible()
            } else {
                withAnimation(.default) { upgradePulse = false }
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func startUpgradePulseIfVisible() {
        guard windowIsVisible else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            upgradePulse = true
        }
    }

    // MARK: - Tutorial Banner

    private var tutorialBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .scaledFont(size: 11)
            Text("Getting Started — Step \(min(tutorial.tutorialChatStep + 1, tutorial.tutorialPrompts.count)) of \(tutorial.tutorialPrompts.count)")
                .scaledFont(size: 11, weight: .medium)
            Spacer()
            Button("Skip") {
                TutorialChatGuide.shared.finish(barState: state)
            }
            .buttonStyle(.plain)
            .scaledFont(size: 11)
            .foregroundColor(FazmColors.overlayForeground.opacity(0.6))
        }
        .foregroundColor(FazmColors.purplePrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(FazmColors.purplePrimary.opacity(0.15))
        .cornerRadius(8)
    }

    // MARK: - Content Blocks Rendering

    /// Renders a ChatMessage's content blocks using the shared components from ChatPage.
    @ViewBuilder
    private func contentBlocksView(for message: ChatMessage) -> some View {
        if !message.contentBlocks.isEmpty {
            let grouped = ContentBlockGroup.group(message.contentBlocks)
            let chatObserverCards = grouped.compactMap { group -> (id: String, activityId: Int64, type: String, content: String, buttons: [ObserverCardButton], actedAction: String?)? in
                if case .observerCard(let id, let activityId, let type, let content, let buttons, let actedAction) = group {
                    return (id, activityId, type, content, buttons, actedAction)
                }
                return nil
            }
            let nonChatObserverGroups = grouped.filter {
                if case .observerCard = $0 { return false }
                return true
            }

            // Render non-chat-observer blocks normally
            ForEach(nonChatObserverGroups) { group in
                switch group {
                case .text(_, let text):
                    SelectableMarkdown(text: text, sender: .ai)
                        .environment(\.compactCodeBlocks, true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolCalls(_, let calls):
                    ToolCallsGroup(calls: calls)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .thinking(_, let text):
                    ThinkingBlock(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .discoveryCard(_, let title, let summary, let fullText):
                    DiscoveryCard(title: title, summary: summary, fullText: fullText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .observerCard:
                    EmptyView() // handled below
                case .systemEvent(_, let event):
                    SystemEventCardView(event: event)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .browserActivity(_, _, let toolName, let action, let mode, let url, let status):
                    BrowserActivityCard(
                        toolName: toolName, action: action, mode: mode,
                        url: url, status: status
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Render chat observer cards as a compact stack (thinking-only state shown near input)
            if !chatObserverCards.isEmpty {
                ObserverCardStackView(
                    cards: chatObserverCards.map { card in
                        ObserverCardItem(
                            id: card.id,
                            activityId: card.activityId,
                            type: card.type,
                            content: card.content,
                            buttons: card.buttons,
                            actedAction: card.actedAction
                        )
                    },
                    isChatObserverRunning: streaming.isChatObserverRunning,
                    onAction: { id, action in
                        handleChatObserverCardAction(activityId: id, action: action)
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !message.text.isEmpty {
            SelectableMarkdown(text: message.text, sender: .ai)
                .environment(\.compactCodeBlocks, true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func handleChatObserverCardAction(activityId: Int64, action: String) {
        onChatObserverCardAction?(activityId, action)
        // Persist the action in the content block so it survives view recreation
        // Use the view's own state (via @EnvironmentObject) so pop-outs update their own state, not the global bar
        for i in streaming.chatHistory.indices {
            for j in streaming.chatHistory[i].aiMessage.contentBlocks.indices {
                if case .observerCard(let id, let aId, let type, let content, let buttons, _) = streaming.chatHistory[i].aiMessage.contentBlocks[j],
                   aId == activityId {
                    streaming.chatHistory[i].aiMessage.contentBlocks[j] = .observerCard(id: id, activityId: aId, type: type, content: content, buttons: buttons, actedAction: action)
                    return
                }
            }
        }
        // Also check pending chat observer exchanges
        for i in streaming.pendingChatObserverExchanges.indices {
            for j in streaming.pendingChatObserverExchanges[i].aiMessage.contentBlocks.indices {
                if case .observerCard(let id, let aId, let type, let content, let buttons, _) = streaming.pendingChatObserverExchanges[i].aiMessage.contentBlocks[j],
                   aId == activityId {
                    streaming.pendingChatObserverExchanges[i].aiMessage.contentBlocks[j] = .observerCard(id: id, activityId: aId, type: type, content: content, buttons: buttons, actedAction: action)
                    return
                }
            }
        }
    }

    // MARK: - Consolidated Chat Observer Cards

    /// Collects all chat observer cards from chat-observer-only history exchanges into one stack.
    @ViewBuilder
    private var consolidatedHistoryChatObserverCards: some View {
        let cards = extractChatObserverCards(from: chatObserverOnlyExchanges)
        if !cards.isEmpty {
            ObserverCardStackView(
                cards: cards,
                onAction: { id, action in
                    handleChatObserverCardAction(activityId: id, action: action)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    /// Collects all chat observer cards from pending chat observer exchanges into one stack.
    /// Collects all chat observer cards from pending chat observer exchanges into one stack.
    /// Uses the view's own @EnvironmentObject state so pop-outs only show their own pending cards.
    @ViewBuilder
    private var consolidatedPendingChatObserverCards: some View {
        let cards = extractChatObserverCards(from: streaming.pendingChatObserverExchanges)
        if !cards.isEmpty {
            ObserverCardStackView(
                cards: cards,
                onAction: { id, action in
                    handleChatObserverCardAction(activityId: id, action: action)
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    private func extractChatObserverCards(from exchanges: [FloatingChatExchange]) -> [ObserverCardItem] {
        exchanges.flatMap { exchange in
            exchange.aiMessage.contentBlocks.compactMap { block -> ObserverCardItem? in
                if case .observerCard(let id, let activityId, let type, let content, let buttons, let actedAction) = block {
                    return ObserverCardItem(id: id, activityId: activityId, type: type, content: content, buttons: buttons, actedAction: actedAction)
                }
                return nil
            }
        }
    }

    // MARK: - Chat History

    private func chatExchangeView(_ exchange: FloatingChatExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Question bubble (hidden for observer-only entries with no user question)
            if !exchange.question.isEmpty {
                ExpandableQuestionBubble(
                    question: exchange.question,
                    exchangeId: exchange.id,
                    onEdit: onEditMessage
                )
                    .opacity(stackedBubbleIDs.contains(exchange.id) ? 0 : 1)
                    .background(
                        GeometryReader { geo in
                            let frame = geo.frame(in: .named(Self.chatScrollSpace))
                            Color.clear.preference(
                                key: StackedBubblesPreferenceKey.self,
                                value: [StackedBubbleInfo(
                                    id: exchange.id,
                                    question: exchange.question,
                                    topY: frame.minY,
                                    height: frame.height
                                )]
                            )
                        }
                    )
            }

            // Response with content blocks
            if !exchange.aiMessage.contentBlocks.isEmpty || !exchange.aiMessage.text.isEmpty {
                MessageWithCopyButton(alignment: .topTrailing) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exchange.aiMessage.copyableText, forType: .string)
                } content: {
                    VStack(alignment: .leading, spacing: 4) {
                        contentBlocksView(for: exchange.aiMessage)
                    }
                    .padding(.horizontal, 4)
                }
            }

            Divider()
                .background(FazmColors.overlayForeground.opacity(0.1))
        }
        .id(exchange.id)
    }

    // MARK: - Current Question & Response

    private var questionBar: some View {
        HStack(alignment: .top, spacing: 4) {
            Group {
                if isQuestionExpanded {
                    ScrollView {
                        SelectableText(
                            text: userInput,
                            fontSize: 13,
                            textColor: NSColor(FazmColors.overlayForeground)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else {
                    SelectableText(
                        text: userInput,
                        fontSize: 13,
                        textColor: NSColor(FazmColors.overlayForeground),
                        lineLimit: 1
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            QuestionBarButtons(
                needsExpansion: needsExpansion,
                isExpanded: $isQuestionExpanded,
                userInput: userInput,
                isBubbleHovered: isQuestionBarHovered
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FazmColors.overlayForeground.opacity(0.1))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onHover { isQuestionBarHovered = $0 }
    }

    /// Whether the user input text needs an expand button — cached to avoid
    /// recalculating NSAttributedString.boundingRect on every render.
    private var needsExpansion: Bool {
        let font = NSFont.systemFont(ofSize: 13)
        return (userInput as NSString).boundingRect(
            with: NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: [.font: font]
        ).size.height > font.pointSize * 1.5
    }

    private var currentContentView: some View {
        Group {
            if let message = currentMessage {
                MessageWithCopyButton(alignment: .topTrailing) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.copyableText, forType: .string)
                } content: {
                    VStack(alignment: .leading, spacing: 4) {
                        contentBlocksView(for: message)

                        // Show typing indicator while AI is still generating.
                        // Uses debouncedIsLoading (600ms min display) to prevent flicker
                        // during rapid API retries.
                        if debouncedIsLoading || message.isStreaming {
                            TypingIndicator()
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                }
                .id(message.id)
            } else {
                TypingIndicator()
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Voice Follow-Up

    private var voiceFollowUpView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(1.2)
                .animation(windowIsVisible ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: isVoiceFollowUp)

            Image(systemName: "mic.fill")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(FazmColors.overlayForeground)

            if !voiceFollowUpTranscript.isEmpty {
                Text(voiceFollowUpTranscript)
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.8))
                    .lineLimit(2)
                    .truncationMode(.head)
            } else {
                Text("Listening...")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.5))
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.15))
        .cornerRadius(8)
    }

    // MARK: - Suggested Replies

    private var suggestedRepliesView: some View {
        QuickReplyButtonsView(
            question: suggestedReplyQuestion,
            options: suggestedReplies,
            onSelect: { reply in
                suggestedReplies = []
                suggestedReplyQuestion = ""
                onSendFollowUp?(reply, [])
            }
        )
    }

    // MARK: - Chat Observer Thinking Indicator

    /// True when any chat observer cards exist in current message, history, or pending exchanges
    private var hasAnyChatObserverCards: Bool {
        let currentHas = currentMessage?.contentBlocks.contains(where: {
            if case .observerCard = $0 { return true }
            return false
        }) ?? false
        if currentHas { return true }

        let pendingHas = streaming.pendingChatObserverExchanges.contains(where: { exchange in
            exchange.aiMessage.contentBlocks.contains(where: {
                if case .observerCard = $0 { return true }
                return false
            })
        })
        return pendingHas
    }

    @State private var chatObserverPulseOpacity: Double = 0.7

    private var chatObserverThinkingIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.circle.fill")
                .scaledFont(size: 11)
                .foregroundColor(FazmColors.purplePrimary.opacity(windowIsVisible ? chatObserverPulseOpacity : 0.7))
                .animation(windowIsVisible ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: chatObserverPulseOpacity)
                .onAppear { chatObserverPulseOpacity = windowIsVisible ? 0.3 : 0.7 }
                .onChange(of: windowIsVisible) { _, visible in
                    // Toggling pulseOpacity with the now-non-repeating animation snaps
                    // the in-flight repeatForever to a static value when occluded.
                    chatObserverPulseOpacity = visible ? 0.3 : 0.7
                }

            Text("Chat observer is thinking...")
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(FazmColors.overlayForeground.opacity(0.4))

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(FazmColors.purplePrimary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(FazmColors.purplePrimary.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Follow-Up Input

    private var followUpHasInput: Bool {
        !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.pendingAttachments.isEmpty
    }

    private var followUpInputView: some View {
        VStack(spacing: 0) {
            // Attachment thumbnails strip
            if !input.pendingAttachments.isEmpty {
                ChatAttachmentStrip(attachments: Binding(get: { input.pendingAttachments }, set: { input.pendingAttachments = $0 }))
            }

            HStack(alignment: .center, spacing: 6) {
                ChatAttachmentButton {
                    ChatAttachmentHelper.openFilePicker { urls in
                        ChatAttachmentHelper.addFiles(from: urls, to: &input.pendingAttachments)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if followUpText.isEmpty {
                        Text(isLoading && isThisSessionStreaming ? "Type next question (queued)..." : "Ask follow up...")
                            .scaledFont(size: 13)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }

                    FazmTextEditor(
                        text: $followUpText,
                        lineFragmentPadding: 8,
                        onSubmit: { sendFollowUp() },
                        focusOnAppear: false,
                        onPasteFiles: { urls in
                            ChatAttachmentHelper.addFiles(from: urls, to: &input.pendingAttachments)
                        },
                        onPasteImageData: { data in
                            ChatAttachmentHelper.addPastedImage(data, to: &input.pendingAttachments)
                        },
                        minHeight: 34,
                        maxHeight: 120,
                        onHeightChange: { newHeight in
                            if abs(followUpTextHeight - newHeight) > 1 {
                                followUpTextHeight = newHeight
                            }
                        }
                    )
                    .onChange(of: input.pendingFollowUpText) {
                        if !input.pendingFollowUpText.isEmpty {
                            if followUpText.isEmpty {
                                followUpText = input.pendingFollowUpText
                            } else {
                                followUpText += " " + input.pendingFollowUpText
                            }
                            input.pendingFollowUpText = ""
                        }
                    }
                    .onChange(of: voice.isVoiceListening) {
                        if voice.isVoiceListening {
                            preVoiceFollowUpText = followUpText
                        }
                    }
                    .onChange(of: input.aiInputText) {
                        if voice.isVoiceListening && !input.aiInputText.isEmpty && input.aiInputText != followUpText {
                            if preVoiceFollowUpText.isEmpty {
                                followUpText = input.aiInputText
                            } else {
                                followUpText = preVoiceFollowUpText + " " + input.aiInputText
                            }
                        }
                    }
                }
                .frame(height: followUpTextHeight)
                .background(FazmColors.overlayForeground.opacity(0.1))
                .cornerRadius(8)
                .slashCommandPopover($followUpText)

                PushToTalkButton(isListening: voice.isVoiceListening, iconSize: 16, frameSize: 24)

                if (isLoading || currentMessage?.isStreaming == true) && !followUpHasInput {
                    Button(action: {
                        isStopping = true
                        // Eagerly clear local UI so the spinner and "Not Responding"
                        // banner vanish instantly, even if the bridge takes a while
                        // (or forever) to actually abort. The onChange(of: isLoading)
                        // handler also clears these when streaming.isAILoading flips
                        // false, but doing it here makes Stop feel instant.
                        loadingHideTask?.cancel()
                        loadingHideTask = nil
                        debouncedIsLoading = false
                        hangTask?.cancel()
                        hangTask = nil
                        isHanging = false
                        isHangingFromCrash = false
                        onStopAgent?()
                    }) {
                        Image(systemName: isStopping ? "ellipsis.circle" : "stop.circle.fill")
                            .scaledFont(size: 20)
                            .foregroundColor(isStopping ? .secondary : .red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isStopping)
                    .help("Stop generating")
                } else {
                    Button(action: { sendFollowUp() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .scaledFont(size: 20)
                            .foregroundColor(
                                followUpHasInput
                                    ? FazmColors.overlayForeground : .secondary
                            )
                    }
                    .disabled(!followUpHasInput)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var isThisSessionStreaming: Bool {
        currentMessage?.isStreaming == true
    }

    private func sendFollowUp() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = input.pendingAttachments
        guard !trimmed.isEmpty || !attachmentsToSend.isEmpty else { return }
        followUpText = ""
        input.pendingAttachments = []

        if isLoading || isThisSessionStreaming {
            // THIS window is busy (pre-first-token wait OR actively streaming) — queue the message (text only).
            // isLoading flips to false as soon as the first delta arrives, so && would never fire during streaming.
            onEnqueueMessage?(trimmed)
        } else {
            // Window is idle (or another window is busy) — always render the user
            // message immediately. sendQuery handles bridge serialization via the queue.
            onSendFollowUp?(trimmed, attachmentsToSend)
        }
    }
}

// MARK: - Expandable Question Bubble (chat history)

/// Question bubble in chat history that truncates to 2 lines with an expand chevron.
/// When `onEdit` is provided, a pencil button (revealed on hover) lets the user
/// edit the message and resubmit, which truncates the conversation at this
/// exchange and restarts with the new text. The exchange is identified by its
/// stable `exchangeId`, so the affordance shows on every real question bubble.
private struct ExpandableQuestionBubble: View {
    let question: String
    var exchangeId: UUID
    var onEdit: ((_ exchangeId: String, _ newText: String) -> Void)?

    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var editText: String = ""
    @State private var isBubbleHovered = false

    private var canEdit: Bool {
        onEdit != nil
    }

    private var needsExpansion: Bool {
        let font = NSFont.systemFont(ofSize: 13)
        return (question as NSString).boundingRect(
            with: NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: [.font: font]
        ).size.height > font.pointSize * 1.5 * 2 // more than 2 lines
    }

    var body: some View {
        Group {
            if isEditing {
                editingView
            } else {
                displayView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FazmColors.overlayForeground.opacity(0.1))
        .cornerRadius(8)
    }

    private var displayView: some View {
        HStack(alignment: .top, spacing: 4) {
            SelectableText(
                text: question,
                fontSize: 13,
                textColor: NSColor(FazmColors.overlayForeground),
                lineLimit: isExpanded ? nil : 2
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            QuestionBarButtons(
                needsExpansion: needsExpansion,
                isExpanded: $isExpanded,
                userInput: question,
                canEdit: canEdit,
                isBubbleHovered: isBubbleHovered,
                onEditTap: {
                    editText = question
                    isEditing = true
                }
            )
        }
        // Detect hover over the whole bubble row (not just the button strip)
        // so the copy / edit / info icons reveal wherever the cursor is.
        .contentShape(Rectangle())
        .onHover { isBubbleHovered = $0 }
    }

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditableTextArea(text: $editText, onSubmit: commitEdit)
                .frame(minHeight: 60, maxHeight: 200)

            HStack(spacing: 8) {
                EditMessageInfoButton()

                Spacer()

                Button("Cancel") {
                    isEditing = false
                    editText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .scaledFont(size: 12)

                Button(action: commitEdit) {
                    Text("Save & resubmit")
                        .scaledFont(size: 12)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(FazmColors.overlayForeground.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(trimmedEditText.isEmpty || trimmedEditText == question)
            }
        }
    }

    private var trimmedEditText: String {
        editText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitEdit() {
        let trimmed = trimmedEditText
        guard !trimmed.isEmpty, trimmed != question else { return }
        guard let edit = onEdit else { return }
        isEditing = false
        editText = ""
        edit(exchangeId.uuidString, trimmed)
    }
}

/// Multi-line text area for editing a past message in-place. Uses NSTextView
/// (via NSViewRepresentable) so Cmd+Return submits and the field auto-focuses.
private struct EditableTextArea: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.delegate = context.coordinator
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.isRichText = false
            tv.allowsUndo = true
            tv.textContainerInset = NSSize(width: 4, height: 6)
            tv.backgroundColor = NSColor.clear
            tv.drawsBackground = false
            tv.textColor = NSColor(FazmColors.overlayForeground)
            tv.string = text
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
            }
        }
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: EditableTextArea
        init(_ parent: EditableTextArea) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Cmd+Return submits. Plain Return inserts a newline (default).
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.command) {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}

/// Small info icon shown inline with the Cancel / Save & resubmit buttons.
/// Hovering reveals the disclaimer about replay fidelity in a popover, so the
/// caveat doesn't take up vertical space in the edit area.
private struct EditMessageInfoButton: View {
    @State private var showHint = false

    var body: some View {
        Image(systemName: "info.circle")
            .scaledFont(size: 12)
            .foregroundColor(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onHover { hovering in
                showHint = hovering
            }
            .popover(isPresented: $showHint, arrowEdge: .top) {
                Text("Resubmitting truncates the conversation here and replays a text-only summary of earlier turns (no tool calls or thinking blocks, up to ~20 turns). The new response may diverge from the original thread.")
                    .scaledFont(size: 11)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: 280)
            }
    }
}

// MARK: - Question Bar Buttons (copy + expand, inline)

/// Inline buttons for the question bar — copy, edit, info, and expand sit
/// side by side to avoid overlap.
private struct QuestionBarButtons: View {
    let needsExpansion: Bool
    @Binding var isExpanded: Bool
    let userInput: String
    /// When true, render the pencil (edit) and info (?) buttons on hover.
    var canEdit: Bool = false
    /// Hover state of the whole bubble row (lifted up so hovering anywhere on
    /// the bubble — not just this narrow button strip — reveals the icons).
    var isBubbleHovered: Bool = false
    var onEditTap: (() -> Void)? = nil

    @State private var showCopied = false

    /// Icons are visible when the cursor is anywhere over the bubble.
    private var isHovered: Bool { isBubbleHovered }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(userInput, forType: .string)
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showCopied = false
                }
            }) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .scaledFont(size: 11)
                    .foregroundColor(showCopied ? .green : .secondary)
                    .frame(width: 22, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || showCopied ? 1 : 0)

            if canEdit, let onEditTap = onEditTap {
                Button(action: onEditTap) {
                    Image(systemName: "square.and.pencil")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Edit and resubmit — rewinds the conversation here")
            }

            if needsExpansion {
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10)
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Message Copy Button (hover overlay)

/// Wraps content with a copy icon that appears on hover.
struct MessageWithCopyButton<Content: View>: View {
    let alignment: Alignment
    let onCopy: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        ZStack(alignment: alignment) {
            content

            Button(action: {
                onCopy()
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showCopied = false
                }
            }) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .scaledFont(size: 10)
                    .foregroundColor(showCopied ? .green : .secondary)
                    .padding(4)
                    .background(.ultraThinMaterial)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .padding(4)
            .opacity(isHovered || showCopied ? 1 : 0)
            .allowsHitTesting(isHovered || showCopied)
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Model Toggle Button

struct ModelToggleButton: View {
    @ObservedObject private var shortcutSettings = ShortcutSettings.shared
    @ObservedObject private var codexBackend = CodexBackendManager.shared
    /// When provided, reads and writes model selection to this binding instead of the global setting.
    var localModel: Binding<String>?
    /// Triggered when the user picks a GPT model while Codex is unauthenticated.
    /// The bar window wires this to `chatProvider.startCodexLogin()`. After OAuth
    /// completes, ChatProvider applies `pendingPickerModelId` to actually switch
    /// the picker to the requested model.
    var onCodexLogin: (() -> Void)?

    private var selectedModelId: String {
        localModel?.wrappedValue ?? shortcutSettings.selectedModel
    }

    private var selectedModelShortLabel: String {
        if codexBackend.loginInProgress, codexBackend.pendingPickerModelId != nil {
            return "Connecting…"
        }
        return shortcutSettings.shortLabel(for: selectedModelId) ?? "Fast"
    }

    var body: some View {
        Menu {
            ForEach(shortcutSettings.availableModels) { model in
                Button {
                    let needsCodexAuth = model.id.hasPrefix("gpt-") && codexBackend.authMode == "none"
                    if needsCodexAuth {
                        codexBackend.pendingPickerModelId = model.id
                        onCodexLogin?()
                        return
                    }
                    if let localModel {
                        localModel.wrappedValue = model.id
                    }
                    // Always write through to the global default so new pop-outs
                    // and the floating bar inherit the most recent model choice.
                    shortcutSettings.selectedModel = model.id
                } label: {
                    if selectedModelId == model.id {
                        Label(model.label, systemImage: "checkmark")
                    } else if model.id.hasPrefix("gpt-") && codexBackend.authMode == "none" {
                        Label(model.label + " — Connect…", systemImage: "person.badge.key")
                    } else {
                        Text(model.label)
                    }
                }
            }
            Divider()
            Button {
                openCodexModelsSettings()
            } label: {
                Label("Customize models…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 2) {
                Text(selectedModelShortLabel)
                    .scaledFont(size: 11, weight: .medium)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 7, weight: .medium)
            }
            .foregroundColor(.secondary)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// Open the main settings window (creating it if necessary) and scroll to
    /// the Visible GPT Models card. Uses in-process notification posting so it
    /// works even when a sibling Fazm build owns the `fazm://` URL scheme.
    private func openCodexModelsSettings() {
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.shared.openWindow?(id: "main")
        // Give the window a beat to attach the .onReceive listener if it just
        // got created. If it was already open, the delay is harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(
                name: NSNotification.Name("navigateToSetting"),
                object: nil,
                userInfo: ["settingId": "advanced.codex.models"]
            )
        }
    }
}

// MARK: - Voice Mute Button

/// Inline toggle to mute/unmute voice responses (TTS).
struct VoiceMuteButton: View {
    @AppStorage("voiceResponseEnabled") private var voiceResponseEnabled = true

    var body: some View {
        Button {
            voiceResponseEnabled.toggle()
            AnalyticsManager.shared.settingToggled(setting: "voice_response", enabled: voiceResponseEnabled)
            // Stop any currently playing audio when muting
            if !voiceResponseEnabled {
                ChatToolExecutor.stopTTSPlayback()
            }
        } label: {
            Image(systemName: voiceResponseEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .scaledFont(size: 11)
                .foregroundColor(voiceResponseEnabled ? .secondary : .orange)
        }
        .buttonStyle(.plain)
        .floatingHint(voiceResponseEnabled ? "Mute voice" : "Unmute voice")
    }
}

// MARK: - Pop Out Button

struct PopOutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PopOutIcon()
                .frame(width: 12, height: 12)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .floatingHint("Pop out")
    }
}

struct PopOutIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            // Back window (lower-left)
            let backRect = RoundedRectangle(cornerRadius: w * 0.08)
            let backPath = backRect.path(in: CGRect(
                x: 0, y: h * 0.3,
                width: w * 0.6, height: w * 0.6
            ))
            context.stroke(backPath, with: .foreground, lineWidth: 1.2)

            // Front window (upper-right)
            let frontRect = RoundedRectangle(cornerRadius: w * 0.08)
            let frontPath = frontRect.path(in: CGRect(
                x: w * 0.28, y: h * 0.05,
                width: w * 0.6, height: w * 0.6
            ))
            context.stroke(frontPath, with: .foreground, lineWidth: 1.2)

            // Arrow line
            var arrowLine = Path()
            arrowLine.move(to: CGPoint(x: w * 0.42, y: h * 0.58))
            arrowLine.addLine(to: CGPoint(x: w * 0.78, y: h * 0.22))
            context.stroke(arrowLine, with: .foreground, lineWidth: 1.4)

            // Arrow head
            var arrowHead = Path()
            arrowHead.move(to: CGPoint(x: w * 0.6, y: h * 0.2))
            arrowHead.addLine(to: CGPoint(x: w * 0.8, y: h * 0.2))
            arrowHead.addLine(to: CGPoint(x: w * 0.8, y: h * 0.4))
            context.stroke(arrowHead, with: .foreground, lineWidth: 1.4)
        }
    }
}

// MARK: - New Chat Button

struct NewChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .scaledFont(size: 11)
                Text("⌘N")
                    .scaledFont(size: 9)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(FazmColors.overlayForeground.opacity(0.1))
                    .cornerRadius(3)
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .floatingHint("New chat")
    }
}

// MARK: - Fork Chat Button

/// Branches the current chat into a new session. The agent retains the prior
/// conversation as context; the source branch is preserved on disk and is
/// reachable via Conversation History.
struct ForkChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.branch")
                .scaledFont(size: 11)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .floatingHint("Fork chat")
    }
}

// MARK: - Slash command popover

/// Renders the agent's `available_commands_update` list as a popover when the
/// user types a leading `/` in a chat input. Anchored to whatever view the
/// `.slashCommandPopover($text)` modifier is applied to.
private struct SlashCommandPopover: ViewModifier {
    @Binding var text: String
    @ObservedObject private var registry = SlashCommandRegistry.shared

    /// Returns the query string after the leading `/` only when the input is
    /// in slash-command position (first non-empty token, no whitespace yet).
    /// Anything else (no slash, slash mid-message, slash followed by space)
    /// resolves to nil and hides the popover.
    private var slashQuery: String? {
        guard text.hasPrefix("/") else { return nil }
        let after = String(text.dropFirst())
        if after.contains(" ") || after.contains("\n") { return nil }
        return after
    }

    private var matchingCommands: [ACPBridge.AvailableCommand] {
        guard let q = slashQuery?.lowercased() else { return [] }
        if q.isEmpty { return registry.commands }
        return registry.commands.filter { $0.name.lowercased().hasPrefix(q) }
    }

    func body(content: Content) -> some View {
        content
            // Use an in-window overlay rather than `.popover()` because the
            // SwiftUI popover spawns a new key window that steals focus from
            // the text editor on every keystroke (it would re-key whenever
            // `matchingCommands` changes, breaking typing). An overlay stays
            // in the same window so first responder stays on the editor.
            .overlay(alignment: .topLeading) {
                if slashQuery != nil && !matchingCommands.isEmpty {
                    SlashCommandListView(commands: matchingCommands) { cmd in
                        // Trailing space lets the user immediately type the
                        // argument (when there's a hint); it also disqualifies
                        // `slashQuery` so the overlay dismisses itself.
                        text = "/\(cmd.name) "
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    // Float the list ABOVE the input by aligning its bottom
                    // edge 6pt above the anchor's top edge.
                    .alignmentGuide(.top) { d in d[.bottom] + 6 }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(1000)
                }
            }
    }
}

private struct SlashCommandListView: View {
    let commands: [ACPBridge.AvailableCommand]
    let onPick: (ACPBridge.AvailableCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { cmd in
                Button {
                    onPick(cmd)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("/\(cmd.name)")
                                .scaledFont(size: 13)
                                .fontDesign(.monospaced)
                                .foregroundColor(.primary)
                            if let hint = cmd.inputHint, !hint.isEmpty {
                                Text(hint)
                                    .scaledFont(size: 11)
                                    .fontDesign(.monospaced)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if !cmd.description.isEmpty {
                            Text(cmd.description)
                                .scaledFont(size: 11)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if cmd.id != commands.last?.id {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
    }
}

extension View {
    /// Attach the slash-command popover to a chat input. The binding is the
    /// editor's current text; the popover shows whenever the text starts
    /// with `/` and the agent has advertised matching commands.
    func slashCommandPopover(_ text: Binding<String>) -> some View {
        modifier(SlashCommandPopover(text: text))
    }
}

// MARK: - Copy Conversation Button

/// Button in the header that copies the entire conversation.
struct CopyConversationButton: View {
    let chatHistory: [FloatingChatExchange]
    let userInput: String
    let currentMessage: ChatMessage?

    @State private var showCopied = false

    var body: some View {
        Button(action: copyAll) {
            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                .scaledFont(size: 11)
                .foregroundColor(showCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .floatingHint(showCopied ? "Copied!" : "Copy all")
    }

    private func copyAll() {
        var parts: [String] = []

        for exchange in chatHistory {
            if !exchange.question.isEmpty {
                parts.append("Q: \(exchange.question)")
            }
            if !exchange.aiMessage.text.isEmpty {
                parts.append("A: \(exchange.aiMessage.text)")
            }
        }

        if !userInput.isEmpty {
            parts.append("Q: \(userInput)")
        }
        if let msg = currentMessage, !msg.text.isEmpty {
            parts.append("A: \(msg.text)")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)

        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

// MARK: - Report Issue Button

/// Icon-only button that opens the Report Issue dialog.
/// Flashes orange when the AI appears to be hanging (isHanging == true).
struct ReportIssueButton: View {
    let isHanging: Bool

    @State private var flashOpacity: Double = 1.0
    @State private var flashScale: Double = 1.0
    @State private var showSent = false
    @Environment(\.fazmWindowIsVisible) private var windowIsVisible

    var body: some View {
        Button(action: sendReport) {
            Image(systemName: showSent ? "checkmark" : "exclamationmark.triangle.fill")
                .scaledFont(size: isHanging ? 13 : 11)
                .foregroundColor(showSent ? .green : (isHanging ? .orange : .secondary))
                .opacity(flashOpacity)
                .scaleEffect(flashScale)
                .shadow(color: isHanging ? .orange.opacity(flashOpacity * 0.9) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .floatingHint(showSent ? "Report sent!" : "Report an issue")
        .onChange(of: isHanging) { _, _ in syncFlash() }
        .onChange(of: windowIsVisible) { _, _ in syncFlash() }
    }

    /// Starts/stops the orange flash animation. Only runs the repeatForever
    /// pulse while the host window is on screen — otherwise SwiftUI keeps the
    /// display cycle alive every frame and burns CPU re-rendering the chat.
    private func syncFlash() {
        if isHanging && windowIsVisible {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                flashOpacity = 0.05
                flashScale = 1.15
            }
        } else {
            withAnimation(.default) {
                flashOpacity = 1.0
                flashScale = 1.0
            }
        }
    }

    private func sendReport() {
        guard !showSent else { return }
        FeedbackWindow.sendSilently()
        withAnimation { showSent = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSent = false }
        }
    }
}

// MARK: - Model Menu Helper

class ModelMenuTarget: NSObject {
    static let shared = ModelMenuTarget()
    var onSelect: ((String) -> Void)?

    @objc func selectModel(_ sender: NSMenuItem) {
        if let modelId = sender.representedObject as? String {
            onSelect?(modelId)
        }
    }
}

// MARK: - Floating Hint (custom tooltip)

/// Shows a small floating label below the view after a short hover delay.
/// Used instead of SwiftUI's `.help()` because native tooltips don't fire
/// reliably on borderless floating panels.
private struct FloatingHintModifier: ViewModifier {
    let label: String
    @State private var isHovered = false
    @State private var isVisible = false
    @State private var showTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovered = hovering
                showTask?.cancel()
                if hovering {
                    showTask = Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if !Task.isCancelled && isHovered {
                            withAnimation(.easeOut(duration: 0.12)) {
                                isVisible = true
                            }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.10)) {
                        isVisible = false
                    }
                }
            }
            .overlay(alignment: .top) {
                if isVisible {
                    Text(label)
                        .scaledFont(size: 10)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.85))
                        )
                        .fixedSize()
                        .allowsHitTesting(false)
                        // Place the hint below the button: shift down by the
                        // button's height plus a small gap. Overlay is inside
                        // the response view's rounded clip, so drawing below
                        // the tiny header row avoids the top-edge clip entirely.
                        .offset(y: 18)
                        .transition(.opacity)
                        .zIndex(1000)
                }
            }
    }
}

extension View {
    /// Shows a small floating label below the view on hover.
    func floatingHint(_ label: String) -> some View {
        modifier(FloatingHintModifier(label: label))
    }
}

// MARK: - Sticky Stacked User Bubbles

/// One user-question bubble's geometry, collected via PreferenceKey from the chat list.
/// `topY` and `height` are in the named "chatScroll" coordinate space — values are stable
/// while content layout doesn't change, regardless of scroll offset.
struct StackedBubbleInfo: Equatable {
    let id: UUID
    let question: String
    let topY: CGFloat
    let height: CGFloat
}

private struct StackedBubblesPreferenceKey: PreferenceKey {
    static var defaultValue: [StackedBubbleInfo] = []
    static func reduce(value: inout [StackedBubbleInfo], nextValue: () -> [StackedBubbleInfo]) {
        value.append(contentsOf: nextValue())
    }
}

/// Visible scroll viewport bounds in document coordinates.
struct ScrollBoundsInfo: Equatable {
    var offsetY: CGFloat
    var viewportHeight: CGFloat
}

/// Reads the enclosing NSScrollView's clip-view bounds and reports offset + height.
/// Same pattern as `ScrollPositionDetector` — must be placed inside the ScrollView content.
struct ScrollBoundsObserver: NSViewRepresentable {
    let onChange: (ScrollBoundsInfo) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    class Coordinator: NSObject {
        let onChange: (ScrollBoundsInfo) -> Void
        private weak var scrollView: NSScrollView?
        private var boundsObs: NSObjectProtocol?
        private var frameObs: NSObjectProtocol?
        private var lastInfo: ScrollBoundsInfo?

        init(onChange: @escaping (ScrollBoundsInfo) -> Void) {
            self.onChange = onChange
        }

        func attach(to view: NSView) {
            var current: NSView? = view
            while let v = current {
                if let sv = v as? NSScrollView { scrollView = sv; break }
                current = v.superview
            }
            guard let sv = scrollView else { return }
            sv.contentView.postsBoundsChangedNotifications = true
            sv.contentView.postsFrameChangedNotifications = true
            boundsObs = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: sv.contentView, queue: .main
            ) { [weak self] _ in self?.report() }
            frameObs = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: sv.contentView, queue: .main
            ) { [weak self] _ in self?.report() }
            report()
        }

        func report() {
            guard let sv = scrollView else { return }
            let bounds = sv.contentView.bounds
            let info = ScrollBoundsInfo(offsetY: bounds.origin.y, viewportHeight: bounds.height)
            guard info != lastInfo else { return }
            lastInfo = info
            onChange(info)
        }

        deinit {
            if let o = boundsObs { NotificationCenter.default.removeObserver(o) }
            if let o = frameObs { NotificationCenter.default.removeObserver(o) }
        }
    }
}

/// Single peek tab in the stacked overlay — shows the top line of a user question
/// with the same gray pill styling as the inline bubble.
struct StackedBubblePeek: View {
    let question: String
    let height: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Text(question)
            .scaledFont(size: 13)
            .foregroundColor(FazmColors.overlayForeground)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: height, alignment: .center)
            .background(
                FazmColors.overlayForeground.opacity(isHovered ? 0.18 : 0.12)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onTap)
            .help("Jump back to this message")
    }
}

/// Top-aligned overlay that pins user-question bubbles as the user scrolls past them.
/// Capped at 20% of the viewport height; on overflow, the oldest bubble drops (FIFO).
/// A small toggle button in the top-right collapses the stack to a single chip so the
/// user can hide past prompts entirely; tapping the chip restores the stack.
/// The background is fully opaque so chat content scrolls cleanly underneath without
/// bleeding through the peek pills; a soft fade just below the stack acts as a visual
/// separator from the live scroll content.
struct StackedBubblesOverlay: View {
    let bubbles: [StackedBubbleInfo]
    let peekHeight: CGFloat
    @Binding var isHidden: Bool
    let onTap: (UUID) -> Void

    var body: some View {
        if bubbles.isEmpty {
            EmptyView()
        } else if isHidden {
            // Collapsed: single chip in the top-right that restores the stack.
            HStack {
                Spacer()
                StackToggleButton(
                    isHidden: true,
                    count: bubbles.count,
                    action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isHidden = false
                        }
                    }
                )
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .transition(.opacity)
        } else {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 2) {
                    ForEach(bubbles, id: \.id) { bubble in
                        StackedBubblePeek(
                            question: bubble.question,
                            height: peekHeight,
                            onTap: { onTap(bubble.id) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 28) // leave space for hide button
                .padding(.top, 4)
                .padding(.bottom, 4)

                StackToggleButton(
                    isHidden: false,
                    count: bubbles.count,
                    action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isHidden = true
                        }
                    }
                )
                .padding(.trailing, 6)
                .padding(.top, 4)
            }
            .background(FazmColors.backgroundPrimary)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        FazmColors.backgroundPrimary,
                        FazmColors.backgroundPrimary.opacity(0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 10)
                .offset(y: 10)
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.18), value: bubbles.map { $0.id })
        }
    }
}

/// Compact toggle that collapses or restores the stacked past-prompts overlay.
/// When hidden, shows a chevron-down + count; when shown, shows a chevron-up.
private struct StackToggleButton: View {
    let isHidden: Bool
    let count: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isHidden ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                if isHidden {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundColor(FazmColors.overlayForeground.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(
                FazmColors.overlayForeground.opacity(isHovered ? 0.22 : 0.14)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isHidden ? "Show past prompts (\(count))" : "Hide past prompts")
    }
}

// MARK: - Scroll Position Detection

/// Detects whether the enclosing NSScrollView is scrolled to the bottom.
/// Must be placed as `.background()` on a view INSIDE the ScrollView content
/// so the NSView's superview chain includes the NSScrollView.
private struct ScrollPositionDetector: NSViewRepresentable {
    let onScrollPositionChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Delay to ensure the scroll view hierarchy is fully assembled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.coordinator.setupScrollObserver(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollPositionChange: onScrollPositionChange)
    }

    class Coordinator: NSObject {
        let onScrollPositionChange: (Bool) -> Void
        private var scrollView: NSScrollView?
        private var observation: NSObjectProtocol?
        private var coalesceWorkItem: DispatchWorkItem?
        private var lastReportedValue: Bool?

        init(onScrollPositionChange: @escaping (Bool) -> Void) {
            self.onScrollPositionChange = onScrollPositionChange
        }

        func setupScrollObserver(for view: NSView) {
            var current: NSView? = view
            while let v = current {
                if let sv = v as? NSScrollView {
                    scrollView = sv
                    break
                }
                current = v.superview
            }
            guard let scrollView = scrollView else { return }

            scrollView.contentView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.checkScrollPosition()
            }
            checkScrollPosition()
        }

        func checkScrollPosition() {
            guard let sv = scrollView, let docView = sv.documentView else { return }
            let clipBounds = sv.contentView.bounds
            let documentHeight = docView.frame.height
            let visibleMaxY = clipBounds.origin.y + clipBounds.height
            let threshold: CGFloat = 80
            let atBottom = visibleMaxY >= documentHeight - threshold

            guard atBottom != lastReportedValue else { return }
            coalesceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.lastReportedValue = atBottom
                self?.onScrollPositionChange(atBottom)
            }
            coalesceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }

        deinit {
            coalesceWorkItem?.cancel()
            if let obs = observation {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }
}
