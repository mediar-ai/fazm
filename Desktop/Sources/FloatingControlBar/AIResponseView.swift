import SwiftUI

/// Streaming markdown response view for the floating control bar.
struct AIResponseView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @ObservedObject private var shortcutSettings = ShortcutSettings.shared
    @Binding var isLoading: Bool
    let currentMessage: ChatMessage?
    @State private var isQuestionExpanded = false
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
    var onSendFollowUp: ((String, [ChatAttachment]) -> Void)?
    var onEnqueueMessage: ((String) -> Void)?
    var onSendNow: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?
    var onStopAgent: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onChatObserverCardAction: ((Int64, String) -> Void)?
    var onChangeWorkspace: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.isTutorialChatActive {
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

                            // Anchor for explicit scroll-to-bottom calls (new exchanges, etc.)
                            Color.clear.frame(height: 1).id("bottom")
                        }
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
                    }
                    // Pin scroll to the bottom of content. When content grows or
                    // reflows (markdown re-layout during streaming), SwiftUI keeps
                    // the bottom edge of the content fixed to the bottom of the
                    // viewport in the same layout transaction — no scrollTo races,
                    // no scrollbar thumb jumping. If the user scrolls up manually,
                    // their offset-from-bottom stays stable, so they aren't yanked.
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: chatHistory.count) {
                        shouldFollowContent = true
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: state.pendingChatObserverExchanges.count) {
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

            if !isLoading && !suggestedReplies.isEmpty {
                suggestedRepliesView
            }

            if !state.messageQueue.isEmpty {
                MessageQueueView(
                    queue: Binding(
                        get: { state.messageQueue },
                        set: { state.messageQueue = $0 }
                    ),
                    onSendNow: { item in onSendNow?(item) },
                    onDelete: { item in onDeleteQueued?(item) },
                    onClearAll: { onClearQueue?() },
                    onReorder: { source, dest in onReorderQueue?(source, dest) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.messageQueue.count)
            }

            // Chat observer thinking indicator — only when no cards have arrived yet
            if state.isChatObserverRunning && !hasAnyChatObserverCards {
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
            } else {
                loadingHideTask?.cancel()
                loadingHideTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { debouncedIsLoading = false }
                }
            }

            if isLoading {
                hangTask?.cancel()
                hangTask = Task { [onStopAgent] in
                    // If no streaming data arrives within 60s, the query is failing silently
                    // (e.g. credit exhaustion, bridge crash, backend unreachable).
                    // Stop the bridge so sendMessage() returns and error handling kicks in.
                    // But don't trigger if tool calls are actively running — those can
                    // legitimately take minutes (e.g. Terminal commands).
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    let blocks = await MainActor.run { currentMessage?.contentBlocks ?? [] }
                    let hasRunningTools = blocks.contains(where: {
                        if case .toolCall(_, _, .running, _, _, _) = $0 { return true }
                        return false
                    })
                    let hasAnyToolCalls = blocks.contains(where: {
                        if case .toolCall = $0 { return true }
                        return false
                    })
                    if hasRunningTools {
                        // Tools are still running — don't flag as hanging.
                        // Re-check every 30s in case tools finish but model stops responding.
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            guard !Task.isCancelled else { return }
                            let stillRunning = await MainActor.run {
                                currentMessage?.contentBlocks.contains(where: {
                                    if case .toolCall(_, _, .running, _, _, _) = $0 { return true }
                                    return false
                                }) ?? false
                            }
                            if !stillRunning { break }
                        }
                        // Tools finished — give the model 60s more to respond
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { return }
                    } else if hasAnyToolCalls {
                        // Tools completed but none are currently running — the model is
                        // processing tool results. This commonly happens when tools finish
                        // right around the 60s mark. Give 60s grace for the model to respond.
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { return }
                    }
                    isHanging = true
                    await MainActor.run {
                        onStopAgent?()
                    }
                }
            } else {
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
    @State private var showWorkspaceChangeConfirmation = false
    @State private var showWorkspaceInfo = false

    /// The effective workspace for this view: per-window state if set, otherwise global default.
    private var aiChatWorkingDirectory: String {
        state.workspaceDirectory.isEmpty ? globalWorkspaceDirectory : state.workspaceDirectory
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
            if state.isCompacting {
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
                    Text(hasRunningTools ? "using tools" : "thinking")
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

            ModelToggleButton(localModel: localModel)

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

            if let onNewChat {
                NewChatButton(action: onNewChat)
            }
        }
    }

    @ViewBuilder
    private var workspaceLabel: some View {
        if onChangeWorkspace != nil {
            HStack(spacing: 6) {
                if isHomeDirectory {
                    Button(action: { onChangeWorkspace?() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.rectangle.on.folder.fill")
                                .scaledFont(size: 10)
                            Text("Create project")
                                .scaledFont(size: 14)
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { showWorkspaceChangeConfirmation = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .scaledFont(size: 10)
                            Text((aiChatWorkingDirectory as NSString).lastPathComponent)
                                .scaledFont(size: 14)
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(aiChatWorkingDirectory)
                    .alert("Change Workspace?", isPresented: $showWorkspaceChangeConfirmation) {
                        Button("Change", role: .destructive) {
                            onChangeWorkspace?()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Changing the workspace will start a new session. Current conversation will be preserved in history.")
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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                connectClaudePulse = true
            }
        }
        .transition(.scale.combined(with: .opacity))
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
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                upgradePulse = true
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Tutorial Banner

    private var tutorialBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .scaledFont(size: 11)
            Text("Getting Started — Step \(min(state.tutorialChatStep + 1, state.tutorialPrompts.count)) of \(state.tutorialPrompts.count)")
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
                    isChatObserverRunning: state.isChatObserverRunning,
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
        for i in state.chatHistory.indices {
            for j in state.chatHistory[i].aiMessage.contentBlocks.indices {
                if case .observerCard(let id, let aId, let type, let content, let buttons, _) = state.chatHistory[i].aiMessage.contentBlocks[j],
                   aId == activityId {
                    state.chatHistory[i].aiMessage.contentBlocks[j] = .observerCard(id: id, activityId: aId, type: type, content: content, buttons: buttons, actedAction: action)
                    return
                }
            }
        }
        // Also check pending chat observer exchanges
        for i in state.pendingChatObserverExchanges.indices {
            for j in state.pendingChatObserverExchanges[i].aiMessage.contentBlocks.indices {
                if case .observerCard(let id, let aId, let type, let content, let buttons, _) = state.pendingChatObserverExchanges[i].aiMessage.contentBlocks[j],
                   aId == activityId {
                    state.pendingChatObserverExchanges[i].aiMessage.contentBlocks[j] = .observerCard(id: id, activityId: aId, type: type, content: content, buttons: buttons, actedAction: action)
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
        let cards = extractChatObserverCards(from: state.pendingChatObserverExchanges)
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
                ExpandableQuestionBubble(question: exchange.question)
            }

            // Response with content blocks
            if !exchange.aiMessage.contentBlocks.isEmpty || !exchange.aiMessage.text.isEmpty {
                MessageWithCopyButton(alignment: .topTrailing) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exchange.aiMessage.text, forType: .string)
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
                userInput: userInput
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FazmColors.overlayForeground.opacity(0.1))
        .cornerRadius(8)
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
                    NSPasteboard.general.setString(message.text, forType: .string)
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
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isVoiceFollowUp)

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

        let pendingHas = state.pendingChatObserverExchanges.contains(where: { exchange in
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
                .foregroundColor(FazmColors.purplePrimary.opacity(chatObserverPulseOpacity))
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: chatObserverPulseOpacity)
                .onAppear { chatObserverPulseOpacity = 0.3 }

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
        !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.pendingAttachments.isEmpty
    }

    private var followUpInputView: some View {
        VStack(spacing: 0) {
            // Attachment thumbnails strip
            if !state.pendingAttachments.isEmpty {
                ChatAttachmentStrip(attachments: $state.pendingAttachments)
            }

            HStack(alignment: .center, spacing: 6) {
                ChatAttachmentButton {
                    ChatAttachmentHelper.openFilePicker { urls in
                        ChatAttachmentHelper.addFiles(from: urls, to: &state.pendingAttachments)
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
                            ChatAttachmentHelper.addFiles(from: urls, to: &state.pendingAttachments)
                        },
                        onPasteImageData: { data in
                            ChatAttachmentHelper.addPastedImage(data, to: &state.pendingAttachments)
                        },
                        minHeight: 34,
                        maxHeight: 120,
                        onHeightChange: { newHeight in
                            if abs(followUpTextHeight - newHeight) > 1 {
                                followUpTextHeight = newHeight
                            }
                        }
                    )
                    .onChange(of: state.pendingFollowUpText) {
                        if !state.pendingFollowUpText.isEmpty {
                            if followUpText.isEmpty {
                                followUpText = state.pendingFollowUpText
                            } else {
                                followUpText += " " + state.pendingFollowUpText
                            }
                            state.pendingFollowUpText = ""
                        }
                    }
                    .onChange(of: state.isVoiceListening) {
                        if state.isVoiceListening {
                            preVoiceFollowUpText = followUpText
                        }
                    }
                    .onChange(of: state.aiInputText) {
                        if state.isVoiceListening && !state.aiInputText.isEmpty && state.aiInputText != followUpText {
                            if preVoiceFollowUpText.isEmpty {
                                followUpText = state.aiInputText
                            } else {
                                followUpText = preVoiceFollowUpText + " " + state.aiInputText
                            }
                        }
                    }
                }
                .frame(height: followUpTextHeight)
                .background(FazmColors.overlayForeground.opacity(0.1))
                .cornerRadius(8)

                PushToTalkButton(isListening: state.isVoiceListening, iconSize: 16, frameSize: 24)

                if (isLoading || currentMessage?.isStreaming == true) && !followUpHasInput {
                    Button(action: {
                        isStopping = true
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
        let attachmentsToSend = state.pendingAttachments
        guard !trimmed.isEmpty || !attachmentsToSend.isEmpty else { return }
        followUpText = ""
        state.pendingAttachments = []

        if isLoading && isThisSessionStreaming {
            // THIS window is actively streaming a response — queue the message (text only)
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
private struct ExpandableQuestionBubble: View {
    let question: String
    @State private var isExpanded = false

    private var needsExpansion: Bool {
        let font = NSFont.systemFont(ofSize: 13)
        return (question as NSString).boundingRect(
            with: NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: [.font: font]
        ).size.height > font.pointSize * 1.5 * 2 // more than 2 lines
    }

    var body: some View {
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
                userInput: question
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FazmColors.overlayForeground.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Question Bar Buttons (copy + expand, inline)

/// Inline buttons for the question bar — copy and expand sit side by side to avoid overlap.
private struct QuestionBarButtons: View {
    let needsExpansion: Bool
    @Binding var isExpanded: Bool
    let userInput: String

    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(userInput, forType: .string)
                showCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    showCopied = false
                }
            }) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .scaledFont(size: 10)
                    .foregroundColor(showCopied ? .green : .secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || showCopied ? 1 : 0)

            if needsExpansion {
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 10)
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { isHovered = $0 }
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
    /// When provided, reads and writes model selection to this binding instead of the global setting.
    var localModel: Binding<String>?

    private var selectedModelId: String {
        localModel?.wrappedValue ?? shortcutSettings.selectedModel
    }

    private var selectedModelShortLabel: String {
        ShortcutSettings.availableModels.first(where: { $0.id == selectedModelId })?.shortLabel ?? "Smart"
    }

    var body: some View {
        Menu {
            ForEach(ShortcutSettings.availableModels, id: \.id) { model in
                Button {
                    if let localModel {
                        localModel.wrappedValue = model.id
                    } else {
                        shortcutSettings.selectedModel = model.id
                    }
                } label: {
                    if selectedModelId == model.id {
                        Label(model.label, systemImage: "checkmark")
                    } else {
                        Text(model.label)
                    }
                }
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
        .onChange(of: isHanging) {
            if isHanging {
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
