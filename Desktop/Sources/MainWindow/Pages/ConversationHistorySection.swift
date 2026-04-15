import SwiftUI
import GRDB

/// Summary of a conversation session for the history list.
struct ConversationSummary: Identifiable {
    let id: String           // taskId (context key: "__floating__", "__detached-UUID__")
    let firstMessage: String // First user message (preview)
    let lastMessageDate: Date
    let messageCount: Int
}

/// Conversation History tab: scrollable list of past conversations with "New Chat" button.
struct ConversationHistorySection: View {
    var chatProvider: ChatProvider? = nil

    @State private var conversations: [ConversationSummary] = []
    @State private var isLoading = true

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with New Chat button
            HStack {
                Spacer()
                Button(action: startNewChat) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.bubble")
                        Text("New Chat")
                    }
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(FazmColors.purplePrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            if isLoading {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Spacer()
                }
                Spacer()
            } else if conversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(conversations) { conversation in
                            ConversationRow(conversation: conversation)
                                .onTapGesture { openConversation(conversation) }
                        }
                    }
                }
            }
        }
        .onAppear { loadConversations() }
        .onReceive(refreshTimer) { _ in loadConversations() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .scaledFont(size: 28)
                        .foregroundColor(FazmColors.textQuaternary)
                    Text("No conversations yet")
                        .scaledFont(size: 14)
                        .foregroundColor(FazmColors.textQuaternary)
                    Text("Start a chat with Fazm to see your history here")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
                Spacer()
            }
            Spacer()
        }
    }

    // MARK: - Actions

    private func startNewChat() {
        if let provider = chatProvider ?? FloatingControlBarManager.shared.chatProvider {
            let sessionKey = "detached-\(UUID().uuidString)"
            DetachedChatWindowController.shared.show(
                chatHistory: [],
                displayedQuery: "",
                currentAIMessage: nil,
                isAILoading: false,
                chatProvider: provider,
                messageCountBefore: provider.messages.count,
                sessionKey: sessionKey
            )
        }
    }

    private func openConversation(_ conversation: ConversationSummary) {
        guard let provider = chatProvider ?? FloatingControlBarManager.shared.chatProvider else { return }

        Task {
            let messages = await ChatMessageStore.loadMessages(context: conversation.id, limit: 200)

            await MainActor.run {
                // Build FloatingChatExchange array from user/ai message pairs
                var exchanges: [FloatingChatExchange] = []
                var pendingQuestion: String? = nil

                for msg in messages {
                    if msg.sender == .user {
                        // If there was a previous unanswered question, create an exchange with empty response
                        if let prev = pendingQuestion {
                            let placeholder = ChatMessage(text: "", sender: .ai)
                            exchanges.append(FloatingChatExchange(question: prev, aiMessage: placeholder))
                        }
                        pendingQuestion = msg.text
                    } else if msg.sender == .ai {
                        let question = pendingQuestion ?? ""
                        exchanges.append(FloatingChatExchange(question: question, aiMessage: msg))
                        pendingQuestion = nil
                    }
                }
                // If there's a trailing user message with no response
                if let trailing = pendingQuestion {
                    let placeholder = ChatMessage(text: "", sender: .ai)
                    exchanges.append(FloatingChatExchange(question: trailing, aiMessage: placeholder))
                }

                // For floating bar conversations, create a new detached session to view them
                let sessionKey: String
                if conversation.id == "__floating__" {
                    sessionKey = "detached-\(UUID().uuidString)"
                } else {
                    // Strip __ wrappers to get the original session key
                    sessionKey = String(conversation.id.dropFirst(2).dropLast(2))
                }

                DetachedChatWindowController.shared.show(
                    chatHistory: exchanges,
                    displayedQuery: "",
                    currentAIMessage: nil,
                    isAILoading: false,
                    chatProvider: provider,
                    messageCountBefore: provider.messages.count,
                    sessionKey: sessionKey
                )
            }
        }
    }

    // MARK: - Data Loading

    private func loadConversations() {
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }

            do {
                let results = try dbQueue.read { db -> [ConversationSummary] in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT
                            cm.taskId,
                            (SELECT sub.messageText FROM chat_messages sub
                             WHERE sub.taskId = cm.taskId AND sub.sender = 'user'
                             ORDER BY sub.createdAt ASC LIMIT 1) as firstUserMessage,
                            MAX(cm.createdAt) as lastMessageDate,
                            COUNT(*) as messageCount
                        FROM chat_messages cm
                        WHERE cm.taskId NOT IN ('__onboarding__')
                        GROUP BY cm.taskId
                        HAVING messageCount > 0
                        ORDER BY lastMessageDate DESC
                    """)

                    return rows.compactMap { row -> ConversationSummary? in
                        guard let taskId = row["taskId"] as String?,
                              let lastDate = row["lastMessageDate"] as Date? else { return nil }

                        let firstMsg = (row["firstUserMessage"] as String?) ?? "New conversation"
                        let count = (row["messageCount"] as Int?) ?? 0

                        return ConversationSummary(
                            id: taskId,
                            firstMessage: firstMsg,
                            lastMessageDate: lastDate,
                            messageCount: count
                        )
                    }
                }

                await MainActor.run {
                    conversations = results
                    isLoading = false
                }
            } catch {
                logError("ConversationHistorySection: Failed to load conversations", error: error)
                await MainActor.run { isLoading = false }
            }
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ConversationSummary

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: conversation.id == "__floating__" ? "text.bubble" : "macwindow")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.purplePrimary)
                .frame(width: 24)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.firstMessage)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(FazmColors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(timeAgo(conversation.lastMessageDate))
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.textTertiary)

                    Text("\(conversation.messageCount) messages")
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.textQuaternary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .scaledFont(size: 11)
                .foregroundColor(FazmColors.textQuaternary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? FazmColors.backgroundTertiary.opacity(0.7) : FazmColors.backgroundTertiary.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}
