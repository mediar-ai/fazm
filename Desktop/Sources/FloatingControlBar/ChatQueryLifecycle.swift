import Combine
import SwiftUI

/// Shared post-query and subscription logic used by both FloatingControlBarManager
/// and DetachedChatWindowController so error handling, auth state, and analytics
/// stay in sync across all chat surfaces.
@MainActor
enum ChatQueryLifecycle {

    // MARK: - Post-query error handling

    /// Call after `provider.sendMessage(...)` returns. Inspects the provider for
    /// errors, credit exhaustion, auth requirements, paywall, and browser-setup
    /// retries, then updates `state` accordingly.
    ///
    /// - Parameters:
    ///   - provider: The ChatProvider that just finished a query.
    ///   - state: The FloatingControlBarState to update with error/auth UI.
    ///   - sessionKey: The session key used for the query (to sync latest AI message).
    static func handlePostQuery(
        provider: ChatProvider,
        state: FloatingControlBarState,
        sessionKey: String
    ) {
        state.isAILoading = false

        // Sync the latest AI message directly from provider.messages to close the
        // race window where sendMessage has returned but the Combine $messages sink
        // (scheduled via .receive(on: .main)) hasn't fired yet.
        if let latestAI = provider.messages.last(where: { $0.sender == .ai && $0.sessionKey == sessionKey }),
           !latestAI.text.isEmpty || !latestAI.contentBlocks.isEmpty {
            state.currentAIMessage = latestAI
        }

        // Don't update state if the conversation was closed while the query was in flight.
        guard state.showingAIConversation else { return }

        if provider.isClaudeAuthRequired {
            state.showConnectClaudeButton = true
            state.currentAIMessage = ChatMessage(text: "Please connect your Claude account to continue.", sender: .ai)
        } else if provider.showCreditExhaustedAlert {
            provider.showCreditExhaustedAlert = false
            state.showConnectClaudeButton = true
            state.currentAIMessage = ChatMessage(text: "Your free built-in credits have run out. Connect your Claude account to continue.", sender: .ai)
        } else if let errorText = provider.errorMessage {
            let isRateLimit = errorText.contains("usage limit") || errorText.contains("rate limit")
            let isPersonalMode = provider.bridgeMode == "personal"

            if isRateLimit && isPersonalMode {
                state.showUpgradeClaudeButton = true
            }

            let hasContent = !state.aiResponseText.isEmpty || !(state.currentAIMessage?.contentBlocks.isEmpty ?? true)
            if state.currentAIMessage != nil && hasContent {
                state.currentAIMessage?.text += "\n\n⚠️ \(errorText)"
            } else {
                state.currentAIMessage = ChatMessage(text: "⚠️ \(errorText)", sender: .ai)
            }
        } else if provider.showPaywall {
            return
        } else if provider.needsBrowserExtensionSetup || provider.pendingRetryMessage != nil {
            log("ChatQueryLifecycle: Suppressing error message — browser setup retry pending")
        } else if state.currentAIMessage == nil ||
                  (state.aiResponseText.isEmpty && (state.currentAIMessage?.contentBlocks.isEmpty ?? true)) {
            state.currentAIMessage = ChatMessage(text: "Failed to get a response. Please try again.", sender: .ai)
        }

        // Ensure the response view is visible (handles the case where
        // the streaming sink never fired because no data arrived before the error)
        if !state.showingAIResponse {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                state.showingAIResponse = true
            }
        }
    }

    // MARK: - Provider state subscriptions

    /// Subscribes to ChatProvider published properties that affect chat UI state.
    /// Returns an array of cancellables that the caller must retain.
    ///
    /// Covers:
    /// - `$isClaudeConnected` / `$isClaudeAuthRequired`: auto-dismiss "Connect Claude" button
    /// - `$queryStartedCount`: clear stale suggested replies on new queries
    /// - `$isCompacting`: sync compaction indicator
    static func subscribeToProviderState(
        provider: ChatProvider,
        state: FloatingControlBarState
    ) -> [AnyCancellable] {
        var cancellables: [AnyCancellable] = []

        // Clear "Connect Claude" button when auth succeeds
        cancellables.append(
            provider.$isClaudeConnected
                .receive(on: DispatchQueue.main)
                .sink { [weak state] connected in
                    guard let state else { return }
                    if connected {
                        withAnimation(.easeOut(duration: 0.3)) {
                            state.showConnectClaudeButton = false
                        }
                    }
                }
        )

        // Also watch isClaudeAuthRequired going false (covers the case where
        // isClaudeConnected was already true and doesn't emit a new value)
        cancellables.append(
            provider.$isClaudeAuthRequired
                .receive(on: DispatchQueue.main)
                .sink { [weak state] authRequired in
                    guard let state else { return }
                    if !authRequired {
                        withAnimation(.easeOut(duration: 0.3)) {
                            state.showConnectClaudeButton = false
                        }
                    }
                }
        )

        // Clear stale suggested replies when ANY new query starts
        cancellables.append(
            provider.$queryStartedCount
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak state] _ in
                    state?.suggestedReplies = []
                    state?.suggestedReplyQuestion = ""
                }
        )

        // Sync compaction indicator
        cancellables.append(
            provider.$isCompacting
                .receive(on: DispatchQueue.main)
                .sink { [weak state] isCompacting in
                    state?.isCompacting = isCompacting
                }
        )

        return cancellables
    }

    // MARK: - Pre-query setup

    /// Common pre-query setup: clear suggested replies, wire up callbacks, track analytics.
    /// Call before `provider.sendMessage(...)`.
    ///
    /// - Parameters:
    ///   - state: The state to update.
    ///   - message: The query text (for analytics).
    ///   - hasScreenshot: Whether a screenshot is attached.
    ///   - sendFollowUp: Closure to send an auto-follow-up (e.g., after OAuth in browser).
    ///                   Pass nil if auto-follow-ups are not supported in this context.
    static func prepareForQuery(
        state: FloatingControlBarState,
        message: String,
        hasScreenshot: Bool,
        sendFollowUp: ((String) -> Void)?
    ) {
        state.suggestedReplies = []
        state.suggestedReplyQuestion = ""

        ChatToolExecutor.onQuickReplyOptions = { [weak state] question, options in
            Task { @MainActor in
                state?.suggestedReplyQuestion = question
                state?.suggestedReplies = options
            }
        }

        if let sendFollowUp {
            ChatToolExecutor.onSendFollowUp = sendFollowUp
        }

        AnalyticsManager.shared.floatingBarQuerySent(messageLength: message.count, hasScreenshot: hasScreenshot, queryText: message)

        // Track referral progress for referred users
        if ReferralService.shared.wasReferred && !ReferralService.shared.isReferralCompleted {
            Task { await ReferralService.shared.validateFloatingBarMessage() }
        }
    }
}
