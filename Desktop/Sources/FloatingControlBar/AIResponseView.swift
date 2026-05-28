import SwiftUI

/// Persisted list of recently-used workspace directory paths (max 9, MRU order).
/// The dropdown filters out the current workspace, so up to 8 entries are shown.
enum RecentWorkspaces {
    private static let key = "recentWorkspacePaths"
    private static let maxCount = 9

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
    /// When non-nil, the follow-up input is staged with a past message's text
    /// so the user can edit it. On send, we route through `onEditMessage`
    /// (truncate + resubmit) instead of the normal follow-up path.
    @State private var editingExchangeId: String?
    /// Snapshot of `followUpText` from before editing started, so Cancel can
    /// restore whatever the user was drafting.
    @State private var preEditFollowUpText: String = ""
    /// Snapshot of pending attachments from before editing started. We hide
    /// attachments during edit (the resubmit path is text-only) and put them
    /// back if the user cancels.
    @State private var preEditAttachments: [ChatAttachment] = []
    /// Bumped each time we start a new edit so the follow-up FazmTextEditor
    /// takes first-responder (without it, the user would have to click the
    /// input to start typing).
    @State private var editFocusToken: Int = 0
    @State private var isHanging = false
    @State private var hangTask: Task<Void, Never>?
    @State private var isStopping = false
    /// True when the hang state was triggered by a previous crash, not the 30s timer.
    /// Prevents the isLoading onChange from clearing it when a query completes.
    @State private var isHangingFromCrash = false
    @State private var shouldFollowContent = true
    @State private var isProgrammaticScroll = false
    /// Scroll-storm instrumentation + rate-limit. `scrollToBottom` is supposed
    /// to fire once per genuine new-content event or user action. When an idle
    /// window gets into a layout feedback loop (a stuck `repeatForever` keeping
    /// an animation transaction open, or auto-follow re-pins compounding), the
    /// animated re-pin runs every display cycle → `runAnimationGroup →
    /// LayoutScrollableTransform` pegs the main thread → composer keystrokes
    /// lag. We (1) log a one-shot `[ScrollStorm]` line with the concurrent flag
    /// state to localize the trigger, and (2) collapse rapid calls to an
    /// instant snap so overlapping 0.15s glides can't compound.
    @State private var lastScrollAt: Date = .distantPast
    @State private var scrollRateWindowStart: Date = .distantPast
    @State private var scrollRateCount: Int = 0
    @State private var scrollStormLoggedAt: Date = .distantPast
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

