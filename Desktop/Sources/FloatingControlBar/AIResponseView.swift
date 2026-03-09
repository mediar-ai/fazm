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
    @State private var followUpTextHeight: CGFloat = 36

    let userInput: String
    let chatHistory: [FloatingChatExchange]
    @Binding var isVoiceFollowUp: Bool
    @Binding var voiceFollowUpTranscript: String
    @Binding var suggestedReplies: [String]

    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onSendFollowUp: ((String) -> Void)?
    var onStopAgent: (() -> Void)?

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

                        // Current question (hidden when empty, e.g. tutorial guide messages)
                        if !userInput.isEmpty {
                            questionBar
                        }

                        // Current response
                        currentContentView

                        // Voice follow-up indicator (shown inline when PTT is active during conversation)
                        if isVoiceFollowUp {
                            voiceFollowUpView
                                .id("voiceFollowUp")
                        }

                        // Anchor for auto-scroll
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .background(
                        GeometryReader { geo -> Color in
                            let h = geo.size.height.rounded()
                            // Use a generous threshold to avoid feedback loops
                            // where resize → relayout → new height → resize (macOS 26 crash).
                            if abs(state.responseContentHeight - h) > 4 {
                                DispatchQueue.main.async { [weak state] in
                                    state?.responseContentHeight = h
                                }
                            }
                            return Color.clear
                        }
                    )
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            userHasScrolledUp = true
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

            if !isVoiceFollowUp {
                followUpInputView
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            onClose?()
        }
        .onChange(of: isLoading) {
            if isLoading {
                userHasScrolledUp = false
            }
        }
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
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("thinking")
                    .scaledFont(size: 14)
                    .foregroundColor(.secondary)
            } else {
                Text("Fazm says")
                    .scaledFont(size: 14)
                    .foregroundColor(.secondary)
            }

            Spacer()

            CopyConversationButton(
                chatHistory: chatHistory,
                userInput: userInput,
                currentMessage: currentMessage
            )

            if let onNewChat {
                Button(action: onNewChat) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("New chat")
                            .scaledFont(size: 11)
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
            }
        }
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
                }
            }
        } else if !message.text.isEmpty {
            SelectableMarkdown(text: message.text, sender: .ai)
                .environment(\.colorScheme, .dark)
                .environment(\.compactCodeBlocks, true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Chat History

    private func chatExchangeView(_ exchange: FloatingChatExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Question bubble
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

            // Response with content blocks
            MessageWithCopyButton(alignment: .topTrailing) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.aiMessage.text, forType: .string)
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    contentBlocksView(for: exchange.aiMessage)
                }
                .padding(.horizontal, 4)
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
                    Text("Ask follow up...")
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
                Button(action: { onStopAgent?() }) {
                    Image(systemName: "stop.circle.fill")
                        .scaledFont(size: 20)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
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

    private func sendFollowUp() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        followUpText = ""
        userHasScrolledUp = false
        onSendFollowUp?(trimmed)
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

// MARK: - Copy Conversation Button

/// Button in the header that copies the entire conversation.
struct CopyConversationButton: View {
    let chatHistory: [FloatingChatExchange]
    let userInput: String
    let currentMessage: ChatMessage?

    @State private var showCopied = false

    var body: some View {
        Button(action: copyAll) {
            HStack(spacing: 4) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                Text(showCopied ? "Copied" : "Copy all")
                    .scaledFont(size: 11)
            }
            .foregroundColor(showCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func copyAll() {
        var parts: [String] = []

        for exchange in chatHistory {
            parts.append("Q: \(exchange.question)")
            parts.append("A: \(exchange.aiMessage.text)")
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
