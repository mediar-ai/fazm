import SwiftUI
import GRDB

/// Summary of a conversation session for the history list.
struct ConversationSummary: Identifiable, Equatable {
    let id: String           // taskId (context key: "__floating__", "__detached-UUID__")
    let firstMessage: String // First user message (preview)
    let lastMessageDate: Date
    let messageCount: Int
    let acpSessionId: String? // ACP session ID for resuming
}

/// Conversation History tab: scrollable list of past conversations with a
/// "New Chat Window" button and a live count of currently open chat windows.
struct ConversationHistorySection: View {
    var chatProvider: ChatProvider? = nil
    var appState: AppState? = nil

    @ObservedObject private var shortcutSettings = ShortcutSettings.shared

    @State private var conversations: [ConversationSummary] = []
    @State private var isLoading = true
    @State private var loadingConversationId: String? = nil

    /// Live count of detached chat windows currently open. Driven by
    /// `Notification.Name.detachedChatWindowsDidChange`, which the controller
    /// posts on every open/close, so the badge updates without polling.
    @State private var openWindowCount: Int = DetachedChatWindowController.shared.openWindowCount

    // Onboarding skipped state
    @AppStorage("onboardingWasSkipped") private var onboardingWasSkipped = false

    // @State so the timer publisher initializes exactly once across the view's lifetime.
    // A `let` stored property is recreated on every parent invalidation, which produces
    // overlapping autoconnect subscriptions and storms the list with refreshes.
    @State private var refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Setup incomplete banner
            if onboardingWasSkipped {
                completeSetupBanner
                    .padding(.bottom, 16)
            }

            // Header with New Chat Window button (shortcut inside) and an open-window
            // count badge to the left, so it's clear that each click spawns another
            // window and that multiple can be open at once.
            HStack(spacing: 10) {
                Text(openWindowCount == 1
                    ? "1 chat window currently open"
                    : "\(openWindowCount) chat windows currently open")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(FazmColors.textTertiary)
                    .help(openWindowCount == 1
                        ? "1 chat window is open right now"
                        : "\(openWindowCount) chat windows are open right now")
                Spacer()
                Button(action: startNewChat) {
                    HStack(spacing: 6) {
                        Text(shortcutSettings.newPopOutChatKey.rawValue)
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.15))
                            )
                        Text("New Chat Window")
                    }
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(FazmColors.purplePrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("Opens a new chat in a separate window. You can have multiple windows open at the same time.")
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
                        ForEach(conversations, id: \.id) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isLoading: loadingConversationId == conversation.id
                            )
                            .onTapGesture {
                                guard loadingConversationId == nil else { return }
                                openConversation(conversation)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            loadConversations()
            // Sync the badge in case windows were opened/closed while this view was off-screen.
            openWindowCount = DetachedChatWindowController.shared.openWindowCount
        }
        .onReceive(refreshTimer) { _ in loadConversations() }
        .onReceive(NotificationCenter.default.publisher(for: .detachedChatWindowsDidChange)) { _ in
            openWindowCount = DetachedChatWindowController.shared.openWindowCount
        }
    }

    // MARK: - Complete Setup Banner

    private var completeSetupBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle.fill")
                .scaledFont(size: 20)
                .foregroundColor(FazmColors.purplePrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Setup incomplete")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Finish setting up Fazm to get the full experience.")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textSecondary)
            }

            Spacer()

            Button(action: {
                appState?.restartOnboarding()
            }) {
                Text("Complete Setup")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(FazmColors.purplePrimary)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.purplePrimary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FazmColors.purplePrimary.opacity(0.3), lineWidth: 1)
                )
        )
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

        loadingConversationId = conversation.id

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

                // For floating bar conversations, create a new detached session to view them.
                // Existing detached sessions already have their messages persisted.
                let sessionKey: String
                let isExistingDetached: Bool
                if conversation.id == "__floating__" {
                    sessionKey = "detached-\(UUID().uuidString)"
                    isExistingDetached = false
                } else {
                    // Strip __ wrappers to get the original session key
                    sessionKey = String(conversation.id.dropFirst(2).dropLast(2))
                    isExistingDetached = true
                }

                // Pre-populate the ACP session ID in UserDefaults so the first
                // query in this detached window can resume the original session.
                if let acpId = conversation.acpSessionId {
                    let detachedIdKey = "acpSessionId_\(sessionKey)_\(provider.bridgeMode)"
                    UserDefaults.standard.set(acpId, forKey: detachedIdKey)
                    log("ConversationHistory: Pre-populated ACP session ID \(acpId.prefix(8))... for \(sessionKey)")
                }

                DetachedChatWindowController.shared.show(
                    chatHistory: exchanges,
                    displayedQuery: "",
                    currentAIMessage: nil,
                    isAILoading: false,
                    chatProvider: provider,
                    messageCountBefore: provider.messages.count,
                    sessionKey: sessionKey,
                    skipPersist: isExistingDetached
                )

                loadingConversationId = nil
            }
        }
    }

    // MARK: - Data Loading

    private func loadConversations() {
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }

            do {
                let results = try await dbQueue.read { db -> [ConversationSummary] in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT
                            cm.taskId,
                            (SELECT sub.messageText FROM chat_messages sub
                             WHERE sub.taskId = cm.taskId AND sub.sender = 'user'
                             ORDER BY sub.createdAt ASC LIMIT 1) as firstUserMessage,
                            MAX(cm.createdAt) as lastMessageDate,
                            COUNT(*) as messageCount,
                            (SELECT sub2.session_id FROM chat_messages sub2
                             WHERE sub2.taskId = cm.taskId AND sub2.session_id IS NOT NULL AND sub2.session_id != ''
                             ORDER BY sub2.createdAt DESC LIMIT 1) as acpSessionId
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
                        let sessionId = row["acpSessionId"] as? String

                        return ConversationSummary(
                            id: taskId,
                            firstMessage: firstMsg,
                            lastMessageDate: lastDate,
                            messageCount: count,
                            acpSessionId: sessionId
                        )
                    }
                }

                await MainActor.run {
                    // Only reassign if contents differ. Otherwise the array gets a fresh
                    // identity every 10s and ForEach re-diffs the entire list, churning
                    // row closures and LazyVStack placements.
                    if conversations != results {
                        conversations = results
                    }
                    if isLoading {
                        isLoading = false
                    }
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
    var isLoading: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon (swap to spinner when loading)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
            } else {
                Image(systemName: conversation.id == "__floating__" ? "text.bubble" : "macwindow")
                    .scaledFont(size: 14)
                    .foregroundColor(FazmColors.purplePrimary)
                    .frame(width: 24)
            }

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
