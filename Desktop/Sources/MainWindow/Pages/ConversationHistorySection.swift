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

private struct ConversationSummaryPage {
    let conversations: [ConversationSummary]
    let hasMore: Bool
}

private enum ConversationLoadMode {
    case initial
    case refresh
    case more
}

/// Conversation History tab: scrollable list of past conversations with a
/// "New Chat Window" button and a live count of currently open chat windows.
struct ConversationHistorySection: View {
    private static let pageSize = 50
    private static let minimumRefreshInterval: TimeInterval = 2

    var chatProvider: ChatProvider? = nil
    var appState: AppState? = nil

    @ObservedObject private var shortcutSettings = ShortcutSettings.shared

    @State private var conversations: [ConversationSummary] = []
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var isLoadingMore = false
    @State private var hasMoreConversations = false
    @State private var loadGeneration = 0
    @State private var lastHistoryRefreshAt = Date.distantPast
    @State private var loadingConversationId: String? = nil
    @State private var pendingDelete: ConversationSummary? = nil

    /// Live count of detached chat windows currently open. Driven by
    /// `Notification.Name.detachedChatWindowsDidChange`, which the controller
    /// posts on every open/close, so the badge updates without polling.
    @State private var openWindowCount: Int = DetachedChatWindowController.shared.openWindowCount

    // Onboarding skipped state
    @AppStorage("onboardingWasSkipped") private var onboardingWasSkipped = false

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
                        if shortcutSettings.newPopOutChatShortcutEnabled {
                            Text(shortcutSettings.newPopOutChatKey.rawValue)
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundColor(.white.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.15))
                                )
                        }
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
                                isLoading: loadingConversationId == conversation.id,
                                onDelete: { pendingDelete = conversation }
                            )
                            .onTapGesture {
                                guard loadingConversationId == nil else { return }
                                openConversation(conversation)
                            }
                        }
                        if hasMoreConversations {
                            loadMoreFooter
                                .onAppear { loadMoreConversations() }
                        }
                    }
                }
            }
        }
        .onAppear {
            loadConversations(mode: conversations.isEmpty ? .initial : .refresh)
            // Sync the badge in case windows were opened/closed while this view was off-screen.
            openWindowCount = DetachedChatWindowController.shared.openWindowCount
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatMessagesDidChange)) { _ in
            refreshFromHistoryChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .detachedChatWindowsDidChange)) { _ in
            openWindowCount = DetachedChatWindowController.shared.openWindowCount
        }
        .alert("Delete this conversation?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let target = pendingDelete { deleteConversation(target) }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently removes the conversation and its messages. This can't be undone.")
        }
    }

    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            if isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading older conversations")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
            } else {
                Button(action: loadMoreConversations) {
                    Text("Load older conversations")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(FazmColors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(FazmColors.backgroundTertiary.opacity(0.6))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 10)
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
            // Claim the always-ready pre-warmed session so the first query is instant.
            let sessionKey = provider.claimWarmDetachedSession()
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

    /// Delete a conversation and all of its messages from the local DB, then
    /// drop it from the list immediately so the row disappears without waiting
    /// for the 10s refresh timer.
    private func deleteConversation(_ conversation: ConversationSummary) {
        // Optimistically remove from the visible list.
        conversations.removeAll { $0.id == conversation.id }
        hasMoreConversations = hasMoreConversations || conversations.count >= Self.pageSize

        Task {
            await ChatMessageStore.clearMessages(context: conversation.id)
            // Reload to reconcile with the DB (also fixes the list if the delete
            // failed and the row should reappear).
            loadConversations(mode: .refresh)
        }
    }

    // MARK: - Data Loading

    private func refreshFromHistoryChange() {
        let now = Date()
        guard now.timeIntervalSince(lastHistoryRefreshAt) >= Self.minimumRefreshInterval else { return }
        lastHistoryRefreshAt = now
        loadConversations(mode: conversations.isEmpty ? .initial : .refresh)
    }

    private func loadMoreConversations() {
        guard hasMoreConversations, !isLoading, !isRefreshing, !isLoadingMore else { return }
        loadConversations(mode: .more)
    }

    private func loadConversations(mode: ConversationLoadMode) {
        guard !isRefreshing, !isLoadingMore else { return }

        let offset: Int
        switch mode {
        case .initial:
            offset = 0
            isLoading = conversations.isEmpty
        case .refresh:
            offset = 0
            isRefreshing = true
        case .more:
            offset = conversations.count
            isLoadingMore = true
        }

        loadGeneration += 1
        let generation = loadGeneration
        let pageSize = Self.pageSize

        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
                await MainActor.run {
                    if generation == loadGeneration {
                        isLoading = false
                        isRefreshing = false
                        isLoadingMore = false
                    }
                }
                return
            }

            do {
                let page = try await dbQueue.read { db -> ConversationSummaryPage in
                    let requestLimit = pageSize + 1
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT
                            taskId,
                            firstUserMessage,
                            lastMessageDate,
                            messageCount,
                            acpSessionId
                        FROM conversation_summaries
                        ORDER BY lastMessageDate DESC, taskId DESC
                        LIMIT ? OFFSET ?
                    """, arguments: [requestLimit, offset])

                    let hasMore = rows.count > pageSize
                    let visibleRows = rows.prefix(pageSize)

                    let summaries = visibleRows.compactMap { row -> ConversationSummary? in
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

                    return ConversationSummaryPage(conversations: summaries, hasMore: hasMore)
                }

                await AppDatabase.shared.reportQuerySuccess()
                await MainActor.run {
                    guard generation == loadGeneration else { return }

                    switch mode {
                    case .initial:
                        conversations = page.conversations
                        hasMoreConversations = page.hasMore
                    case .refresh:
                        let refreshedIds = Set(page.conversations.map(\.id))
                        let olderLoadedPages = conversations.count > Self.pageSize
                        let retained = conversations.filter { !refreshedIds.contains($0.id) }
                        let refreshed = page.conversations + retained
                        if conversations != refreshed {
                            conversations = refreshed
                        }
                        hasMoreConversations = olderLoadedPages ? hasMoreConversations : page.hasMore
                    case .more:
                        let existingIds = Set(conversations.map(\.id))
                        let newConversations = page.conversations.filter { !existingIds.contains($0.id) }
                        conversations.append(contentsOf: newConversations)
                        hasMoreConversations = page.hasMore
                    }

                    if isLoading {
                        isLoading = false
                    }
                    isRefreshing = false
                    isLoadingMore = false
                }
            } catch {
                logError("ConversationHistorySection: Failed to load conversations", error: error)
                await AppDatabase.shared.reportQueryError(error)
                await MainActor.run {
                    if generation == loadGeneration {
                        isLoading = false
                        isRefreshing = false
                        isLoadingMore = false
                    }
                }
            }
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: ConversationSummary
    var isLoading: Bool = false
    var onDelete: (() -> Void)? = nil

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

            // Delete button, revealed on hover so the row stays clean otherwise.
            if isHovered && !isLoading, let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this conversation")
            }

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
