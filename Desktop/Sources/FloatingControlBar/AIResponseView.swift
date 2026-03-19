import SwiftUI

/// Streaming markdown response view for the floating control bar.
struct AIResponseView: View {
    @EnvironmentObject var state: FloatingControlBarState
    @Binding var isLoading: Bool
    let currentMessage: ChatMessage?
    @State private var isQuestionExpanded = false
    @State private var followUpText: String = ""
    @State private var preVoiceFollowUpText: String = ""
    @State private var userHasScrolledUp: Bool = false
    @State private var isAtBottom: Bool = true
    @State private var followUpTextHeight: CGFloat = 36
    @State private var isHanging = false
    @State private var hangTask: Task<Void, Never>?
    @State private var isStopping = false
    /// True when the hang state was triggered by a previous crash, not the 30s timer.
    /// Prevents the isLoading onChange from clearing it when a query completes.
    @State private var isHangingFromCrash = false

    let userInput: String
    let chatHistory: [FloatingChatExchange]
    @Binding var isVoiceFollowUp: Bool
    @Binding var voiceFollowUpTranscript: String
    @Binding var suggestedReplies: [String]

    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onSendFollowUp: ((String) -> Void)?
    var onEnqueueMessage: ((String) -> Void)?
    var onSendNow: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?
    var onStopAgent: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onObserverCardAction: ((Int64, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.isTutorialChatActive {
                tutorialBanner
            }

            headerView
                .fixedSize(horizontal: false, vertical: true)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Previous chat exchanges
                        ForEach(chatHistory) { exchange in
                            chatExchangeView(exchange)
                        }

                        // Current question (hidden when empty, e.g. tutorial guide messages or history-only mode)
                        if !userInput.isEmpty {
                            questionBar
                        }

                        // Current response (hidden when just showing history with no active query)
                        if !userInput.isEmpty || currentMessage != nil {
                            currentContentView
                        }

                        // Observer cards that arrived while the current query was streaming
                        ForEach(state.pendingObserverExchanges) { exchange in
                            chatExchangeView(exchange)
                        }

                        // Voice follow-up indicator (shown inline when PTT is active during conversation)
                        if isVoiceFollowUp {
                            voiceFollowUpView
                                .id("voiceFollowUp")
                        }

                        // Anchor for auto-scroll
                        Color.clear.frame(height: 1).id("bottom")
                            .background(
                                GeometryReader { geo -> Color in
                                    let bottomY = geo.frame(in: .named("chatScroll")).maxY
                                    let scrollHeight = geo.frame(in: .named("chatScroll")).height
                                    // Consider "at bottom" if the anchor is within 60pt of the visible area bottom
                                    let atBottom = bottomY >= 0 && bottomY <= scrollHeight + 60
                                    if atBottom != isAtBottom {
                                        DispatchQueue.main.async {
                                            isAtBottom = atBottom
                                            if atBottom {
                                                userHasScrolledUp = false
                                            }
                                        }
                                    }
                                    return Color.clear
                                }
                            )
                    }
                    .background(
                        GeometryReader { geo -> Color in
                            let h = geo.size.height.rounded()
                            // Use a generous threshold to avoid feedback loops
                            // where resize → relayout → new height → resize (macOS 26 crash).
                            if abs(state.responseContentHeight - h) > 8 {
                                DispatchQueue.main.async { [weak state] in
                                    state?.responseContentHeight = h
                                }
                            }
                            return Color.clear
                        }
                    )
                }
                .coordinateSpace(name: "chatScroll")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            if !isAtBottom {
                                userHasScrolledUp = true
                            }
                        }
                )
                .onChange(of: currentMessage?.text) {
                    if !userHasScrolledUp {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: currentMessage?.contentBlocks.count) {
                    if !userHasScrolledUp {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: chatHistory.count) {
                    // New exchange added — always scroll to bottom and reset
                    userHasScrolledUp = false
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: state.pendingObserverExchanges.count) {
                    // Observer card arrived — scroll to show it
                    if !userHasScrolledUp {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isLoading) {
                    // When loading finishes, flush any pending observer cards into chat history
                    if !isLoading {
                        state.flushPendingObserverExchanges()
                    }
                }
                .onChange(of: isVoiceFollowUp) {
                    if isVoiceFollowUp {
                        userHasScrolledUp = false
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("voiceFollowUp", anchor: .bottom)
                        }
                    }
                }
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
            if isLoading {
                userHasScrolledUp = false
                hangTask?.cancel()
                hangTask = Task { [onStopAgent] in
                    // If no streaming data arrives within 60s, the query is failing silently
                    // (e.g. credit exhaustion, bridge crash, backend unreachable).
                    // Stop the bridge so sendMessage() returns and error handling kicks in.
                    // But don't trigger if tool calls are actively running — those can
                    // legitimately take minutes (e.g. Terminal commands).
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    let hasRunningTools = currentMessage?.contentBlocks.contains(where: {
                        if case .toolCall(_, _, .running, _, _, _) = $0 { return true }
                        return false
                    }) ?? false
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

    @State private var connectClaudePulse = false

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
                        .font(.system(size: 12))
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
            } else if userInput.isEmpty && currentMessage == nil {
                Text("conversation")
                    .scaledFont(size: 14)
                    .foregroundColor(.secondary)
            } else {
                Text("Fazm says")
                    .scaledFont(size: 14)
                    .foregroundColor(.secondary)
            }

            if state.showConnectClaudeButton {
                connectClaudeButton
            }

            Spacer()

            ReportIssueButton(isHanging: isHanging)

            CopyConversationButton(
                chatHistory: chatHistory,
                userInput: userInput,
                currentMessage: currentMessage
            )

            if let onNewChat {
                NewChatButton(action: onNewChat)
            }
        }
    }

    private var connectClaudeButton: some View {
        Button(action: { onConnectClaude?() }) {
            HStack(spacing: 5) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 10))
                Text("Connect Claude")
                    .scaledFont(size: 11, weight: .medium)
            }
            .foregroundColor(.white)
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

    // MARK: - Tutorial Banner

    private var tutorialBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 11))
            Text("Getting Started — Test \(min(state.tutorialChatStep + 1, state.tutorialPrompts.count))/\(state.tutorialPrompts.count)")
                .scaledFont(size: 11, weight: .medium)
            Spacer()
            Button("Skip") {
                TutorialChatGuide.shared.finish(barState: state)
            }
            .buttonStyle(.plain)
            .scaledFont(size: 11)
            .foregroundColor(.white.opacity(0.6))
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
            ForEach(grouped) { group in
                switch group {
                case .text(_, let text):
                    SelectableMarkdown(text: text, sender: .ai)
                        .environment(\.colorScheme, .dark)
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
                case .observerCard(_, let activityId, let type, let content, let buttons):
                    ObserverCardView(
                        activityId: activityId,
                        type: type,
                        content: content,
                        buttons: buttons,
                        onAction: { id, action in
                            handleObserverCardAction(activityId: id, action: action)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if !message.text.isEmpty {
            SelectableMarkdown(text: message.text, sender: .ai)
                .environment(\.colorScheme, .dark)
                .environment(\.compactCodeBlocks, true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func handleObserverCardAction(activityId: Int64, action: String) {
        onObserverCardAction?(activityId, action)
    }

    // MARK: - Chat History

    private func chatExchangeView(_ exchange: FloatingChatExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Question bubble (hidden for observer-only entries with no user question)
            if !exchange.question.isEmpty {
                MessageWithCopyButton(alignment: .topTrailing) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exchange.question, forType: .string)
                } content: {
                    Text(exchange.question)
                        .scaledFont(size: 13)
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }
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
                .background(Color.white.opacity(0.1))
        }
    }

    // MARK: - Current Question & Response

    private var questionBar: some View {
        MessageWithCopyButton(alignment: .topTrailing) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(userInput, forType: .string)
        } content: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if isQuestionExpanded {
                        ScrollView {
                            Text(userInput)
                                .scaledFont(size: 13)
                                .foregroundColor(.white)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    } else {
                        Text(userInput)
                            .scaledFont(size: 13)
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if needsExpansion {
                    Button(action: { isQuestionExpanded.toggle() }) {
                        Image(systemName: isQuestionExpanded ? "chevron.up" : "chevron.down")
                            .scaledFont(size: 10)
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
        }
    }

    private var needsExpansion: Bool {
        let font = NSFont.systemFont(ofSize: 13)
        let attributes = [NSAttributedString.Key.font: font]
        let size = (userInput as NSString).boundingRect(
            with: NSSize(width: 350, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: attributes
        ).size
        return size.height > font.pointSize * 1.5
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

                        // Show typing indicator while AI is still generating
                        if isLoading || message.isStreaming {
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
                .foregroundColor(.white)

            if !voiceFollowUpTranscript.isEmpty {
                Text(voiceFollowUpTranscript)
                    .scaledFont(size: 13)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(2)
                    .truncationMode(.head)
            } else {
                Text("Listening...")
                    .scaledFont(size: 13)
                    .foregroundColor(.white.opacity(0.5))
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestedReplies, id: \.self) { reply in
                    Button(action: {
                        suggestedReplies = []
                        onSendFollowUp?(reply)
                    }) {
                        Text(reply)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Follow-Up Input

    private var followUpInputView: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if followUpText.isEmpty {
                    Text(isAgentBusy ? "Type next question (queued)..." : "Ask follow up...")
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
                    minHeight: 36,
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
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)

            if (isLoading || currentMessage?.isStreaming == true) && followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                            followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? .secondary : .white
                        )
                }
                .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.plain)
            }
        }
    }

    private var isAgentBusy: Bool {
        isLoading || currentMessage?.isStreaming == true
    }

    private func sendFollowUp() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        followUpText = ""

        if isAgentBusy {
            // Agent is busy — queue the message instead of interrupting
            onEnqueueMessage?(trimmed)
        } else {
            userHasScrolledUp = false
            onSendFollowUp?(trimmed)
        }
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

            if isHovered || showCopied {
                Button(action: {
                    onCopy()
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        showCopied = false
                    }
                }) {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(showCopied ? .green : .secondary)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .padding(4)
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - New Chat Button

struct NewChatButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                if isHovered {
                    Text("New chat")
                        .scaledFont(size: 11)
                        .transition(.opacity)
                }
                Text("⌘N")
                    .scaledFont(size: 9)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(3)
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Copy Conversation Button

/// Button in the header that copies the entire conversation.
struct CopyConversationButton: View {
    let chatHistory: [FloatingChatExchange]
    let userInput: String
    let currentMessage: ChatMessage?

    @State private var showCopied = false

    @State private var isHovered = false

    var body: some View {
        Button(action: copyAll) {
            HStack(spacing: 4) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                if isHovered {
                    Text(showCopied ? "Copied!" : "Copy all")
                        .scaledFont(size: 11)
                        .transition(.opacity)
                }
            }
            .foregroundColor(showCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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
    @State private var isHovered = false

    var body: some View {
        Button(action: sendReport) {
            HStack(spacing: 4) {
                Image(systemName: showSent ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: isHanging ? 13 : 11))
                    .foregroundColor(showSent ? .green : (isHanging ? .orange : .secondary))
                    .opacity(flashOpacity)
                    .scaleEffect(flashScale)
                    .shadow(color: isHanging ? .orange.opacity(flashOpacity * 0.9) : .clear, radius: 6)
                if isHovered {
                    Text(showSent ? "Report sent!" : "Report an issue")
                        .scaledFont(size: 11)
                        .foregroundColor(showSent ? .green : (isHanging ? .orange : .secondary))
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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