    // MARK: - Response-body virtualization (large conversations)
    // In a long conversation the message list is a plain (non-lazy) VStack, so
    // every AI response — markdown, code blocks, tool/observer cards — stays in
    // the display list and is re-walked on every layout pass, an O(history) cost
    // paid at the streaming refresh rate (profiled 2026-05-27). We can't switch
    // to LazyVStack (`.defaultScrollAnchor(.bottom)` needs full synchronous
    // content height — reverted in 9585586e). Instead we keep every PROMPT bubble
    // mounted (so the stacked-prompt overlay + `scrollTo` jump-back are untouched)
    // and swap each off-viewport AI RESPONSE for a fixed-height spacer matching
    // its last-measured height, rematerializing it when scrolled near. Responses
    // are the bulk of the per-frame cost; prompts are one line each.
    /// Last-measured rendered height of each archived exchange's response block,
    /// keyed by exchange id. Drives the collapsed spacer so expand/collapse never
    /// shifts layout. Cleared on font-scale change (heights become stale).
    @State private var responseHeights: [UUID: CGFloat] = [:]
    /// Vertical extent (minY...maxY in `chatScrollSpace` document coords) of each
    /// archived exchange row. Document coords don't move when scrolling, so these
    /// only update on real layout changes; visibility is recomputed cheaply when
    /// `scrollBounds` moves. Used to decide which responses fall inside the
    /// keep-rendered window.
    @State private var exchangeExtents: [UUID: ClosedRange<CGFloat>] = [:]
    /// Only virtualize once the conversation is large enough to matter; shorter
    /// chats render in full (zero behavior change for the common case).
    private static let virtualizationMinExchanges = 12
    /// Height assumed for a response we have not measured yet (older turns on
    /// first open). Real heights replace it as they scroll into view.
    private static let estimatedResponseHeight: CGFloat = 220

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
    /// Force-stop: invoked from the "Force stop" button shown next to the
    /// `streaming.stalledToolName` indicator when a tool has gone silent.
    /// Wired to `ChatProvider.forceStopAgent(sessionKey:)`; bridge SIGKILLs
    /// the wedged Playwright MCP so the in-flight call dies for real.
    var onForceStopAgent: (() -> Void)?
    /// Retry action for the `.toolForceStopped` system card. Closure takes
    /// the sessionKey of the message containing the card (so the card view
    /// can stay sessionKey-agnostic). Wired to
    /// `ChatProvider.retryAfterForceStop(sessionKey:)`.
    var onRetryAfterForceStop: ((String) -> Void)?
    /// Tear down the upstream session — wired to `ChatProvider.endSession(sessionKey:)`.
    /// Called from the "Reset session" button in the still-cleaning-up pill when
    /// the bridge hasn't ack'd a Stop within `stuckSessionWarnThreshold`.
    /// Distinct from the bar window's `onResetSession` (which is "New Chat" /
    /// `resetSession`): this preserves local history and only kills the upstream
    /// subprocess, used to escape a hung Claude/Codex call.
    var onResetStuckSession: (() -> Void)?
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
                        // NOTE: Must stay VStack, NOT LazyVStack. .defaultScrollAnchor(.bottom)
                        // below requires the full content height to be known synchronously;
                        // LazyVStack defers off-screen row materialization, which makes the
                        // bottom anchor land in unrendered space when streaming starts → the
                        // viewport appears empty until tokens arrive. Reverted from 9585586e.
                        VStack(alignment: .leading, spacing: 16) {
                            // Previous chat exchanges — regular ones rendered individually
                            ForEach(Array(regularExchanges.enumerated()), id: \.element.id) { index, exchange in
                                chatExchangeView(exchange, index: index)
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

                            // Koah contextual ad slot. Gated by `KoahAdGate.shouldShowAd()`,
                            // which requires no active subscription AND the `koah_enabled`
                            // PostHog feature flag to be true (default false → off for
                            // everyone). Floating bar + pop-out only; not used in onboarding.
                            // See KoahAdView.swift.
                            if !isLoading,
                               let msg = currentMessage,
                               !userInput.isEmpty,
                               !msg.copyableText.isEmpty,
                               msg.isStreaming == false,
                               KoahAdGate.shouldShowAd() {
                                KoahAdView(question: userInput, answer: msg.copyableText)
                                    .padding(.top, 8)
                                    .id("koah-ad-\(msg.id)")
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
                            //
                            // Render as soon as the chips are populated, even if the turn hasn't
                            // ended yet. ask_followup is supposed to be the last tool call, but
                            // the model often keeps generating after it, which used to leave the
                            // pop-out stuck in a spinning state for minutes with no visible chips.
                            // Clicking a chip while the session is still busy safely enqueues via
                            // DetachedChatWindowController.sendQuery (busy branch).
                            if !suggestedReplies.isEmpty {
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
                        .animation(.spring(response: 0.5, dampingFraction: 0.82),
                                   value: suggestedReplies.isEmpty)
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
                    // EXPERIMENT 2026-05-28: nullify any ambient SwiftUI
                    // animation transaction at the ScrollView boundary. Prod
                    // sample shows `InterpolatedDisplayList.updateValue() →
                    // ResolvedStyledText.modifyTransition` running every
                    // display cycle on idle windows — i.e. an animation
                    // transaction kept alive by SOMETHING (still unidentified)
                    // is making SwiftUI interpolate the whole markdown
                    // display list at 60Hz. `.transaction { $0.animation =
                    // nil }` strips the inherited animation from this subtree,
                    // so even if an ambient transaction is alive elsewhere,
                    // the message list won't re-interpolate.
                    .transaction { $0.animation = nil }
                    .onPreferenceChange(StackedBubblesPreferenceKey.self) { value in
                        // Dedupe by id (preferences accumulate across updates) and
                        // sort once so consumers can binary-search later if needed.
                        var byId: [UUID: StackedBubbleInfo] = [:]
                        for info in value { byId[info.id] = info }
                        let sorted = byId.values.sorted { $0.topY < $1.topY }
                        // Equality guard: only write @State when the result
                        // actually changed. Without this, an identical re-report
                        // (sub-pixel jitter, overlay relayout) reassigns @State →
                        // re-render → re-measure → re-report, a feedback loop that
                        // feeds the scroll-anchor storm.
                        if sorted != bubbleInfos { bubbleInfos = sorted }
                    }
                    .onPreferenceChange(ExchangeExtentPreferenceKey.self) { value in
                        // Latest extent per exchange (document coords) for the
                        // virtualization visibility window.
                        var next = exchangeExtents
                        for info in value where info.maxY >= info.minY {
                            next[info.id] = info.minY...info.maxY
                        }
                        if next != exchangeExtents { exchangeExtents = next }
                    }
                    .onPreferenceChange(ResponseHeightPreferenceKey.self) { value in
                        // Cache each expanded response's height so its collapsed
                        // spacer is the same size (no scroll jump on toggle).
                        var next = responseHeights
                        for info in value where info.height > 0 {
                            next[info.id] = info.height
                        }
                        if next != responseHeights { responseHeights = next }
                    }
                    .onChange(of: fontScale) {
                        // Cached response heights are in points at the old scale;
                        // drop them so spacers re-measure at the new font size.
                        responseHeights.removeAll()
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
                        scrollToBottom(proxy: proxy, reason: "chatHistory", userInitiated: true)
                    }
                    .onChange(of: streaming.pendingChatObserverExchanges.count) {
                        shouldFollowContent = true
                        scrollToBottom(proxy: proxy, reason: "observerExchanges")
                    }
                    // Active re-pin while streaming: when a new content block
                    // appears (tool call, thinking block, new text segment) and
                    // we're still following, programmatically scroll to the
                    // bottom instead of relying solely on .defaultScrollAnchor,
                    // which can lag a frame behind a large block insertion. This
                    // is gated on shouldFollowContent, so once the user scrolls
                    // up (detector sets it false) we stop yanking them down and
                    // the scroll-down button stays visible — no "stuck detached
                    // with no button" state.
                    .onChange(of: currentMessage?.contentBlocks.count ?? 0) {
                        if shouldFollowContent {
                            scrollToBottom(proxy: proxy, reason: "contentBlocks")
                        }
                    }
                    .onChange(of: isLoading) {
                        if !isLoading {
                            state.flushPendingChatObserverExchanges()
                        }
                    }
                    .onChange(of: isVoiceFollowUp) {
                        if isVoiceFollowUp {
                            shouldFollowContent = true
                            scrollToBottom(proxy: proxy, anchor: "voiceFollowUp", reason: "voice", userInitiated: true)
                        }
                    }
                    // Debug-only: deterministic idle scroll-storm repro. The
                    // `simulateIdleScrollStorm` control command ticks this at
                    // 60Hz for a few seconds, driving scrollToBottom exactly
                    // like the runaway loop so we can verify the rate-limit
                    // collapses it (and the [ScrollStorm] log fires).
                    .onChange(of: streaming.debugScrollStormTick) {
                        scrollToBottom(proxy: proxy, reason: "debug-storm", userInitiated: true)
                    }

                    // Scroll-to-bottom overlay button — show whenever the view
                    // is detached and there is anything scrollable. Gating on
                    // chatHistory alone hid the button during the very first
                    // exchange (the live question/response lives in
                    // currentMessage and isn't archived into chatHistory until
                    // the next query), so scrolling up mid-first-stream left no
                    // way back to the bottom.
                    if !shouldFollowContent && (currentMessage != nil || !userInput.isEmpty || !chatHistory.isEmpty) {
                        Button {
                            shouldFollowContent = true
                            scrollToBottom(proxy: proxy, reason: "jumpButton", userInitiated: true)
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
                // Auto-expire the crash-triggered flash. The ReportIssueButton's
                // `repeatForever` flash (gated on isHanging) keeps a SwiftUI
                // animation transaction open for as long as isHanging stays true.
                // If the user never sends a query in this window, that transaction
                // never closes, and `.defaultScrollAnchor(.bottom)` re-pins under
                // it animate every display cycle → main-thread layout storm →
                // composer lag. Clear it after 20s so the flash can't run forever.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    if isHangingFromCrash {
                        isHanging = false
                        isHangingFromCrash = false
                    }
                }
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
    @State private var showWorkspaceInfo = false

    /// The effective workspace for this view: per-window state if set, otherwise global default.
    private var aiChatWorkingDirectory: String {
        workspace.workspaceDirectory.isEmpty ? globalWorkspaceDirectory : workspace.workspaceDirectory
    }

    private func scrollToBottom(proxy: ScrollViewProxy, anchor: String = "bottom", reason: String = "unknown", userInitiated: Bool = false) {
        let now = Date()

        // --- Instrumentation: catch a runaway auto-follow / re-pin loop.
        // scrollToBottom should fire once per real event. If it's being called
        // >15×/sec, that IS the input-lag storm. Log once per storm (throttled
        // to 5s) with the concurrent flag state so the log tells us WHICH
        // trigger / stuck repeatForever is driving it (isHanging from the crash
        // flash? a stuck isStreaming bubble? the chat observer?).
        if now.timeIntervalSince(scrollRateWindowStart) >= 1.0 {
            scrollRateWindowStart = now
            scrollRateCount = 0
        }
        scrollRateCount += 1
        if scrollRateCount == 16, now.timeIntervalSince(scrollStormLoggedAt) > 5.0 {
            scrollStormLoggedAt = now
            log("[ScrollStorm] scrollToBottom \(scrollRateCount)+/s session=\(currentMessage?.sessionKey ?? "floating") reason=\(reason) userInitiated=\(userInitiated) isTurnActive=\(isTurnActive) isHanging=\(isHanging) isStreaming=\(currentMessage?.isStreaming == true) observerRunning=\(streaming.isChatObserverRunning) shouldFollow=\(shouldFollowContent)")
        }

        // --- Fix: rate-limit the animated re-pin. A genuine new-content or
        // user scroll animates once (the 0.15s glide). But if calls arrive
        // faster than that glide (auto-follow during a reflow loop, or a stuck
        // ambient animation re-pinning every frame), collapse to an instant
        // snap so overlapping animations can't compound into a continuous
        // runAnimationGroup → LayoutScrollableTransform main-thread storm.
        let rapid = now.timeIntervalSince(lastScrollAt) < 0.12
        lastScrollAt = now

        isProgrammaticScroll = true
        // Animate ONLY a deliberate, non-rapid, user-initiated jump while idle.
        // Streaming, rapid-repeat, and background auto-follow all snap instantly.
        if userInitiated && !rapid && !isTurnActive {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        } else {
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

    /// Maps a raw MCP tool title like `mcp__playwright__browser_evaluate` to
    /// a short human label for the "not responding" indicator. Playwright /
    /// browser tools all collapse to "Browser" (the user doesn't care which
    /// browser method wedged, only that the browser is); other servers show
    /// their capitalized server name.
    private func friendlyToolLabel(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("playwright") || lower.contains("browser_") || lower.contains("browser-harness") {
            return "Browser"
        }
        let parts = raw.components(separatedBy: "__").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let server = parts[1]
            return server.prefix(1).uppercased() + server.dropFirst()
        }
        return raw
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
                if let stalledName = streaming.stalledToolName,
                   let stalledSince = streaming.stalledSince {
                    // Live "tool not responding" indicator. Driven by the
                    // bridge stall detector (`tool_stalled`) when an in-flight
                    // mcp__ tool has gone silent past the threshold (typical
                    // case: Playwright on a dead Chrome extension). The turn
                    // is NOT canceled — this is purely a "stop is the move"
                    // signal so the window doesn't sit there looking frozen
                    // with no animation. Takes precedence over the crash-only
                    // `isHanging` path; both shouldn't render at once.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 12)
                        .foregroundColor(.orange)
                    TimelineView(.periodic(from: stalledSince, by: 1.0)) { ctx in
                        Text("\(friendlyToolLabel(stalledName)) is not responding · \(Int(ctx.date.timeIntervalSince(stalledSince)))s")
                            .scaledFont(size: 14)
                            .foregroundColor(.orange)
                    }
                    // Force stop affordance. Cooperative Stop (red square in
                    // the composer) tells the agent to halt and frees the UI
                    // but the wedged MCP tool keeps running underneath. This
                    // escalation actually SIGKILLs the Playwright MCP so the
                    // browser call dies for real. Hidden until the parent
                    // wires `onForceStopAgent` (Force stop is only meaningful
                    // in the bar / pop-out surfaces that own a session).
                    if let action = onForceStopAgent {
                        Button(action: action) {
                            Text("Force stop")
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.orange.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(Color.orange.opacity(0.45), lineWidth: 0.5)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Kill the unresponsive browser tool and reset the connection. Your conversation is intact.")
                    }
                } else if isHanging {
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
                    // Pull running tool names so we can show the user which tool
                    // is actually in flight. A 45s Terminal exec used to look
                    // identical to a hung session ("using tools" + spinner);
                    // naming the tool + showing elapsed seconds beyond 10s tells
                    // the user real work is happening so they don't double-click
                    // the Report Issue button thinking the agent is dead.
                    let runningTools: [String] = currentMessage?.contentBlocks.compactMap {
                        if case .toolCall(_, let name, .running, _, _, _) = $0 { return name }
                        return nil
                    } ?? []
                    // A query queued behind first-launch warmup would otherwise
                    // show a bare "thinking" spinner that looks stuck — name the
                    // actual wait so the user knows it's cold-starting, not hung.
                    if streaming.isBridgeWarmingUp {
                        Text("preparing assistant…")
                            .scaledFont(size: 14)
                            .foregroundColor(.secondary)
                    } else if !runningTools.isEmpty {
                        RunningToolLabel(toolNames: runningTools)
                    } else {
                        Text("thinking")
                            .scaledFont(size: 14)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                workspaceLabel
            }

            if state.showUpgradeClaudeButton {
                upgradeClaudeButton
            }

            Spacer()

            ModelToggleButton(
                localModel: localModel,
                isClaudeConnected: state.isClaudeConnected,
                onConnectClaude: onConnectClaude,
                onCodexLogin: onCodexLogin
            )

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
                    // Value-based animation per Extensions/WindowVisibility.swift.
                    // When the window hides, the modifier becomes `.default` and
                    // snaps the in-flight repeatForever to a static value, closing
                    // the SwiftUI animation transaction. The previous
                    // `withAnimation(.repeatForever) { upgradePulse = true }`
                    // kept the transaction open forever — the root cause of the
                    // ResolvedStyledText storm + composer lag (2026-05-27).
                    .animation(
                        windowIsVisible
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .default,
                        value: upgradePulse
                    )
            )
        }
        .buttonStyle(.plain)
        .onAppear { startUpgradePulseIfVisible() }
        .onChange(of: windowIsVisible) { _, _ in startUpgradePulseIfVisible() }
        .transition(.scale.combined(with: .opacity))
    }

    private func startUpgradePulseIfVisible() {
        upgradePulse = windowIsVisible
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
    private func contentBlocksView(for message: ChatMessage) -> MessageContentBlocks {
        MessageContentBlocks(
            message: message,
            isChatObserverRunning: streaming.isChatObserverRunning,
            onChatObserverCardAction: { [self] activityId, action in
                handleChatObserverCardAction(activityId: activityId, action: action)
            },
            onRetryAfterForceStop: onRetryAfterForceStop
        )
    }

    /// Renders one message's content blocks. Conforms to `Equatable` so completed
    /// (history) exchanges can be wrapped with `.equatable()` at the call site —
    /// while a new turn streams, SwiftUI then skips re-rendering every prior
    /// bubble's markdown instead of reflowing the whole VStack per token. The
    /// message list is a plain VStack (not LazyVStack — `.defaultScrollAnchor(.bottom)`
    /// needs the full content height), so before this every streamed token forced an
    /// O(history) markdown re-render + re-layout. History exchanges are immutable, so
    /// (id + block count + text length) uniquely identifies the rendered content; the
    /// streaming bubble is rendered without `.equatable()` and keeps updating live.
    struct MessageContentBlocks: View, Equatable {
        let message: ChatMessage
        let isChatObserverRunning: Bool
        let onChatObserverCardAction: (Int64, String) -> Void
        /// Threaded to `.systemEvent` rendering so the `.toolForceStopped`
        /// card can show a Retry button. Excluded from Equatable comparison
        /// (closures aren't equatable); SwiftUI still re-renders because the
        /// struct is recreated on each parent body invocation.
        var onRetryAfterForceStop: ((String) -> Void)? = nil

        static func == (lhs: MessageContentBlocks, rhs: MessageContentBlocks) -> Bool {
            lhs.message.id == rhs.message.id
                && lhs.message.contentBlocks.count == rhs.message.contentBlocks.count
                && lhs.message.text.count == rhs.message.text.count
                && lhs.isChatObserverRunning == rhs.isChatObserverRunning
        }

        var body: some View {
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
                        SystemEventCardView(
                            event: event,
                            onRetry: event.kind == .toolForceStopped
                                ? { onRetryAfterForceStop?(message.sessionKey ?? "floating") }
                                : nil
                        )
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
                        isChatObserverRunning: isChatObserverRunning,
                        onAction: { id, action in
                            onChatObserverCardAction(id, action)
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

    /// Virtualization is on only for long conversations.
    /// EXPERIMENT (2026-05-27 evening): force-disable while diagnosing the
    /// `runAnimationGroup → LazyLayoutViewCache.invalidateSize` storm. Sample
    /// of prod 2.9.47 shows `ScrollViewCommitMutation.apply()` running every
    /// display cycle, which is the textbook signature of a viewport ↔ content-
    /// size feedback loop (swap response → spacer → height changes → viewport
    /// shifts → another swap). If the lag clears with this disabled, the
    /// virt path needs a stable-content-size guard before re-enabling.
    private var virtualizationActive: Bool {
        return false
    }

    /// Whether the AI response for the exchange at `index` should render in full
    /// now, vs. a height-preserving spacer. The keep-rendered window is the
    /// viewport plus one extra screen of margin in each direction, so content
    /// rematerializes before it scrolls into view. Until an exchange's extent has
    /// been measured (first open), only the last few render — older unmeasured
    /// ones stay collapsed at the estimate until scrolled to.
    private func shouldExpandResponse(id: UUID, index: Int) -> Bool {
        guard virtualizationActive else { return true }
        guard scrollBounds.viewportHeight > 0 else { return true }
        let margin = max(scrollBounds.viewportHeight, 600)
        let windowLo = scrollBounds.offsetY - margin
        let windowHi = scrollBounds.offsetY + scrollBounds.viewportHeight + margin
        if let extent = exchangeExtents[id] {
            return extent.lowerBound <= windowHi && extent.upperBound >= windowLo
        }
        return index >= regularExchanges.count - 4
    }

    private func chatExchangeView(_ exchange: FloatingChatExchange, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Question bubble (hidden for observer-only entries with no user question)
            if !exchange.question.isEmpty {
                ExpandableQuestionBubble(
                    question: exchange.question,
                    exchangeId: exchange.id,
                    // Show the pencil only when the parent wired a commit
                    // handler. Tapping it stages the edit in the follow-up
                    // input; the actual truncate + resubmit fires from
                    // `sendFollowUp()` when the user hits send.
                    onBeginEdit: onEditMessage == nil ? nil : { exchangeId, original in
                        beginEditingMessage(exchangeId: exchangeId, originalText: original)
                    }
                )
                    .opacity(stackedBubbleIDs.contains(exchange.id) ? 0 : 1)
                    .background {
                        // Per-bubble geometry probe feeding the stacked-bubble
                        // peek overlay. Suspended while a turn is active: it
                        // otherwise re-measures every history bubble on every
                        // layout pass — an O(history) cost paid at the streaming
                        // refresh rate. With it gone, bubbleInfos clears (the
                        // preference defaults to []), so every bubble renders at
                        // full opacity and the peek overlay hides until the turn
                        // ends — fine, since the user is pinned to the bottom
                        // while a response streams.
                        if !isTurnActive {
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
                        }
                    }
            }

            // Response with content blocks. In long conversations the response
            // is virtualized (see the virtualization notes on `responseHeights`):
            // rendered in full only when near the viewport, otherwise a
            // fixed-height spacer matching its last-measured height, so the heavy
            // markdown/code/tool display list isn't re-walked every frame while a
            // later turn streams. The prompt bubble above always stays mounted, so
            // the stacked-prompt overlay and jump-back are unaffected.
            if !exchange.aiMessage.contentBlocks.isEmpty || !exchange.aiMessage.text.isEmpty {
                if shouldExpandResponse(id: exchange.id, index: index) {
                    MessageWithCopyButton(alignment: .topTrailing) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exchange.aiMessage.copyableText, forType: .string)
                    } content: {
                        VStack(alignment: .leading, spacing: 4) {
                            // Completed history exchange: memoize so a streaming turn doesn't
                            // re-render this bubble's markdown every token. See MessageContentBlocks.
                            contentBlocksView(for: exchange.aiMessage)
                                .equatable()
                        }
                        .padding(.horizontal, 4)
                    }
                    .background {
                        // Measure the rendered response height so the collapsed
                        // spacer is identical and expand/collapse never shifts
                        // layout. Only present while expanded (few at a time).
                        if virtualizationActive {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ResponseHeightPreferenceKey.self,
                                    value: [ResponseHeightInfo(id: exchange.id, height: geo.size.height)]
                                )
                            }
                        }
                    }
                } else {
                    Color.clear
                        .frame(height: responseHeights[exchange.id] ?? Self.estimatedResponseHeight)
                }
            }

            Divider()
                .background(FazmColors.overlayForeground.opacity(0.1))
        }
        .background {
            // Probe the whole exchange row's vertical extent (document coords) so
            // `shouldExpandResponse` knows which rows fall inside the keep-rendered
            // window. Document coords are scroll-invariant, so this only fires on
            // real layout changes, not while scrolling.
            if virtualizationActive {
                GeometryReader { geo in
                    let f = geo.frame(in: .named(Self.chatScrollSpace))
                    Color.clear.preference(
                        key: ExchangeExtentPreferenceKey.self,
                        value: [ExchangeExtentInfo(id: exchange.id, minY: f.minY, maxY: f.maxY)]
                    )
                }
            }
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
            // Stuck-after-stop pill: appears when the user clicked Stop but the
            // bridge hasn't emitted its result within ~3s (typical ack is sub-second).
            // Surfaces a Reset that fully tears down the upstream session — the
            // only escape hatch from a hung Claude/Codex call. Wrapped in
            // TimelineView so the elapsed check refreshes once a second
            // without an explicit timer.
            stuckAfterStopPill

            // Editing-message pill: appears above the input when the user
            // clicks the pencil on a past bubble. The same input field is
            // reused for editing so voice / select-all / paste all just work.
            if editingExchangeId != nil {
                editingMessagePill
                    .padding(.bottom, 6)
            }

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
                        Text(followUpPlaceholder)
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
                        focusRequest: editFocusToken,
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

    /// True while a turn is in flight for this window (streaming tokens or
    /// running tools). Used to suspend the per-history-bubble geometry probes
    /// that feed the stacked-bubble peek overlay — see `chatExchangeView`.
    /// Those probes re-measure every history bubble on every layout pass, an
    /// O(history) cost paid at the streaming refresh rate; the peek overlay
    /// simply doesn't update mid-turn (the user is pinned to the bottom while
    /// a response streams).
    private var isTurnActive: Bool {
        isLoading || currentMessage?.isStreaming == true
    }

    private var followUpPlaceholder: String {
        if editingExchangeId != nil {
            return "Edit your message…"
        }
        if isLoading && isThisSessionStreaming {
            return "Type next question (queued)..."
        }
        return "Ask follow up..."
    }

    /// Pill above the follow-up input that surfaces when the bridge hasn't
    /// honored a Stop within `ChatProvider.stuckSessionWarnThreshold` seconds.
    /// Wraps in a `TimelineView` so the elapsed check refreshes ~1× / sec
    /// without us owning a timer. Hidden once `pendingInterruptStartedAt` is
    /// cleared by ChatProvider (bridge ack'd or session reset).
    @ViewBuilder
    private var stuckAfterStopPill: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            if let startedAt = streaming.pendingInterruptStartedAt,
               context.date.timeIntervalSince(startedAt) >= 3.0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundColor(.orange)

                    Text("Previous request is still cleaning up")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundColor(FazmColors.overlayForeground.opacity(0.85))

                    Spacer(minLength: 4)

                    Button(action: { onResetStuckSession?() }) {
                        Text("Reset session")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundColor(FazmColors.overlayForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(FazmColors.overlayForeground.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Tear down the stuck session and start fresh")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.orange.opacity(0.30), lineWidth: 0.5)
                        )
                )
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: streaming.pendingInterruptStartedAt)
    }

    /// Pill above the follow-up input that signals "you are editing a past
    /// message; submitting will rewind the conversation here." X cancels.
    private var editingMessagePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundColor(FazmColors.purplePrimary)

            Text("Editing message")
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(FazmColors.overlayForeground.opacity(0.85))

            EditMessageInfoButton()

            Spacer(minLength: 4)

            Button(action: cancelEditingMessage) {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 12)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel edit")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(FazmColors.purplePrimary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(FazmColors.purplePrimary.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    /// Stage a past message for editing in the main follow-up input. The
    /// pencil click that triggers this came from `ExpandableQuestionBubble`.
    /// We snapshot whatever the user had in the input + their attachments so
    /// Cancel can restore them.
    private func beginEditingMessage(exchangeId: String, originalText: String) {
        // If we're already editing something else, treat this as switching
        // targets — keep the original snapshot of the user's draft.
        if editingExchangeId == nil {
            preEditFollowUpText = followUpText
            preEditAttachments = input.pendingAttachments
        }
        editingExchangeId = exchangeId
        input.pendingAttachments = []  // edit path is text-only
        followUpText = originalText
        // Bump the focus token so FazmTextEditor takes first-responder. Doing
        // this in the same render pass as setting `followUpText` makes the
        // input ready to type into immediately after the pencil click.
        editFocusToken &+= 1
    }

    /// Discard the staged edit. Restores the user's prior draft text and any
    /// attachments they had pending before the pencil click.
    private func cancelEditingMessage() {
        editingExchangeId = nil
        followUpText = preEditFollowUpText
        input.pendingAttachments = preEditAttachments
        preEditFollowUpText = ""
        preEditAttachments = []
    }

    private func sendFollowUp() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Edit-and-resubmit path: route through `onEditMessage` (truncate +
        // resubmit) instead of the normal follow-up. Attachments don't carry
        // through an edit — the resubmit is text-only by design.
        if let editId = editingExchangeId {
            guard !trimmed.isEmpty else { return }
            followUpText = ""
            input.pendingAttachments = []
            editingExchangeId = nil
            preEditFollowUpText = ""
            preEditAttachments = []
            onEditMessage?(editId, trimmed)
            return
        }

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
/// When `onBeginEdit` is provided, a pencil button (revealed on hover) lets the
/// user start editing this message. Editing happens in the main follow-up input
/// at the bottom of the conversation (with an "editing" pill above it); the
/// bubble itself stays put so the original message remains visible.
private struct ExpandableQuestionBubble: View {
    let question: String
    var exchangeId: UUID
    /// Fires when the user clicks the pencil. The parent (AIResponseView)
    /// loads the message text into the follow-up input and shows the edit
    /// pill; it does NOT truncate or resubmit until the user actually hits
    /// send on the input.
    var onBeginEdit: ((_ exchangeId: String, _ originalText: String) -> Void)?

    @State private var isExpanded = false
    @State private var isBubbleHovered = false

    private var canEdit: Bool {
        onBeginEdit != nil
    }

    /// PERF FIX 2026-05-28: the original implementation called
    /// `NSString.boundingRect(with:options:attributes:)` on the FULL question
    /// text on EVERY body re-evaluation. With users pasting whole conversations
    /// (40 KB+) into prompts, that single measurement pegged the main thread;
    /// across multiple bubbles × 60Hz re-renders it caused the
    /// `ResolvedStyledText.modifyTransition` storm. A fast character/newline
    /// heuristic is fine here — we just need to know whether the bubble
    /// overflows ~2 visual lines to show the expand button.
    private var needsExpansion: Bool {
        // ~70 chars per line at fontSize 13, width 350; 2 lines ≈ 140 chars.
        // Or any explicit newline indicates a multi-line message.
        return question.count > 140 || question.contains("\n")
    }

    /// Cap what SwiftUI's SelectableText measures when collapsed. `.fixedSize`
    /// on the SelectableText forces it to measure the full string before
    /// `.lineLimit(2)` clips display — devastating with 40 KB prompts. While
    /// collapsed we only feed it the first 600 chars (plenty for 2 visual
    /// lines); expansion uses the full string.
    private var displayedQuestion: String {
        if isExpanded { return question }
        if question.count <= 600 { return question }
        // Take first 600 chars or up to the second newline, whichever is shorter.
        if let secondNewline = question.range(of: "\n", options: [], range: question.range(of: "\n")?.upperBound..<question.endIndex) {
            let upTo = min(secondNewline.lowerBound, question.index(question.startIndex, offsetBy: 600))
            return String(question[question.startIndex..<upTo])
        }
        return String(question.prefix(600))
    }

    var body: some View {
        displayView
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FazmColors.overlayForeground.opacity(0.1))
            .cornerRadius(8)
    }

    private var displayView: some View {
        HStack(alignment: .top, spacing: 4) {
            SelectableText(
                text: displayedQuestion,
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
                    onBeginEdit?(exchangeId.uuidString, question)
                }
            )
        }
        // Detect hover over the whole bubble row (not just the button strip)
        // so the copy / edit / info icons reveal wherever the cursor is.
        .contentShape(Rectangle())
        .onHover { isBubbleHovered = $0 }
    }
}

/// Small info icon shown next to the "Editing message" pill. Hovering reveals
/// the disclaimer about replay fidelity in a popover, so the caveat doesn't
/// take up vertical space inline.
private struct EditMessageInfoButton: View {
    @State private var showHint = false

    var body: some View {
        Image(systemName: "info.circle")
            .scaledFont(size: 11)
            .foregroundColor(.secondary)
            .frame(width: 16, height: 16)
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
    /// Whether the user has a cached Claude OAuth token. Mirrored from
    /// `ChatProvider.isClaudeConnected` via `FloatingControlBarState` so we don't
    /// have to plumb `ChatProvider` into this leaf view. Default is `true` so
    /// surfaces that don't mirror the state (none today) don't accidentally
    /// surface a "Connect…" affordance.
    var isClaudeConnected: Bool = true
    /// Triggered when the user picks a Claude model while Claude is unconnected.
    /// The bar window wires this to `chatProvider.startClaudeAuth()`, mirroring
    /// the Codex pattern (kick off OAuth directly from the picker, no chooser sheet).
    var onConnectClaude: (() -> Void)?
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

    private func isClaudeModel(_ id: String) -> Bool {
        // Claude IDs come in several shapes in the picker:
        //   - Canonical: "claude-opus-4-7", "claude-sonnet-4-6"
        //   - Plain aliases: "haiku", "sonnet", "opus"
        //   - Bracketed variants: "sonnet[1m]"
        // Gemini IDs always start with "gemini-"; Codex IDs with "gpt-".
        // Neither contains "haiku", "sonnet", or "opus" as substrings, so the
        // substring check below safely scopes to the Claude family.
        if id.hasPrefix("claude-") { return true }
        if id.contains("haiku") { return true }
        if id.contains("sonnet") { return true }
        if id.contains("opus") { return true }
        return false
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
                    let needsClaudeAuth = isClaudeModel(model.id) && !isClaudeConnected
                    if needsClaudeAuth {
                        if let localModel {
                            localModel.wrappedValue = model.id
                        }
                        shortcutSettings.selectedModel = model.id
                        onConnectClaude?()
                        return
                    }
                    if let localModel {
                        localModel.wrappedValue = model.id
                    }
                    // Always write through to the global default so new pop-outs
                    // and the floating bar inherit the most recent model choice.
                    shortcutSettings.selectedModel = model.id
                } label: {
                    // Surface the "— Connect…" affordance even for the currently-
                    // selected model. Claude is the default model in this app, so
                    // a checkmark-only state would hide the only re-auth handle
                    // when the user's Claude credentials lapse.
                    if isClaudeModel(model.id) && !isClaudeConnected {
                        Label(model.label + " — Connect…", systemImage: "person.badge.key")
                    } else if model.id.hasPrefix("gpt-") && codexBackend.authMode == "none" {
                        Label(model.label + " — Connect…", systemImage: "person.badge.key")
                    } else if selectedModelId == model.id {
                        Label(model.label, systemImage: "checkmark")
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

// MARK: - Running Tool Label

/// Header label that names the in-flight tool so the user can tell a working
/// agent from a hung one. A bare "using tools" label was indistinguishable
/// from a dead session during long calls (45s Terminal execs, 30s screen
/// captures on slow Macs), which led some users to click the Report Issue
/// button mid-task. We show the specific tool name and start counting elapsed
/// seconds after 10s so the user can see real work is happening.
struct RunningToolLabel: View {
    let toolNames: [String]

    @State private var startedAt: Date = Date()
    @State private var trackedSignature: String = ""
    @State private var now: Date = Date()
    /// Timer fires every 1s while a tool is running so the elapsed counter
    /// stays current. Reset whenever the set of running tools changes.
    private let ticker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(label)
            .scaledFont(size: 14)
            .foregroundColor(.secondary)
            .onAppear {
                trackedSignature = signature
                startedAt = Date()
                now = startedAt
            }
            .onChange(of: signature) { _, newSignature in
                trackedSignature = newSignature
                startedAt = Date()
                now = startedAt
            }
            .onReceive(ticker) { tick in
                now = tick
            }
    }

    /// Stable identity for the current set of running tools. When this changes,
    /// we treat it as a new tool starting and reset the elapsed timer.
    private var signature: String {
        toolNames.sorted().joined(separator: ",")
    }

    private var label: String {
        let elapsed = Int(now.timeIntervalSince(startedAt))
        let body: String
        if toolNames.count == 1 {
            body = "running \(humanizedToolName(toolNames[0]))…"
        } else {
            body = "using \(toolNames.count) tools…"
        }
        // Only surface seconds after 10s so quick tool calls don't get a
        // distracting counter. Once visible, it updates every second.
        return elapsed >= 10 ? "\(body) \(elapsed)s" : body
    }

    /// Map a raw tool name to a label the user understands. Falls back to the
    /// raw name so newly added tools just show their internal id rather than
    /// silently disappearing from the indicator.
    private func humanizedToolName(_ name: String) -> String {
        switch name {
        case "capture_screenshot": return "screen capture"
        case "execute_sql": return "database query"
        case "speak_response": return "voice response"
        case "ask_followup": return "follow-up prompt"
        case "query_browser_profile", "extract_browser_profile": return "browser profile"
        case "edit_browser_profile": return "browser profile edit"
        case "save_observer_card": return "saving card"
        case "set_user_preferences": return "preferences update"
        default:
            if name.hasPrefix("routines_") { return "routine \(name.dropFirst("routines_".count))" }
            if name.hasPrefix("mcp__") {
                // mcp__server__tool → "tool" (last segment)
                if let lastSeparator = name.range(of: "__", options: .backwards) {
                    return String(name[lastSeparator.upperBound...])
                }
            }
            return name
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
        HStack(spacing: 4) {
            Button(action: sendReport) {
                Image(systemName: showSent ? "checkmark" : "exclamationmark.triangle.fill")
                    .scaledFont(size: isHanging ? 13 : 11)
                    .foregroundColor(showSent ? .green : (isHanging ? .orange : .secondary))
                    .opacity(flashOpacity)
                    .scaleEffect(flashScale)
                    .shadow(color: isHanging ? .orange.opacity(flashOpacity * 0.9) : .clear, radius: 6)
                    // Value-based animation: gates auto-close the transaction
                    // when isHanging or visibility flips. Replaces the previous
                    // `withAnimation(.repeatForever) { flashOpacity = 0.05 }` —
                    // see Extensions/WindowVisibility.swift.
                    .animation(
                        isHanging && windowIsVisible
                            ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                            : .default,
                        value: flashOpacity
                    )
                    .animation(
                        isHanging && windowIsVisible
                            ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                            : .default,
                        value: flashScale
                    )
            }
            .buttonStyle(.plain)
            .disabled(showSent)
            .floatingHint(showSent ? "Report sent!" : "Report an issue")

            // Visible confirmation pill: an icon swap alone was too easy to miss,
            // which led some users to click the button twice (the second click
            // was harmless but produced a duplicate Sentry event). Now we show
            // an explicit "Report sent" label for ~2s after the click.
            if showSent {
                Text("Report sent")
                    .scaledFont(size: 11)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.green.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.green.opacity(0.35), lineWidth: 0.5)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onChange(of: isHanging) { _, _ in syncFlash() }
        .onChange(of: windowIsVisible) { _, _ in syncFlash() }
    }

    /// Sets the target values; the value-based `.animation(...)` modifiers on
    /// the Image decide whether to repeat-forever (gates open) or snap to
    /// default (gates closed). No `withAnimation` blocks — those leak the
    /// animation transaction across the whole subtree, which forces every
    /// `.defaultScrollAnchor` re-pin to animate and the completed markdown's
    /// `ResolvedStyledText` to re-encode every display cycle.
    private func syncFlash() {
        if isHanging && windowIsVisible {
            flashOpacity = 0.05
            flashScale = 1.15
        } else {
            flashOpacity = 1.0
            flashScale = 1.0
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

// MARK: - Response virtualization preferences

/// Vertical extent of one archived exchange row in chat-content (document) coords.
struct ExchangeExtentInfo: Equatable {
    let id: UUID
    let minY: CGFloat
    let maxY: CGFloat
}

private struct ExchangeExtentPreferenceKey: PreferenceKey {
    static var defaultValue: [ExchangeExtentInfo] = []
    static func reduce(value: inout [ExchangeExtentInfo], nextValue: () -> [ExchangeExtentInfo]) {
        value.append(contentsOf: nextValue())
    }
}

/// Measured rendered height of one expanded AI response block.
struct ResponseHeightInfo: Equatable {
    let id: UUID
    let height: CGFloat
}

private struct ResponseHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [ResponseHeightInfo] = []
    static func reduce(value: inout [ResponseHeightInfo], nextValue: () -> [ResponseHeightInfo]) {
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
        private var lastOriginY: CGFloat?
        private var lastViewportHeight: CGFloat?

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
            let originY = clipBounds.origin.y
            let viewportHeight = clipBounds.height
            let visibleMaxY = originY + viewportHeight
            let threshold: CGFloat = 80
            // If the whole document fits inside the viewport, there is nothing
            // to scroll and the user is by definition seeing the bottom — even
            // if NSScrollView happens to be holding a transient origin.y from a
            // mid-animation reflow (e.g. the floating bar growing from compact
            // to conversation mode leaves origin.y way below the small initial
            // doc until layout settles). Without this short-circuit a fresh
            // chat would briefly flash the scroll-down button.
            let atBottom = documentHeight <= viewportHeight
                ? true
                : visibleMaxY >= documentHeight - threshold

            defer {
                lastOriginY = originY
                lastViewportHeight = viewportHeight
            }

            // Distinguish user scroll from layout churn. There are two layout
            // events that look like "scroll up" to a naive at-bottom check but
            // are not user-initiated:
            //
            //   1. Content growth: a tool-call block, thinking block, or
            //      streamed text delta enlarges documentHeight before SwiftUI's
            //      .defaultScrollAnchor(.bottom) advances origin.y to match. In
            //      that frame visibleMaxY trails documentHeight even though
            //      origin.y is unchanged.
            //
            //   2. Viewport resize: the floating bar expands from compact to
            //      conversation mode (and the pop-out window animates open) by
            //      growing/shrinking the host window. origin.y can shift wildly
            //      across multiple frames as the clip view re-clamps against a
            //      changing viewport height even though the user never touched
            //      the scrollwheel.
            //
            // Without this guard, either event would flip shouldFollowContent
            // false, briefly flash the scroll-down button and (in the worst
            // case) leave it stuck until the next user action. Rule: if
            // origin.y didn't decrease *or* the viewport height changed between
            // checks, treat it as layout churn and don't flip. A real
            // user-scroll-up always lowers origin.y while the viewport height
            // stays constant, so this never blocks the intentional mid-stream
            // detach the user wants when they scroll back to read history.
            if atBottom == false,
               lastReportedValue == true,
               let prevOrigin = lastOriginY,
               let prevHeight = lastViewportHeight {
                let originStable = originY >= prevOrigin - 0.5
                let viewportChanged = abs(viewportHeight - prevHeight) > 0.5
                if originStable || viewportChanged {
                    coalesceWorkItem?.cancel()
                    return
                }
            }

            guard atBottom != lastReportedValue else { return }
            coalesceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onScrollPositionChange(atBottom)
            }
            coalesceWorkItem = work
            // Eagerly record the intended value so a follow-up check inside the
            // 60ms coalesce window sees the new "true" state and the suppress
            // rule above can recognize true→false transients even before the
            // work item fires.
            lastReportedValue = atBottom
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
