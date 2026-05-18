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
    ///   - messageCountBefore: Message count before the query started. When provided,
    ///     only messages added since this index are considered for AI message sync,
    ///     preventing a stale prior AI response from being re-set as currentAIMessage.
    static func handlePostQuery(
        provider: ChatProvider,
        state: FloatingControlBarState,
        sessionKey: String,
        messageCountBefore: Int? = nil
    ) {
        state.streaming.isAILoading = false

        // Sync the latest AI message directly from provider.messages to close the
        // race window where sendMessage has returned but the Combine $messages sink
        // (scheduled via .receive(on: .main)) hasn't fired yet.
        // Only search messages added AFTER this query started (the new slice) to
        // avoid re-setting currentAIMessage to a stale prior AI response, which
        // produces a duplicate bubble when the same message is also in chatHistory.
        let searchRange: ArraySlice<ChatMessage>
        if let start = messageCountBefore, start < provider.messages.count {
            searchRange = provider.messages[start...]
        } else {
            searchRange = provider.messages[provider.messages.startIndex...]
        }
        if let latestAI = searchRange.last(where: { $0.sender == .ai && $0.sessionKey == sessionKey }),
           !latestAI.text.isEmpty || !latestAI.contentBlocks.isEmpty {
            log("ChatQueryLifecycle: handlePostQuery synced AI message id=\(latestAI.id) session=\(sessionKey) fromSlice=\(messageCountBefore != nil)")
            state.streaming.currentAIMessage = latestAI
        } else {
            log("ChatQueryLifecycle: handlePostQuery found no new AI in \(searchRange.count) message(s) for session=\(sessionKey)")
        }

        // Don't update state if the conversation was closed while the query was in flight.
        guard state.streaming.showingAIConversation else { return }

        if provider.isClaudeAuthRequired {
            state.showConnectClaudeButton = true
            state.streaming.currentAIMessage = ChatMessage(text: "Please connect your Claude account to continue.", sender: .ai)
        } else if provider.showCreditExhaustedAlert {
            provider.showCreditExhaustedAlert = false
            if provider.isClaudeConnected {
                // User already has valid Claude credentials; just inform them the switch happened
                log("ChatQueryLifecycle: credits exhausted but Claude already connected, skipping connect prompt")
                state.streaming.currentAIMessage = ChatMessage(text: "Switched to your Claude account. You can keep chatting.", sender: .ai)
            } else {
                state.showConnectClaudeButton = true
                state.streaming.currentAIMessage = ChatMessage(text: "Your free built-in credits have run out. Connect your Claude account to continue.", sender: .ai)
            }
        } else if let errorText = provider.errorMessage {
            let isRateLimit = errorText.contains("usage limit") || errorText.contains("rate limit")
            let isPersonalMode = provider.bridgeMode == "personal"

            if isRateLimit && isPersonalMode {
                log("ChatQueryLifecycle: rate limit error in personal mode — showing upgrade banner")
                state.showUpgradeClaudeButton = true
            }

            let hasBlocks = !(state.streaming.currentAIMessage?.contentBlocks.isEmpty ?? true)
            let hasContent = !state.streaming.aiResponseText.isEmpty || hasBlocks
            let suffix = "\n\n⚠️ \(errorText)"
            if state.streaming.currentAIMessage != nil && hasContent {
                // ChatProvider's catch block also appends this suffix to the underlying
                // message in `messages[]` and persists it. Skip the in-state append
                // here if the warning is already present (the sync at line ~46 may
                // have already pulled in the warning-included text from messages[]).
                if !(state.streaming.currentAIMessage?.text.hasSuffix(suffix) ?? false) {
                    log("ChatQueryLifecycle: appending error to partial response (\(state.streaming.aiResponseText.count) chars): \(errorText.prefix(80))")
                    state.streaming.currentAIMessage?.text += suffix
                }
                // AIResponseView renders contentBlocks when non-empty and ignores .text.
                // Inject the warning as a text block too so it actually shows in the UI.
                if hasBlocks {
                    let warningBlockText = "⚠️ \(errorText)"
                    let alreadyShown = state.streaming.currentAIMessage?.contentBlocks.contains { block in
                        if case .text(_, let t) = block { return t == warningBlockText }
                        return false
                    } ?? false
                    if !alreadyShown {
                        state.streaming.currentAIMessage?.contentBlocks.append(
                            .text(id: "rate-limit-warning-\(UUID().uuidString)", text: warningBlockText)
                        )
                    }
                }
            } else {
                log("ChatQueryLifecycle: creating error-only AI message: \(errorText.prefix(80))")
                state.streaming.currentAIMessage = ChatMessage(text: "⚠️ \(errorText)", sender: .ai)
            }
        } else if provider.showPaywall {
            // Paywall blocked the message before it was sent. Restore the
            // user's typed message back into the input field so they don't
            // have to retype it after dismissing the paywall (or subscribing).
            //
            // The slice search above may have set currentAIMessage to a stale
            // prior AI response (when messageCountBefore is older than the
            // next exchange), making it look like the new question got the
            // old answer. Clear it so the only feedback is the paywall popup.
            let unsentMessage = state.streaming.displayedQuery
            state.streaming.currentAIMessage = nil

            if state.streaming.chatHistory.isEmpty {
                // First message in the session — collapse the chat view back
                // to the floating bar input and restore the message text there.
                state.input.aiInputText = unsentMessage
                state.streaming.displayedQuery = ""
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.streaming.showingAIResponse = false
                }
            } else {
                // Mid-conversation — un-archive the previous exchange (it was
                // moved to chatHistory in onSendFollowUp just before sending)
                // so the visible question/answer pair matches again, and drop
                // the unsent message back into the follow-up input via
                // pendingFollowUpText (AIResponseView's onChange picks it up).
                if let previous = state.streaming.chatHistory.popLast() {
                    state.streaming.displayedQuery = previous.question
                    state.streaming.currentAIMessage = previous.aiMessage
                } else {
                    state.streaming.displayedQuery = ""
                }
                state.input.pendingFollowUpText = unsentMessage
            }
            return
        } else if provider.needsBrowserExtensionSetup || provider.pendingRetryMessage != nil {
            log("ChatQueryLifecycle: Suppressing error message — browser setup retry pending")
        } else if state.streaming.currentAIMessage == nil ||
                  (state.streaming.aiResponseText.isEmpty && (state.streaming.currentAIMessage?.contentBlocks.isEmpty ?? true)) {
            state.streaming.currentAIMessage = ChatMessage(text: "Failed to get a response. Please try again.", sender: .ai)
        }

        // Ensure the response view is visible (handles the case where
        // the streaming sink never fired because no data arrived before the error)
        if !state.streaming.showingAIResponse {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                state.streaming.showingAIResponse = true
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
    /// - `$isCompacting` / `$compactingSessionKey`: sync compaction indicator (scoped to session)
    static func subscribeToProviderState(
        provider: ChatProvider,
        state: FloatingControlBarState,
        sessionKey: String? = nil,
        sessionKeyProvider: (() -> String?)? = nil
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

        // Clear stale suggested replies when a new query starts on THIS window's
        // session. Without the session-key filter, a query in any pop-out clears
        // the choice buttons in every other pop-out (bug: shared @Published on a
        // single ChatProvider observed by all chat surfaces).
        cancellables.append(
            provider.$queryStartedCount
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak state, weak provider] _ in
                    guard let state else { return }
                    let currentKey = sessionKeyProvider?() ?? sessionKey
                    let startedKey = provider?.queryStartedSessionKey
                    if let currentKey, let startedKey, currentKey != startedKey {
                        return
                    }
                    state.streaming.suggestedReplies = []
                    state.streaming.suggestedReplyQuestion = ""
                }
        )

        // Clear "Upgrade Plan" button only after the rate-limit reset time has
        // actually elapsed. A bare `status == "allowed"` is not enough: when
        // the ACP subprocess restarts after a credit/rate-limit hit, the fresh
        // session's warmup emits `rate_limit: allowed` for the new session even
        // though the user-level 5h cap hasn't moved. Trusting that signal hides
        // the banner ~2 minutes after the cap was hit (real reset is hours away).
        cancellables.append(
            provider.$rateLimitStatus
                .combineLatest(provider.$rateLimitResetsAt)
                .receive(on: DispatchQueue.main)
                .sink { [weak state, weak provider] status, resetsAt in
                    guard let state else { return }
                    guard status == "allowed" || status == nil else { return }
                    guard state.showUpgradeClaudeButton else { return }
                    let now = Date().timeIntervalSince1970
                    let resetElapsed = (resetsAt ?? 0) <= now
                    if !resetElapsed {
                        // Keep the banner up; reset hasn't actually arrived yet.
                        return
                    }
                    let lastType = provider?.rateLimitType ?? "nil"
                    log("ChatQueryLifecycle: rate limit cleared (status=\(status ?? "nil"), type=\(lastType), resetElapsed=true) — clearing upgrade banner")
                    withAnimation(.easeOut(duration: 0.3)) {
                        state.showUpgradeClaudeButton = false
                    }
                }
        )

        // Sync compaction indicator, scoped to this session's key.
        // sessionKeyProvider is preferred (handles session key changes from "new chat"),
        // falls back to the static sessionKey, falls back to unfiltered.
        cancellables.append(
            provider.$isCompacting
                .combineLatest(provider.$compactingSessionKey)
                .receive(on: DispatchQueue.main)
                .sink { [weak state] isCompacting, compactingKey in
                    guard let state else { return }
                    let currentKey = sessionKeyProvider?() ?? sessionKey
                    if let currentKey {
                        state.streaming.isCompacting = isCompacting && compactingKey == currentKey
                    } else {
                        state.streaming.isCompacting = isCompacting
                    }
                }
        )

        // Sync the bridge cold-start indicator. Not session-scoped — warmup is a
        // global, one-time-per-launch event shared by every session.
        cancellables.append(
            provider.$isBridgeWarmingUp
                .receive(on: DispatchQueue.main)
                .sink { [weak state] isWarmingUp in
                    state?.streaming.isBridgeWarmingUp = isWarmingUp
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
    ///   - sessionKey: The ACP session key for this query. When provided, callbacks are
    ///                 registered per-session to prevent cross-contamination between pop-out windows.
    static func prepareForQuery(
        state: FloatingControlBarState,
        message: String,
        hasScreenshot: Bool,
        sendFollowUp: ((String) -> Void)?,
        sessionKey: String? = nil
    ) {
        state.streaming.suggestedReplies = []
        state.streaming.suggestedReplyQuestion = ""

        let quickReplyHandler: (String, [String]) -> Void = { [weak state] question, options in
            Task { @MainActor in
                state?.streaming.suggestedReplyQuestion = question
                // Animate the appearance so the chips slide + fade in smoothly
                // instead of popping in abruptly. The .transition on the view
                // itself only fires when the state change is animated.
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    state?.streaming.suggestedReplies = options
                }
            }
        }

        if let sessionKey {
            // Per-session registration prevents cross-contamination between pop-out windows
            ChatToolExecutor.registerCallbacks(
                sessionKey: sessionKey,
                onQuickReply: quickReplyHandler,
                onFollowUp: sendFollowUp
            )
        } else {
            // Fallback for floating bar / onboarding (single-session contexts)
            ChatToolExecutor.onQuickReplyOptions = quickReplyHandler
            if let sendFollowUp {
                ChatToolExecutor.onSendFollowUp = sendFollowUp
            }
        }

        AnalyticsManager.shared.floatingBarQuerySent(messageLength: message.count, hasScreenshot: hasScreenshot, queryText: message)

        // Track referral progress for referred users
        if ReferralService.shared.wasReferred && !ReferralService.shared.isReferralCompleted {
            Task { await ReferralService.shared.validateFloatingBarMessage() }
        }
    }
}
