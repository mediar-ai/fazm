import Cocoa
import Combine
import SwiftUI

/// NSWindow subclass for the floating control bar.
class FloatingControlBarWindow: NSWindow, NSWindowDelegate {
    private static let positionKey = "FloatingControlBarPosition"
    private static let sizeKey = "FloatingControlBarSize"
    private static let defaultSize = NSSize(width: 40, height: 10)
    private static let minBarSize = NSSize(width: 40, height: 10)
    /// Extra vertical offset (pt) applied to the collapsed pill so it sits slightly higher.
    private static let collapsedYOffset: CGFloat = 24
    static let expandedBarSize = NSSize(width: 210, height: 50)
    private static let maxBarSize = NSSize(width: 1200, height: 1000)
    private static let expandedWidth: CGFloat = 559
    /// Minimum window height when AI response first appears.
    private static let minResponseHeight: CGFloat = 300
    /// Base height used as the reference for 2× cap.
    private static let defaultBaseResponseHeight: CGFloat = 323
    /// Overhead (px) added to measured scroll content to account for control bar, header, follow-up input, and padding.

    let state = FloatingControlBarState()
    private var hostingView: NSHostingView<AnyView>?
    private var isResizingProgrammatically = false
    private var isUserDragging = false
    /// Set by ResizeHandleNSView while the user is manually dragging the corner.
    /// Prevents the response-height observer from fighting manual resize.

    /// Persist the current window size as the user's preferred chat height.
    func saveUserSize() {
        guard state.streaming.showingAIResponse else { return }
        UserDefaults.standard.set(
            NSStringFromSize(self.frame.size), forKey: FloatingControlBarWindow.sizeKey
        )
    }

    /// Suppresses hover resizes during close animation to prevent position drift.
    private var suppressHoverResize = false
    /// The canonical bottom-edge Y position. Set once during initial positioning and
    /// only updated by explicit user drag. ALL resizing reads from this value instead
    /// of frame.origin.y, making vertical drift structurally impossible.
    private var canonicalBottomY: CGFloat = 0
    private var inputHeightCancellable: AnyCancellable?
    private var resizeWorkItem: DispatchWorkItem?
    /// Token incremented each time a windowDidResignKey dismiss animation starts.
    /// Checked in the completion block so a new PTT query can cancel a stale close.
    private var resignKeyAnimationToken: Int = 0
    /// The target origin of an in-progress close/restore animation, set in
    /// closeAIConversation() and cleared when the animation settles.
    /// Used by savePreChatCenterIfNeeded() to snap to the correct pill position
    /// if a new PTT query fires while the restore animation is still running.
    private var pendingRestoreOrigin: NSPoint?
    /// Global mouse monitor that detects clicks outside the app to dismiss the chat.
    private var globalClickOutsideMonitor: Any?
    /// Local monitor for Cmd+N new chat shortcut.
    private var cmdNMonitor: Any?
    /// When true, clicks outside the app don't dismiss the chat (e.g. browser tool running).
    var suppressClickOutsideDismiss = false

    // MARK: - Window-level drag tracking
    /// Screen-space mouse position at the start of a potential drag gesture.
    private var dragStartScreenLocation: NSPoint?
    /// Window origin at the start of a potential drag gesture.
    private var dragStartWindowOrigin: NSPoint?
    /// True once the mouse has moved past the drag threshold during a gesture.
    private var isDragGestureActive = false
    /// Minimum distance (pt) the mouse must move before a drag gesture activates.
    private static let dragThreshold: CGFloat = 4

    var onPlayPause: (() -> Void)?
    var onAskAI: (() -> Void)?
    var onHide: (() -> Void)?
    var onSendQuery: ((String, [ChatAttachment]) -> Void)?
    var onInterruptAndFollowUp: ((String) -> Void)?
    var onStopAgent: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onResetSession: (() -> Void)?
    /// Fired when the user clicks the fork button in the chat header. The
    /// handler (set externally, alongside `onResetSession`) is responsible for
    /// calling `ACPBridge.forkSession(fromKey:, toKey:)` for the floating
    /// session. The window controller then clears the local chat UI so the
    /// user has a fresh prompt while the agent retains prior context.
    var onForkChat: (() -> Void)?
    var onConnectClaude: (() -> Void)?
    var onCodexLogin: (() -> Void)?
    var onChatObserverCardAction: ((Int64, String) -> Void)?
    /// Workspace selection callback. Pass `nil` to open the directory picker
    /// (NSOpenPanel). Pass a path to switch directly to that workspace.
    var onChangeWorkspace: ((String?) -> Void)?
    /// Edit a previous user message in chat history and resubmit (truncates here).
    var onEditMessage: ((_ messageId: String, _ newText: String) -> Void)?

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType = .buffered, defer flag: Bool = false
    ) {
        let initialRect = NSRect(origin: .zero, size: FloatingControlBarWindow.minBarSize)

        super.init(
            contentRect: initialRect,
            styleMask: [.borderless],
            backing: backingStoreType,
            defer: flag
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.delegate = self
        self.minSize = FloatingControlBarWindow.minBarSize
        self.maxSize = FloatingControlBarWindow.maxBarSize
        self.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing

        setupViews()

        // Cmd+N local monitor — intercepts before text fields consume the event
        cmdNMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 45 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                self?.startNewChat()
                return nil // consume the event
            }
            return event
        }

        if ShortcutSettings.shared.draggableBarEnabled,
           let savedPosition = UserDefaults.standard.string(forKey: FloatingControlBarWindow.positionKey) {
            let savedCenter = NSPointFromString(savedPosition)
            // Saved value is center X — convert back to origin for the pill width.
            let pillWidth = FloatingControlBarWindow.minBarSize.width
            let targetScreen = NSScreen.main ?? NSScreen.screens.first
            let visibleFrame = targetScreen?.visibleFrame ?? .zero
            let defaultY = visibleFrame.minY + 20
            let origin = NSPoint(x: savedCenter.x - pillWidth / 2, y: defaultY + FloatingControlBarWindow.collapsedYOffset)
            // Verify saved position is on a visible screen
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(NSPoint(x: origin.x + 14, y: origin.y + 14)) }
            if onScreen {
                self.setFrameOrigin(origin)
                canonicalBottomY = defaultY
            } else {
                centerOnMainScreen()
            }
        } else {
            centerOnMainScreen()
        }

    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - Window-level drag via sendEvent

    /// Returns true if the view (or any ancestor) is a text input or resize handle
    /// that should not trigger window dragging.
    private func isInteractiveView(_ view: NSView?) -> Bool {
        var current = view
        while let v = current {
            if v is NSTextView || v is NSTextField || v is ResizeHandleNSView || v is PushToTalkMouseView { return true }
            current = v.superview
        }
        return false
    }

    override func sendEvent(_ event: NSEvent) {
        if ShortcutSettings.shared.draggableBarEnabled {
            switch event.type {
            case .leftMouseDown:
                let hitView = contentView?.hitTest(event.locationInWindow)
                if isInteractiveView(hitView) {
                    NSLog("FloatingBar drag: mouseDown on interactive view (%@), skipping drag", String(describing: type(of: hitView!)))
                } else {
                    dragStartScreenLocation = NSEvent.mouseLocation
                    dragStartWindowOrigin = frame.origin
                    isDragGestureActive = false
                }
            case .leftMouseDragged:
                if let startScreen = dragStartScreenLocation,
                   let startOrigin = dragStartWindowOrigin {
                    let currentScreen = NSEvent.mouseLocation
                    let dx = currentScreen.x - startScreen.x
                    if !isDragGestureActive {
                        if abs(dx) > Self.dragThreshold {
                            isDragGestureActive = true
                            isUserDragging = true
                            state.isDragging = true
                            NSLog("FloatingBar drag: started at x=%.0f", startOrigin.x)
                        }
                    }
                    if isDragGestureActive {
                        let newOrigin = NSPoint(x: startOrigin.x + dx, y: frame.origin.y)
                        NSAnimationContext.beginGrouping()
                        NSAnimationContext.current.duration = 0
                        setFrameOrigin(newOrigin)
                        NSAnimationContext.endGrouping()
                        return // consume the event — don't pass through to subviews
                    }
                }
            case .leftMouseUp:
                if isDragGestureActive {
                    NSLog("FloatingBar drag: ended at x=%.0f (moved %.0fpt)", frame.origin.x, frame.origin.x - (dragStartWindowOrigin?.x ?? 0))
                    isUserDragging = false
                    state.isDragging = false
                }
                dragStartScreenLocation = nil
                dragStartWindowOrigin = nil
                isDragGestureActive = false
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        // Esc closes the AI conversation only — never hides the entire bar
        if event.keyCode == 53 { // Escape
            if state.streaming.showingAIConversation {
                closeAIConversation()
            }
            return
        }
        super.keyDown(with: event)
    }

    var onEnqueueMessage: ((String) -> Void)?
    var onSendNowQueued: ((QueuedMessage) -> Void)?
    var onDeleteQueued: ((QueuedMessage) -> Void)?
    var onClearQueue: (() -> Void)?
    var onReorderQueue: ((IndexSet, Int) -> Void)?

    private func setupViews() {
        let swiftUIView = FloatingControlBarView(
            window: self,
            onPlayPause: { [weak self] in self?.onPlayPause?() },
            onAskAI: { [weak self] in self?.handleAskAI() },
            onHide: { [weak self] in self?.hideBar() },
            onSendQuery: { [weak self] message, attachments in self?.onSendQuery?(message, attachments) },
            onCloseAI: { [weak self] in self?.closeAIConversation() },
            onNewChat: { [weak self] in self?.startNewChat() },
            onFork: { [weak self] in self?.forkChat() },
            onInterruptAndFollowUp: { [weak self] message in self?.onInterruptAndFollowUp?(message) },
            onEnqueueMessage: { [weak self] message in self?.onEnqueueMessage?(message) },
            onSendNowQueued: { [weak self] item in self?.onSendNowQueued?(item) },
            onDeleteQueued: { [weak self] item in self?.onDeleteQueued?(item) },
            onClearQueue: { [weak self] in self?.onClearQueue?() },
            onReorderQueue: { [weak self] source, dest in self?.onReorderQueue?(source, dest) },
            onStopAgent: { [weak self] in self?.onStopAgent?() },
            onPopOut: { [weak self] in self?.onPopOut?() },
            onConnectClaude: { [weak self] in self?.onConnectClaude?() },
            onCodexLogin: { [weak self] in self?.onCodexLogin?() },
            onChatObserverCardAction: { [weak self] activityId, action in self?.onChatObserverCardAction?(activityId, action) },
            onChangeWorkspace: { [weak self] path in self?.onChangeWorkspace?(path) },
            onEditMessage: { [weak self] messageId, newText in self?.onEditMessage?(messageId, newText) }
        )
        .environmentObject(state)
        .environmentObject(state.streaming)
        .environmentObject(state.input)
        .environmentObject(state.voice)
        .environmentObject(state.workspace)
        .environmentObject(state.tutorial)

        hostingView = NSHostingView(rootView: AnyView(
            swiftUIView
                .withFontScaling()
                .trackWindowVisibility()
        ))

        // CRITICAL: Use a container view instead of making NSHostingView the contentView directly.
        // When NSHostingView IS the contentView of a borderless window, it tries to negotiate
        // window sizing through updateWindowContentSizeExtremaIfNecessary and updateAnimatedWindowSize,
        // causing re-entrant constraint updates that crash in _postWindowNeedsUpdateConstraints.
        // Wrapping in a container breaks that "I own this window" relationship.
        //
        // sizingOptions: Remove .intrinsicContentSize so the hosting view can expand beyond
        // its SwiftUI ideal size. Remove .minSize so the hosting view can't auto-resize the
        // window when content changes (which anchors from top-left and breaks canonicalBottomY).
        // Keep .maxSize only. All window sizing is controlled explicitly via resizeAnchored().
        let container = NSView()
        self.contentView = container

        if let hosting = hostingView {
            // Only keep .maxSize — removing .minSize prevents the hosting view from
            // force-resizing the window when SwiftUI content changes (e.g. pill → input).
            // That auto-resize anchors from top-left, pushing origin.y below canonicalBottomY
            // and causing the "sticking to bottom" glitch on first PTT expansion.
            hosting.sizingOptions = [.maxSize]
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        // Re-validate position when monitors are connected/disconnected
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.validatePositionOnScreenChange()
            }
        }
    }

    // MARK: - AI Actions

    private func handleAskAI() {
        if state.streaming.showingAIConversation && !state.streaming.showingAIResponse {
            // Already showing input, close it
            closeAIConversation()
        } else if state.streaming.showingAIConversation && state.streaming.showingAIResponse {
            // Showing response — focus the follow-up input instead of closing
            makeKeyAndOrderFront(nil)
            focusInputField()
        } else {
            AnalyticsManager.shared.floatingBarAskFazmOpened(source: "button")
            onAskAI?()
        }
    }

    /// Focus the text input field by finding the NSTextView or NSTextField in the view hierarchy.
    /// Returns `true` if a text field was found and focused.
    @discardableResult
    func focusInputField() -> Bool {
        guard let contentView = self.contentView else { return false }
        // Find the first editable text field (NSTextView from FazmTextEditor or NSTextField from SwiftUI TextField)
        func findTextField(in view: NSView) -> NSView? {
            if let textView = view as? NSTextView, textView.isEditable { return textView }
            if let textField = view as? NSTextField, textField.isEditable { return textField }
            for subview in view.subviews {
                if let found = findTextField(in: subview) { return found }
            }
            return nil
        }
        if let field = findTextField(in: contentView) {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(field)
            return true
        }
        return false
    }

    func closeAIConversation() {
        removeGlobalClickOutsideMonitor()
        suppressClickOutsideDismiss = false
        state.isCollapsed = false
        self.alphaValue = 1.0
        AnalyticsManager.shared.floatingBarAskFazmClosed()

        // End tutorial chat guide if active
        if state.tutorial.isTutorialChatActive {
            TutorialChatGuide.shared.finish(barState: state)
        }

        // Cancel any in-flight chat streaming to prevent re-expansion
        FloatingControlBarManager.shared.cancelChat()


        // Cancel PTT if in follow-up mode
        if state.voice.isVoiceFollowUp {
            PushToTalkManager.shared.cancelListening()
        }

        // Snapshot the conversation before clearing so user can resume it later
        if let msg = state.streaming.currentAIMessage, !msg.text.isEmpty {
            var fullHistory = state.streaming.chatHistory
            if !state.streaming.displayedQuery.isEmpty {
                fullHistory.append(FloatingChatExchange(question: state.streaming.displayedQuery, aiMessage: msg))
            }
            if !fullHistory.isEmpty {
                let lastExchange = fullHistory.last!
                state.lastConversation = (
                    history: Array(fullHistory.dropLast()),
                    lastQuestion: lastExchange.question,
                    lastMessage: lastExchange.aiMessage
                )
            }
        }

        // Preserve unsent input text so it survives a dismiss-without-sending
        if !state.input.aiInputText.isEmpty && state.streaming.currentAIMessage == nil {
            state.input.draftInputText = state.input.aiInputText
        }

        // Clear conversation state instantly — no fade.
        // Previously this was wrapped in withAnimation(.easeOut(duration: 0.2))
        // and the window shrink was deferred 0.06s then ran a 0.35s animation,
        // which left an empty translucent (frosted) window visible for ~200ms
        // before the frame collapsed to the pill. The user perceived that as
        // "going gray, then closing." Snap straight to the pill instead.
        state.streaming.showingAIConversation = false
        state.streaming.showingAIResponse = false
        state.input.aiInputText = ""
        state.streaming.currentAIMessage = nil
        state.streaming.chatHistory = []
        state.voice.isVoiceFollowUp = false
        state.voice.voiceFollowUpTranscript = ""

        // Always restore to pill — Smart TV only shows when dialog is open.
        let size = FloatingControlBarWindow.minBarSize
        let restoreOrigin = NSPoint(
            x: defaultPillOrigin(followFocus: false).x,
            y: canonicalBottomY + FloatingControlBarWindow.collapsedYOffset
        )
        // NOTE: offset applied here because this path doesn't go through originForBottomCenterAnchor

        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        styleMask.remove(.resizable)
        isResizingProgrammatically = true
        pendingRestoreOrigin = nil

        setFrame(NSRect(origin: restoreOrigin, size: size), display: true, animate: false)

        isResizingProgrammatically = false
    }

    // MARK: - Click-Outside Monitor

    /// Installs a global event monitor that fires when the user clicks outside the app.
    /// `windowDidResignKey` only detects in-app focus changes reliably; when the user
    /// clicks on another app or the desktop, `NSApp.currentEvent` doesn't contain a
    /// mouse-down from our process, so the resign-key check misses it.
    private func installGlobalClickOutsideMonitor() {
        removeGlobalClickOutsideMonitor()
        globalClickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible, self.state.streaming.showingAIConversation, !self.suppressClickOutsideDismiss, !self.state.isCollapsed, !self.state.voice.isVoiceListening else { return }
            // Don't dismiss while ACP is listening for agent output (covers tool calls
            // between streamed text — see windowDidResignKey for full reasoning).
            if FloatingControlBarManager.shared.isChatActive { return }
            self.dismissConversationAnimated()
        }
    }

    func removeGlobalClickOutsideMonitor() {
        if let monitor = globalClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickOutsideMonitor = nil
        }
    }

    /// Shared dismiss animation used by both windowDidResignKey (in-app) and global click monitor (cross-app).
    /// Collapses to half height and semi-transparent instead of fully closing.
    private func dismissConversationAnimated() {
        guard state.streaming.showingAIResponse, state.streaming.currentAIMessage != nil else {
            // No response to show — fully close
            closeAIConversation()
            return
        }

        resignKeyAnimationToken += 1
        preCollapseHeight = max(frame.height, FloatingControlBarWindow.minResponseHeight)

        let halfHeight = frame.height / 2
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.5
        })
        resizeAnchored(to: NSSize(width: frame.width, height: halfHeight), makeResizable: false, animated: true)
        // Set isCollapsed AFTER resize to prevent SwiftUI content changes from
        // triggering a top-left-anchored auto-resize before our bottom-anchored resize runs.
        state.isCollapsed = true
    }

    /// Height of the window before it was collapsed (used to restore on focus).
    private var preCollapseHeight: CGFloat = 0

    /// Expand back from collapsed state when the window regains focus.
    /// When `instant` is true, skip the alpha animation (used by PTT to go solid immediately).
    func expandFromCollapsed(instant: Bool = false) {
        guard state.isCollapsed else { return }
        state.isCollapsed = false

        if instant {
            self.alphaValue = 1.0
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 1.0
            })
        }

        if preCollapseHeight > 0 {
            resizeAnchored(to: NSSize(width: frame.width, height: preCollapseHeight), makeResizable: true, animated: true)
        }

        makeKeyAndOrderFront(nil)
    }

    private func hideBar() {
        self.orderOut(nil)
        AnalyticsManager.shared.floatingBarToggled(visible: false, source: state.streaming.showingAIConversation ? "escape_ai" : "bar_button")
        onHide?()
    }

    // MARK: - Public State Updates

    func updateRecordingState(isRecording: Bool, duration: Int, isInitialising: Bool) {
        state.voice.isRecording = isRecording
        state.voice.duration = duration
        state.voice.isInitialising = isInitialising
    }

    func showAIConversation() {
        // Clear stale collapse state so expandFromCollapsed doesn't fire with
        // an outdated preCollapseHeight when the window next becomes key.
        state.isCollapsed = false

        // Check if we have existing conversation to restore — if so, skip the input-only
        // view and go straight to the response/chat view with history visible.
        let hasLastConversation = state.lastConversation != nil
        let hasHistory = !state.streaming.chatHistory.isEmpty
        let shouldShowResponse = hasLastConversation || hasHistory

        // Resize window BEFORE changing state so SwiftUI content doesn't render
        // in the old 28x28 frame (which causes a visible jump).
        if !shouldShowResponse {
            // No history — resize to the small input-only height.
            // 146 = default text editor(40) + overhead(106) — matches the inputViewHeight formula.
            let savedWidth = UserDefaults.standard.string(forKey: FloatingControlBarWindow.sizeKey)
                .map(NSSizeFromString)?.width ?? 0
            let inputWidth = max(FloatingControlBarWindow.expandedWidth, savedWidth)
            let inputSize = NSSize(width: inputWidth, height: 146)
            resizeAnchored(to: inputSize, makeResizable: false, animated: true)
        }
        // When shouldShowResponse is true, we skip the small resize and go straight
        // to response height (done below after restoring state).

        // Restore any draft input that was preserved from a previous dismiss
        let restoredDraft = state.input.draftInputText
        state.input.draftInputText = ""

        // If restoring a conversation, prepare the state.
        if shouldShowResponse {
            if let last = state.lastConversation {
                state.streaming.chatHistory = last.history
                state.streaming.displayedQuery = last.lastQuestion
                state.streaming.currentAIMessage = last.lastMessage
                state.clearLastConversation()
            } else {
                state.streaming.displayedQuery = ""
                state.streaming.currentAIMessage = nil
            }
        }

        // When restoring a conversation, resize to response height immediately so the
        // window is already the right size before SwiftUI content renders.
        if shouldShowResponse {
            resizeToResponseHeight(animated: true)
        }

        // Delay the SwiftUI state change slightly so the window has started expanding
        // before content appears. This prevents the input view from rendering in
        // the still-tiny pill frame and creates a smooth reveal effect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                self.state.streaming.showingAIConversation = true
                self.state.streaming.showingAIResponse = shouldShowResponse
                self.state.streaming.isAILoading = false
                self.state.input.aiInputText = restoredDraft
                if !shouldShowResponse {
                    self.state.streaming.currentAIMessage = nil
                }
                // Match the explicit resize height so the observer doesn't immediately override it
                self.state.input.inputViewHeight = 146
            }
        }
        setupInputHeightObserver()
        installGlobalClickOutsideMonitor()

        // Make the window key so the FazmTextEditor's focusOnAppear can take effect.
        // The text editor itself handles focusing via updateNSView once it's in the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.makeKeyAndOrderFront(nil)
        }

        // Fallback: explicitly focus the input after SwiftUI layout settles.
        // The AutoFocusScrollView.viewDidMoveToWindow() fires once and can miss
        // if the window isn't yet key at that moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.focusInputField()
        }
    }

    func startNewChat() {
        // End tutorial chat guide if active
        if state.tutorial.isTutorialChatActive {
            TutorialChatGuide.shared.finish(barState: state)
        }

        state.streaming.showingAIConversation = true
        state.streaming.chatHistory = []
        state.streaming.displayedQuery = ""
        state.streaming.currentAIMessage = nil
        state.streaming.isAILoading = false
        state.streaming.showingAIResponse = false
        state.input.aiInputText = ""
        state.streaming.suggestedReplies = []
        state.streaming.suggestedReplyQuestion = ""
        state.clearQueue()

        // Clear persisted messages and reset ACP session so restart doesn't reload old chat
        onResetSession?()
        finishChatRefresh()
    }

    /// Branch the current chat into a NEW pop-out window. Leaves the floating
    /// bar conversation intact (source branch continues here), spawns a fresh
    /// detached window bound to a new session key, copies the prior chat
    /// history into the new window for visibility, and asks the bridge to
    /// fork the agent session from "floating" into the new key. The two
    /// branches then diverge on subsequent prompts.
    func forkChat() {
        guard let handler = onForkChat else {
            // No bridge wireup: fall back to plain new-chat semantics so the
            // button does *something* useful instead of going silent.
            startNewChat()
            return
        }
        // Everything is delegated to the manager-installed handler, which has
        // access to ChatProvider and DetachedChatWindowController. The
        // floating bar's own UI state is intentionally untouched so the
        // source branch keeps rendering exactly as it was.
        handler()
    }

    /// Common tail of `startNewChat` and `forkChat`: resize to the input view,
    /// re-install the height observer, and focus the input field.
    private func finishChatRefresh() {

        let savedWidth = UserDefaults.standard.string(forKey: FloatingControlBarWindow.sizeKey)
            .map(NSSizeFromString)?.width ?? 0
        let inputWidth = max(FloatingControlBarWindow.expandedWidth, savedWidth)
        let inputSize = NSSize(width: inputWidth, height: 146)
        resizeAnchored(to: inputSize, makeResizable: false, animated: true)
        state.input.inputViewHeight = 146
        setupInputHeightObserver()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.focusInputField()
        }
    }

    private func setupInputHeightObserver() {
        inputHeightCancellable?.cancel()
        inputHeightCancellable = state.input.$inputViewHeight
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self,
                      self.state.streaming.showingAIConversation,
                      !self.state.streaming.showingAIResponse
                else { return }
                self.resizeToFixedHeight(height)
            }
    }

    func cancelInputHeightObserver() {
        inputHeightCancellable?.cancel()
        inputHeightCancellable = nil
    }

    func updateAIResponse(type: String, text: String) {
        guard state.streaming.showingAIConversation else { return }

        switch type {
        case "data":
            if state.streaming.isAILoading {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.streaming.isAILoading = false
                    state.streaming.showingAIResponse = true
                }
                resizeToResponseHeight(animated: true)
            }
            state.streaming.aiResponseText += text
        case "done":
            withAnimation(.easeOut(duration: 0.2)) {
                state.streaming.isAILoading = false
            }
            if !text.isEmpty {
                state.streaming.aiResponseText = text
            }
        case "error":
            withAnimation(.easeOut(duration: 0.2)) {
                state.streaming.isAILoading = false
            }
            state.streaming.aiResponseText = text.isEmpty ? "An unknown error occurred." : text
        default:
            break
        }
    }

    // MARK: - Window Geometry

    /// Bottom-center: keeps bottom edge at canonicalBottomY, centers horizontally.
    /// Uses the stored canonical Y instead of frame.origin.y to prevent drift.
    /// Adds `collapsedYOffset` when the target size matches `minBarSize` so the
    /// collapsed pill always sits slightly higher than the expanded bar.
    private func originForBottomCenterAnchor(newSize: NSSize) -> NSPoint {
        let yOffset = (newSize == FloatingControlBarWindow.minBarSize)
            ? FloatingControlBarWindow.collapsedYOffset : 0
        return NSPoint(
            x: frame.midX - newSize.width / 2,
            y: canonicalBottomY + yOffset
        )
    }

    private func resizeAnchored(to size: NSSize, makeResizable: Bool, animated: Bool = false) {
        // Cancel any pending resizeToFixedHeight work item to prevent stale resizes
        resizeWorkItem?.cancel()
        resizeWorkItem = nil

        var constrainedSize = NSSize(
            width: max(size.width, FloatingControlBarWindow.minBarSize.width),
            height: max(size.height, FloatingControlBarWindow.minBarSize.height)
        )

        // Clamp height to fit within the screen's visible frame so the window
        // never expands beyond screen bounds.
        if let screenFrame = (self.screen ?? NSScreen.main)?.visibleFrame {
            constrainedSize.height = min(constrainedSize.height, screenFrame.height)
        }

        let newOrigin = originForBottomCenterAnchor(newSize: constrainedSize)

        log("FloatingControlBar: resizeAnchored to \(constrainedSize) origin=\(newOrigin) resizable=\(makeResizable) animated=\(animated) from=\(frame.size) fromOrigin=\(frame.origin) canonicalY=\(canonicalBottomY)")

        if makeResizable {
            styleMask.insert(.resizable)
        } else {
            styleMask.remove(.resizable)
        }

        isResizingProgrammatically = true

        // Force-complete any in-flight _NSWindowTransformAnimation to prevent
        // accumulation of stale animation objects that can cause use-after-free
        // crashes (EXC_BAD_ACCESS in _NSWindowTransformAnimation dealloc) in
        // long-running sessions.
        if animated {
            self.setFrame(self.frame, display: false, animate: false)
        }

        // On macOS 26+ (Tahoe), animated setFrame triggers NSHostingView.updateAnimatedWindowSize
        // which invalidates safe area insets -> view graph -> requestUpdate -> setNeedsUpdateConstraints,
        // causing an infinite constraint update loop. Disable implicit animations
        // during the resize to prevent the updateAnimatedWindowSize code path.
        //
        // Even with that workaround, animated resizes can still throw an uncaught NSException
        // from `_updateStructuralRegionsOnNextDisplayCycle` during the CA transaction commit
        // (NSTextView frame change → tracking-area invalidation → window structural-region
        // update). The exception is intercepted by NSApplicationCrashOnExceptions (enabled by
        // SentrySDK) before any Swift @try/@catch can unwind, so we cannot recover from it.
        // The mitigation is at the call site: callers passing `animated:true` should not be
        // stacking resizes during a streaming response. See `resizeToResponseHeightPublic`
        // and its callers.
        let animDuration: CGFloat = animated ? 0.4 : 0
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = animDuration
        NSAnimationContext.current.allowsImplicitAnimation = false
        NSAnimationContext.current.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.2, 0.9, 0.3, 1.0  // approximates spring(response: 0.4, dampingFraction: 0.8)
        )
        self.setFrame(NSRect(origin: newOrigin, size: constrainedSize), display: true, animate: animated)
        NSAnimationContext.endGrouping()

        if animated {
            // Reset flag after animation duration to prevent overlapping resizes
            DispatchQueue.main.asyncAfter(deadline: .now() + animDuration + 0.05) { [weak self] in
                self?.isResizingProgrammatically = false
            }
        } else {
            self.isResizingProgrammatically = false
        }
    }

    private func resizeToFixedHeight(_ height: CGFloat, animated: Bool = false) {
        resizeWorkItem?.cancel()
        let savedWidth = UserDefaults.standard.string(forKey: FloatingControlBarWindow.sizeKey)
            .map(NSSizeFromString)?.width ?? 0
        let width = max(FloatingControlBarWindow.expandedWidth, savedWidth)
        let size = NSSize(width: width, height: height)
        resizeWorkItem = DispatchWorkItem { [weak self] in
            self?.resizeAnchored(to: size, makeResizable: false, animated: animated)
        }
        if let workItem = resizeWorkItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    /// Resize for hover expand/collapse — anchored from bottom so the pill expands upward.
    func resizeForHover(expanded: Bool) {
        guard !state.streaming.showingAIConversation, !state.voice.isVoiceListening, !suppressHoverResize else { return }
        resizeWorkItem?.cancel()
        resizeWorkItem = nil

        let base = FloatingControlBarWindow.expandedBarSize
        let updateExtra: CGFloat = UpdaterViewModel.shared.updateAvailable ? 30 : 0
        let expandedWithUpdate = NSSize(width: base.width + updateExtra, height: base.height)
        let targetSize = expanded ? expandedWithUpdate : FloatingControlBarWindow.minBarSize

        let newOrigin = originForBottomCenterAnchor(newSize: targetSize)
        styleMask.remove(.resizable)

        if expanded {
            // Expand synchronously so the window is already large enough when
            // SwiftUI re-evaluates body with isHovering=true.
            // Use animate:false to avoid accumulating _NSWindowTransformAnimation
            // objects that can cause use-after-free crashes in long-running sessions.
            isResizingProgrammatically = true
            self.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true, animate: false)
            isResizingProgrammatically = false
        } else {
            // Collapse async to avoid blocking SwiftUI body evaluation during unhover.
            let doResize: () -> Void = { [weak self] in
                guard let self = self else { return }
                self.isResizingProgrammatically = true
                self.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true, animate: false)
                self.isResizingProgrammatically = false
            }
            resizeWorkItem = DispatchWorkItem(block: doResize)
            DispatchQueue.main.async(execute: resizeWorkItem!)
        }
    }

    /// Resize window for PTT state (expanded when listening, compact circle when idle)
    func resizeForPTTState(expanded: Bool) {
        let size = expanded
            ? NSSize(width: FloatingControlBarWindow.expandedWidth, height: FloatingControlBarWindow.expandedBarSize.height)
            : FloatingControlBarWindow.minBarSize
        resizeAnchored(to: size, makeResizable: false, animated: true)
    }

    private func resizeToResponseHeight(animated: Bool = false) {
        let savedSize = UserDefaults.standard.string(forKey: FloatingControlBarWindow.sizeKey)
            .map(NSSizeFromString)
        let width = max(Self.expandedWidth, savedSize?.width ?? Self.expandedWidth)
        let height = max(Self.minResponseHeight, savedSize?.height ?? Self.defaultBaseResponseHeight)
        resizeAnchored(to: NSSize(width: width, height: height), makeResizable: true, animated: animated)
    }

    /// Compute the origin for the collapsed pill.
    /// When dragging is enabled and a saved position exists, returns the user's saved X.
    /// Otherwise falls back to horizontal screen center.
    /// - Parameter followFocus: when true, uses the key window's screen (for opening new
    ///   conversations to follow the user's focus). When false, uses the screen the bar
    ///   is already on (for closing/restoring to avoid jumping away mid-conversation).
    private func defaultPillOrigin(followFocus: Bool = true) -> NSPoint {
        let size = FloatingControlBarWindow.minBarSize
        let targetScreen: NSScreen?
        if followFocus {
            targetScreen = NSScreen.main ?? self.screen ?? NSScreen.screens.first
        } else {
            targetScreen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
        }
        guard let screen = targetScreen else { return .zero }
        let visibleFrame = screen.visibleFrame
        let y = visibleFrame.minY + 20

        // Respect user's saved drag position when draggable bar is enabled.
        // Saved value is center X — convert back to origin for the pill width.
        if ShortcutSettings.shared.draggableBarEnabled,
           let savedPosition = UserDefaults.standard.string(forKey: FloatingControlBarWindow.positionKey) {
            let savedCenter = NSPointFromString(savedPosition)
            let savedCenterX = savedCenter.x
            // Only use saved X if it's on the target screen
            if savedCenterX >= visibleFrame.minX && savedCenterX <= visibleFrame.maxX {
                return NSPoint(x: savedCenterX - size.width / 2, y: y)
            }
        }

        let x = visibleFrame.midX - size.width / 2
        return NSPoint(x: x, y: y)
    }

    /// Center the bar near the bottom of the active monitor (where the foreground app is).
    private func centerOnMainScreen() {
        // NSScreen.main follows the system-wide foreground app's key window
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else {
            self.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.minY + 20  // 20pt from bottom, just above dock
        canonicalBottomY = y
        // Apply collapsed offset so the pill sits slightly higher on initial display
        self.setFrameOrigin(NSPoint(x: x, y: y + FloatingControlBarWindow.collapsedYOffset))
        log("FloatingControlBarWindow: centered at (\(x), \(y)) on screen \(visibleFrame)")
    }

    /// Move the bar to the active monitor (where the foreground app is) if it's on a different screen.
    /// Called when starting a new interaction (PTT, shortcut) so the bar follows the user.
    func moveToActiveScreen() {
        guard let activeScreen = NSScreen.main,
              let currentScreen = self.screen,
              activeScreen != currentScreen else { return }
        let visibleFrame = activeScreen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.minY + 20
        isResizingProgrammatically = true
        canonicalBottomY = y
        setFrameOrigin(NSPoint(x: x, y: y + FloatingControlBarWindow.collapsedYOffset))
        isResizingProgrammatically = false
        log("FloatingControlBarWindow: moved to active screen at (\(x), \(y))")
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: FloatingControlBarWindow.positionKey)
        centerOnMainScreen()
    }

    /// Called when monitors are connected/disconnected. Re-center if the bar is no longer
    /// fully visible on any screen.
    private func validatePositionOnScreenChange() {
        // Non-draggable mode: always restore to default position on screen change
        if !ShortcutSettings.shared.draggableBarEnabled {
            log("FloatingControlBarWindow: non-draggable mode, re-centering after monitor change")
            centerOnMainScreen()
            return
        }

        let barFrame = self.frame
        // Check if the bar's center point is on any visible screen
        let center = NSPoint(x: barFrame.midX, y: barFrame.midY)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        if !onScreen {
            log("FloatingControlBarWindow: bar center \(center) is off-screen after monitor change, re-centering")
            UserDefaults.standard.removeObject(forKey: FloatingControlBarWindow.positionKey)
            centerOnMainScreen()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if state.isCollapsed {
            expandFromCollapsed()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard state.streaming.showingAIConversation else { return }

        // Don't dismiss when already collapsed or during push-to-talk
        guard !state.isCollapsed, !state.voice.isVoiceListening else { return }

        // Only dismiss when the user physically clicks away within our app.
        // Programmatic focus changes — e.g. the AI agent activating a browser
        // window for automation — do NOT produce a mouse-down event, so we
        // leave the conversation open in those cases.
        // Clicks outside the app are handled by the global click-outside monitor
        // (installGlobalClickOutsideMonitor), since NSApp.currentEvent won't
        // contain a mouse-down from another process.
        let eventType = NSApp.currentEvent?.type
        let isMouseClick = eventType == .leftMouseDown
            || eventType == .rightMouseDown
            || eventType == .otherMouseDown
        guard isMouseClick else { return }

        // Don't dismiss while ACP is listening for agent output. isStreaming/isAILoading
        // only cover token streaming and the initial wait — they go false during tool
        // calls (Playwright, Terminal, macos-use, etc.), which can take minutes. Using
        // chatCancellable as the source of truth keeps the conversation open through
        // the entire agent run, including tool execution gaps.
        if FloatingControlBarManager.shared.isChatActive { return }

        dismissConversationAnimated()
    }

    @objc func windowDidMove(_ notification: Notification) {
        // Only persist position when the user is physically dragging the bar.
        // Programmatic moves (resize animations, chat open/close) should not
        // overwrite the saved position — that causes silent drift.
        guard isUserDragging else { return }
        // Drag is horizontal-only — don't update canonicalBottomY from the drag.
        // Only save the horizontal position; vertical is always computed from screen geometry.
        // Save the center X so the position is width-independent.
        // The bar can be dragged while expanded (wide) or collapsed (pill),
        // and restoring from center avoids drift when widths differ.
        UserDefaults.standard.set(
            NSStringFromPoint(NSPoint(x: self.frame.midX, y: self.frame.origin.y)),
            forKey: FloatingControlBarWindow.positionKey
        )
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var clamped = NSSize(
            width: max(frameSize.width, FloatingControlBarWindow.minBarSize.width),
            height: max(frameSize.height, FloatingControlBarWindow.minBarSize.height)
        )
        // Prevent resizing beyond screen bounds.
        if let screenFrame = (sender.screen ?? NSScreen.main)?.visibleFrame {
            clamped.height = min(clamped.height, screenFrame.height)
        }
        return clamped
    }

    func windowDidResize(_ notification: Notification) {
        if !isResizingProgrammatically && state.streaming.showingAIResponse {
            UserDefaults.standard.set(
                NSStringFromSize(self.frame.size), forKey: FloatingControlBarWindow.sizeKey
            )
        }
    }
}

// MARK: - FloatingControlBarManager

/// Singleton manager that owns the floating bar window and coordinates with AppState / ChatProvider.
@MainActor
class FloatingControlBarManager {
    static let shared = FloatingControlBarManager()

    private static let kAskFazmEnabled = "askFazmBarEnabled"

    private var window: FloatingControlBarWindow?
    private var recordingCancellable: AnyCancellable?
    private var durationCancellable: AnyCancellable?
    private var chatCancellable: AnyCancellable?
    /// Per-message @Observable tracker for the currently streaming message.
    /// Drives `state.streaming.isAILoading` and the streaming-completion handler.
    /// Token deltas no longer fire `provider.$messages` (ChatMessage is a
    /// reference type), so this is the only granular signal available.
    private var messageObserver: MessageObserver?
    private var sharedProviderCancellables: [AnyCancellable] = []
    private(set) var chatProvider: ChatProvider?
    private var workspaceObserver: Any?
    private var dequeueObserver: Any?
    private weak var appState: AppState?

    /// PID of the last active app before Fazm. Used to capture that app's window for screenshots.
    private(set) var lastActiveAppPID: pid_t = 0

    /// File URL of a pre-captured screenshot, taken when the bar opens (PTT or keyboard).
    private var pendingScreenshotPath: URL?

    /// Wall-clock time of the last popOutNewChat invocation (uptime seconds).
    /// Used to debounce duplicate creations from rapid global-shortcut presses.
    private var lastPopOutNewChatTime: TimeInterval = 0

    /// Whether the user has enabled the Ask Fazm bar (persisted across launches).
    /// Defaults to true for new users.
    var isEnabled: Bool {
        get {
            // Default to true if never set
            if UserDefaults.standard.object(forKey: Self.kAskFazmEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.kAskFazmEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.kAskFazmEnabled)
        }
    }

    private init() {
        // Track the last active app (before Fazm) so we can screenshot its window
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                self?.lastActiveAppPID = app.processIdentifier
            }
        }
        // Initialize with current frontmost app if it's not us
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveAppPID = frontApp.processIdentifier
        }
    }

    /// Capture the last active app's window immediately (before Fazm's bar covers it).
    /// Stores the file path for use when the query is sent.
    private func captureScreenshotEarly() {
        let targetPID = self.lastActiveAppPID
        pendingScreenshotPath = nil
        Task.detached { [weak self] in
            let url: URL?
            if targetPID != 0 {
                switch ScreenCaptureManager.captureAppWindow(pid: targetPID) {
                case .success(let capturedURL):
                    url = capturedURL
                case .permissionDenied:
                    url = nil
                    let weakSelf = self
                    await MainActor.run {
                        weakSelf?.flagScreenRecordingPermissionLost()
                    }
                }
            } else {
                url = ScreenCaptureManager.captureScreen()
            }
            let weakSelf = self
            await MainActor.run {
                weakSelf?.pendingScreenshotPath = url
            }
        }
    }

    /// Flag that Screen Recording permission is missing/stale so the user sees a prompt.
    @MainActor
    private func flagScreenRecordingPermissionLost() {
        guard let appState = self.appState else { return }
        guard !appState.isScreenRecordingStale else { return } // already flagged
        log("FloatingControlBarManager: Screen Recording permission lost — flagging stale")
        appState.isScreenRecordingStale = true
    }

    /// Create the floating bar window and wire up AppState bindings.
    func setup(appState: AppState, chatProvider: ChatProvider) {
        guard window == nil else {
            log("FloatingControlBarManager: setup() called but window already exists")
            return
        }
        self.appState = appState
        log("FloatingControlBarManager: setup() creating floating bar window")

        let barWindow = FloatingControlBarWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Play/pause toggles transcription
        barWindow.onPlayPause = { [weak appState] in
            guard let appState = appState else { return }
            appState.toggleTranscription()
        }

        // Ask AI opens the input panel
        // Ask AI routes through the manager so it can load history from ChatProvider
        barWindow.onAskAI = { [weak self] in
            self?.openAIInput()
        }

        // Hide persists the preference so bar stays hidden across restarts
        barWindow.onHide = { [weak self] in
            self?.isEnabled = false
        }

        // Reuse the sidebar's ChatProvider (bridge is already warm from app startup)
        self.chatProvider = chatProvider

        // Subscribe to shared provider state (auth, suggested replies, compaction)
        sharedProviderCancellables = ChatQueryLifecycle.subscribeToProviderState(
            provider: chatProvider, state: barWindow.state, sessionKey: "floating"
        )

        // Independent subscription on sendingSessionKeys. MessageObserver only
        // fires on message mutations, so a session-state flip with no message
        // mutation would leave isAILoading stale. This sink recomputes the flag
        // whenever the set changes so the header indicator stays on during the
        // gap between agent turns (tool result roundtrips).
        sharedProviderCancellables.append(
            chatProvider.$sendingSessionKeys
                .receive(on: DispatchQueue.main)
                .sink { [weak barWindow] keys in
                    guard let barWindow else { return }
                    let isSessionSending = keys.contains("floating")
                    let msgStreaming = barWindow.state.streaming.currentAIMessage?.isStreaming ?? false
                    let newLoading = msgStreaming || isSessionSending
                    if barWindow.state.streaming.isAILoading != newLoading {
                        barWindow.state.streaming.isAILoading = newLoading
                    }
                }
        )

        barWindow.onSendQuery = { [weak self, weak barWindow, weak chatProvider] message, attachments in
            guard let self = self, let barWindow = barWindow, let provider = chatProvider else { return }
            Task { @MainActor in
                await self.sendAIQuery(message, attachments: attachments, barWindow: barWindow, provider: provider)
            }
        }

        barWindow.onInterruptAndFollowUp = { [weak chatProvider] message in
            guard let provider = chatProvider else { return }
            Task { @MainActor in
                await provider.interruptAndSend(message, sessionKey: "floating")
            }
        }

        barWindow.onEditMessage = { [weak self, weak barWindow, weak chatProvider] messageId, newText in
            guard let self, let barWindow, let provider = chatProvider else { return }
            Task { @MainActor in
                let ok = await provider.truncateForEdit(messageId: messageId, sessionKey: "floating")
                guard ok else { return }
                await self.sendAIQuery(newText, barWindow: barWindow, provider: provider)
            }
        }

        barWindow.onEnqueueMessage = { [weak chatProvider] message in
            chatProvider?.enqueueMessage(message, sessionKey: "floating")
        }

        barWindow.onSendNowQueued = { [weak chatProvider] item in
            guard let provider = chatProvider else { return }
            Task { @MainActor in
                await provider.interruptAndSend(item.text, sessionKey: "floating")
            }
        }

        barWindow.onDeleteQueued = { [weak chatProvider] item in
            // Find and remove the matching pending message in ChatProvider
            guard let provider = chatProvider else { return }
            if let idx = provider.pendingMessageTexts.firstIndex(of: item.text) {
                provider.removePendingMessage(at: idx)
            }
        }

        barWindow.onClearQueue = { [weak chatProvider] in
            chatProvider?.clearPendingMessages()
        }

        barWindow.onReorderQueue = { [weak chatProvider] source, dest in
            chatProvider?.reorderPendingMessages(from: source, to: dest)
        }

        barWindow.onStopAgent = { [weak chatProvider] in
            chatProvider?.stopAgent()
        }

        barWindow.onPopOut = { [weak self] in
            self?.popOutToWindow()
        }

        barWindow.onResetSession = { [weak chatProvider] in
            guard let provider = chatProvider else { return }
            Task { @MainActor in
                await provider.resetSession(key: "floating")
            }
        }

        barWindow.onForkChat = { [weak barWindow, weak chatProvider] in
            guard let bar = barWindow, let provider = chatProvider else { return }

            // Snapshot the floating bar's visible conversation. The new
            // pop-out gets its own copy so the source branch stays rendered
            // on the bar.
            let chatHistory = bar.state.streaming.chatHistory
            let displayedQuery = bar.state.streaming.displayedQuery
            let currentAIMessage = bar.state.streaming.currentAIMessage
            // Don't carry a "still streaming" state into the fork — the
            // in-flight AI message belongs to the source session and will
            // continue to arrive there. The forked window starts idle.
            let isAILoading = false
            // No back-fill: the new pop-out's subscriber should treat any
            // existing global messages as "before its time" and only render
            // its own future stream.
            let messageCountBefore = provider.messages.count

            let newKey = "detached-\(UUID().uuidString)"

            Task { @MainActor in
                // Ask the bridge to branch the agent session: "floating"
                // remains live, a new session is registered under `newKey`.
                await provider.forkSession(fromKey: "floating", toKey: newKey)

                // Open the new pop-out window pre-populated with the
                // copied chat history so the user sees the conversation
                // that was forked from.
                DetachedChatWindowController.shared.show(
                    chatHistory: chatHistory,
                    displayedQuery: displayedQuery,
                    currentAIMessage: currentAIMessage,
                    isAILoading: isAILoading,
                    chatProvider: provider,
                    messageCountBefore: messageCountBefore,
                    sessionKey: newKey
                )
            }
        }

        barWindow.onConnectClaude = { [weak chatProvider] in
            guard let provider = chatProvider else { return }
            ClaudeAuthWindowController.shared.show(chatProvider: provider)
        }

        barWindow.onCodexLogin = { [weak chatProvider] in
            chatProvider?.startCodexLogin()
        }

        barWindow.onChatObserverCardAction = { [weak chatProvider] activityId, action in
            chatProvider?.handleChatObserverCardAction(activityId: activityId, action: action)
        }

        barWindow.onChangeWorkspace = { [weak self, weak chatProvider] requestedPath in
            guard let self, let provider = chatProvider else { return }

            // Resolve the destination path. nil → open NSOpenPanel; non-nil →
            // jump directly to the chosen recent workspace (no intermediate UI).
            let newPath: String
            if let requestedPath, !requestedPath.isEmpty {
                newPath = requestedPath
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.message = "Select a project directory"
                panel.prompt = "Select"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                newPath = url.path
            }

            // No-op if the user picked the workspace we're already on.
            guard newPath != provider.aiChatWorkingDirectory else { return }

            provider.aiChatWorkingDirectory = newPath
            provider.workingDirectory = newPath
            RecentWorkspaces.add(newPath)
            Task { await provider.discoverClaudeConfig() }

            // Reset session
            let state = self.window?.state
            state?.streaming.chatHistory = []
            state?.streaming.displayedQuery = ""
            state?.streaming.currentAIMessage = nil
            state?.streaming.isAILoading = false
            state?.input.aiInputText = ""
            state?.clearQueue()
            self.window?.onResetSession?()
        }

        // Observe ChatProvider dequeuing messages to sync UI queue
        dequeueObserver = NotificationCenter.default.addObserver(
            forName: .chatProviderDidDequeue, object: nil, queue: .main
        ) { [weak barWindow, weak chatProvider] notification in
            guard let text = notification.userInfo?["text"] as? String,
                  let state = barWindow?.state else { return }
            // Only react to dequeue events for the floating bar's own session
            let dequeuedSessionKey = notification.userInfo?["sessionKey"] as? String ?? ""
            guard dequeuedSessionKey.isEmpty || dequeuedSessionKey == "floating" else { return }
            MainActor.assumeIsolated {
                // Remove the first matching queued message from UI
                if let idx = state.input.messageQueue.firstIndex(where: { $0.text == text }) {
                    state.input.messageQueue.remove(at: idx)
                }
                // Archive current exchange and set up for the new query.
                // The Combine $messages sink uses receive(on: .main) which delivers
                // asynchronously, so currentAIMessage may not yet reflect the latest
                // provider state. Fall back to reading directly from provider.messages.
                let currentQuery = state.streaming.displayedQuery
                var aiMessage = state.streaming.currentAIMessage
                if aiMessage == nil, let provider = chatProvider,
                   let latestAI = provider.messages.last(where: { $0.sender == .ai && $0.sessionKey == "floating" }),
                   !latestAI.text.isEmpty {
                    aiMessage = latestAI
                }
                // Skip archiving if onSendNow already set displayedQuery to this
                // message. Otherwise a race with the $messages subscriber causes
                // the same exchange to be archived twice (duplicate bubble).
                if currentQuery != text, !currentQuery.isEmpty {
                    var resolved = aiMessage ?? ChatMessage(
                        id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                        isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
                    )
                    resolved.contentBlocks = resolved.contentBlocks.map { block in
                        if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = block {
                            return .toolCall(id: id, name: name, status: .completed, toolUseId: toolUseId, input: input, output: output)
                        }
                        return block
                    }
                    state.streaming.chatHistory.append(FloatingChatExchange(
                        question: currentQuery,
                        aiMessage: resolved,
                        userMessageId: chatProvider?.mostRecentUserMessageId(text: currentQuery, scope: "floating")
                    ))
                }
                state.flushPendingChatObserverExchanges()
                state.streaming.displayedQuery = text
                state.streaming.isAILoading = true
                state.streaming.currentAIMessage = nil
                state.showUpgradeClaudeButton = false
            }
        }

        // Observe recording state
        recordingCancellable = appState.$isTranscribing
            .combineLatest(appState.$isSavingConversation)
            .receive(on: DispatchQueue.main)
            .sink { [weak barWindow] isTranscribing, isSaving in
                barWindow?.updateRecordingState(
                    isRecording: isTranscribing,
                    duration: Int(RecordingTimer.shared.duration),
                    isInitialising: isSaving
                )
            }

        // Observe duration from RecordingTimer
        durationCancellable = RecordingTimer.shared.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak barWindow, weak appState] duration in
                guard let appState = appState else { return }
                barWindow?.updateRecordingState(
                    isRecording: appState.isTranscribing,
                    duration: Int(duration),
                    isInitialising: appState.isSavingConversation
                )
            }

        self.window = barWindow

        // Debug: replay post-onboarding tutorial via distributed notification
        // Trigger from terminal: `defaults write com.fazm.app hasSeenPostOnboardingTutorial -bool false && /usr/bin/notifyutil -p com.fazm.replayTutorial`
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.replayTutorial"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let barState = self.barState else { return }
                log("FloatingControlBarManager: Replaying post-onboarding tutorial")
                PostOnboardingTutorialManager.shared.replay(barState: barState)
            }
        }

        // Debug: programmatically run the full tutorial chat guide (skip overlay)
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testTutorial"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testTutorial"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let barState = self.barState, let window = self.window, let provider = self.chatProvider else { return }
                log("FloatingControlBarManager: Starting programmatic tutorial test (skipping overlay)")

                // Reset tutorial state
                TutorialChatGuide.shared.finish(barState: barState)
                PostOnboardingTutorialManager.shared.dismiss()

                // Start the chat guide directly (bypass overlay)
                TutorialChatGuide.shared.start(barState: barState)

                // Wait for prompts to load, then auto-send each step's query
                try? await Task.sleep(for: .seconds(2))

                let prompts = barState.tutorial.tutorialPrompts.isEmpty ? TutorialChatGuide.defaultPrompts : barState.tutorial.tutorialPrompts

                for (i, prompt) in prompts.enumerated() {
                    guard barState.tutorial.isTutorialChatActive else {
                        log("FloatingControlBarManager: Tutorial test — chat guide ended early at step \(i)")
                        break
                    }

                    log("FloatingControlBarManager: Tutorial test — sending step \(i): \(prompt.instruction)")

                    // Capture screenshot before showing the bar
                    self.captureScreenshotEarly()

                    // Show the bar and send the query
                    if !window.isVisible { self.show() }
                    window.state.streaming.displayedQuery = prompt.instruction
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        window.state.streaming.showingAIResponse = true
                    }
                    window.showAIConversation()

                    await self.sendAIQuery(prompt.instruction, barWindow: window, provider: provider)

                    // Wait for the AI to finish responding (poll isAILoading)
                    var waited = 0
                    while barState.streaming.isAILoading, waited < 300 {
                        try? await Task.sleep(for: .seconds(1))
                        waited += 1
                    }

                    log("FloatingControlBarManager: Tutorial test — step \(i) response complete (waited \(waited)s)")

                    // Brief pause before next step's guidance injection + query
                    try? await Task.sleep(for: .seconds(3))
                }

                log("FloatingControlBarManager: Tutorial test — all steps complete")
            }
        }

        // Debug: send a text query via distributed notification
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "your query here"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testQuery"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, let window = self.window, let provider = self.chatProvider else { return }
                let text = notification.userInfo?["text"] as? String ?? "take a screenshot of the full screen"
                log("FloatingControlBarManager: Test query received: \(text)")

                // Capture screenshot before showing the bar
                self.captureScreenshotEarly()

                // Show the bar and set up the UI as if the user typed the query
                if !window.isVisible { self.show() }
                window.state.streaming.displayedQuery = text
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    window.state.streaming.showingAIResponse = true
                }
                window.showAIConversation()

                await self.sendAIQuery(text, barWindow: window, provider: provider)
            }
        }

        // Debug: test the Gemini analysis overlay
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testAnalysisOverlay"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testAnalysisOverlay"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let barFrame = self.barWindowFrame else { return }
                log("FloatingControlBarManager: Test analysis overlay triggered")
                AnalysisOverlayWindow.shared.show(
                    below: barFrame,
                    task: "User is refactoring authentication middleware across 15 route files. An AI agent could bulk-update the remaining files following the established pattern.",
                    description: "The user spent significant time manually editing route handler files, copying the same auth middleware pattern from one file to another. They opened 4 different route files in VS Code, made nearly identical changes to each, and appeared to have many more files remaining. This is a classic bulk find-and-replace task that an AI agent could complete much faster.",
                    activityId: 0
                )
            }
        }

        // Debug: force Gemini analysis with current buffered chunks (no need to wait for 60)
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testAnalyzeNow"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testAnalyzeNow"),
            object: nil,
            queue: .main
        ) { _ in
            Task {
                log("FloatingControlBarManager: Force analyzeNow triggered (\(await GeminiAnalysisService.shared.bufferedChunkCount) chunks)")
                let result = await GeminiAnalysisService.shared.analyzeNow()
                if let result {
                    log("FloatingControlBarManager: analyzeNow result: verdict=\(result.verdict) task=\(result.task ?? "nil")")
                } else {
                    log("FloatingControlBarManager: analyzeNow returned nil (no chunks or already analyzing)")
                }
            }
        }

        // Debug: show the Claude auth sheet popup
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testClaudeAuth"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testClaudeAuth"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let provider = self?.chatProvider else { return }
                log("FloatingControlBarManager: Test Claude auth sheet triggered")
                let mode = notification.userInfo?["mode"] as? String ?? "initial"
                if mode == "timeout" {
                    provider.claudeAuthTimedOut = true
                } else if mode == "failed" {
                    provider.claudeAuthFailed = true
                    provider.claudeAuthRetryCooldownEnd = Date().addingTimeInterval(30)
                }
                provider.isClaudeAuthRequired = true
                ClaudeAuthWindowController.shared.show(chatProvider: provider)
            }
        }

        // Debug: show the paywall popup
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testPaywall"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.testPaywall"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let provider = self?.chatProvider else { return }
                log("FloatingControlBarManager: Test paywall triggered")
                provider.showPaywall = true
                PaywallWindowController.shared.show(chatProvider: provider)
            }
        }

        // Programmatic control: unified command interface for all floating bar controls.
        // Trigger: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.control"), object: nil, userInfo: ["command": "getState"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        //
        // Supported commands:
        //   getState                            — writes JSON state to /tmp/fazm-control-state.json
        //   newChat                             — starts a new chat session
        //   popOut                              — pops conversation out to a detached window
        //   newPopOutChat                       — opens a brand-new chat directly in a detached window
        //   setModel:<id>                       — sets AI model (e.g. "setModel:claude-sonnet-4-6")
        //   toggleVoice                         — toggles voice response (TTS) on/off
        //   setVoice:on|off                     — explicitly sets voice response
        //   show                                — shows the floating bar
        //   hide                                — hides the floating bar
        //   toggle                              — toggles floating bar visibility
        //   openInput                           — opens the AI input field
        //   sendFollowUp:<text>                 — sends a follow-up message in active conversation
        //   setWorkspace:<path>                 — sets the working directory
        //   stopAgent                           — interrupt the floating bar's in-flight query
        // -- Test / diagnostics surface (added for CPU regression bisection) --
        //   listPopOuts                         — writes /tmp/fazm-control-popouts.json with every detached window's sessionKey, workspace, model, frame, busy/visible state
        //   closePopOut:<sessionKey>            — close a specific detached window by sessionKey (tears down its ACP subprocess)
        //   closeAllPopOuts                     — close every detached window (full test cleanup)
        //   sendQueryToWindow:<sessionKey>:<t>  — deliver text `<t>` to the pop-out matching `<sessionKey>` (drives the same path as a user typing into that window)
        //   getBridgeState                      — signal SIGUSR2 to the bridge so it dumps sessions / activeQueries / PID to /tmp/fazm-bridge-state.json
        //   restartBridge                       — terminate the running bridge subprocess and let ChatProvider relaunch it (clears leaked claude subprocesses)
        //   testBrowserSetupRetry:<key>:<ob>:<text> — simulate the post-browser-extension-setup retry (key empty = main/nil, "floating", or "detached-<uuid>"; ob=0|1 = was onboarding; text = pending message)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.fazm.control"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                let command = notification.userInfo?["command"] as? String ?? ""
                log("FloatingControlBarManager: Control command received: \(command)")

                if command == "getState" {
                    self.writeControlState()
                } else if command == "newChat" {
                    self.window?.startNewChat()
                } else if command == "popOut" {
                    self.popOutToWindow()
                } else if command == "newPopOutChat" {
                    self.popOutNewChat()
                } else if command.hasPrefix("setModel:") {
                    let modelId = String(command.dropFirst("setModel:".count))
                    // Accept any model ID; the ACP backend will reject truly invalid ones
                    ShortcutSettings.shared.selectedModel = modelId
                    log("FloatingControlBarManager: Model set to \(modelId)")
                    self.writeControlState()
                } else if command == "toggleVoice" {
                    let current = UserDefaults.standard.bool(forKey: "voiceResponseEnabled")
                    UserDefaults.standard.set(!current, forKey: "voiceResponseEnabled")
                    if current { ChatToolExecutor.stopTTSPlayback() }
                    log("FloatingControlBarManager: Voice toggled to \(!current)")
                    self.writeControlState()
                } else if command == "setVoice:on" {
                    UserDefaults.standard.set(true, forKey: "voiceResponseEnabled")
                    log("FloatingControlBarManager: Voice set to on")
                    self.writeControlState()
                } else if command == "setVoice:off" {
                    UserDefaults.standard.set(false, forKey: "voiceResponseEnabled")
                    ChatToolExecutor.stopTTSPlayback()
                    log("FloatingControlBarManager: Voice set to off")
                    self.writeControlState()
                } else if command == "stopAgent" {
                    self.chatProvider?.stopAgent()
                    log("FloatingControlBarManager: stopAgent invoked via control")
                } else if command == "show" {
                    self.show()
                } else if command == "hide" {
                    self.hide()
                } else if command == "toggle" {
                    self.toggle()
                } else if command == "openInput" {
                    self.openAIInput()
                } else if command.hasPrefix("sendFollowUp:") {
                    let text = String(command.dropFirst("sendFollowUp:".count))
                    self.sendFollowUpQuery(text)
                } else if command.hasPrefix("setWorkspace:") {
                    let path = String(command.dropFirst("setWorkspace:".count))
                    UserDefaults.standard.set(path, forKey: "aiChatWorkingDirectory")
                    log("FloatingControlBarManager: Workspace set to \(path)")
                    self.writeControlState()
                } else if command == "listPopOuts" {
                    self.writePopOutsList()
                } else if command == "closeAllPopOuts" {
                    let n = DetachedChatWindowController.shared.closeAllWindows()
                    log("FloatingControlBarManager: closeAllPopOuts closed \(n) windows")
                    self.writePopOutsList()
                } else if command.hasPrefix("closePopOut:") {
                    let sessionKey = String(command.dropFirst("closePopOut:".count))
                    let closed = DetachedChatWindowController.shared.closeWindow(sessionKey: sessionKey)
                    log("FloatingControlBarManager: closePopOut sessionKey=\(sessionKey) closed=\(closed)")
                    self.writePopOutsList()
                } else if command.hasPrefix("sendQueryToWindow:") {
                    // Format: sendQueryToWindow:<sessionKey>:<text>
                    let rest = String(command.dropFirst("sendQueryToWindow:".count))
                    if let colon = rest.firstIndex(of: ":") {
                        let sessionKey = String(rest[..<colon])
                        let text = String(rest[rest.index(after: colon)...])
                        let sent = DetachedChatWindowController.shared.sendQuery(toSessionKey: sessionKey, message: text)
                        log("FloatingControlBarManager: sendQueryToWindow sessionKey=\(sessionKey) sent=\(sent) text='\(text.prefix(40))'")
                    } else {
                        log("FloatingControlBarManager: sendQueryToWindow malformed — expected sessionKey:text, got '\(rest)'")
                    }
                } else if command == "getBridgeState" {
                    self.dumpBridgeState()
                } else if command == "restartBridge" {
                    self.restartBridgeSubprocess()
                } else if command.hasPrefix("testBrowserSetupRetry:") {
                    // Test hook for `ChatProvider.retryAfterBrowserSetup()` dispatch.
                    // Format: testBrowserSetupRetry:<sessionKey>:<onboarding>:<text>
                    //   <sessionKey>   empty | "floating" | "detached-<uuid>" | "main"
                    //   <onboarding>   "1" | "0" — whether the interrupted send was onboarding
                    //   <text>         the message text that was "interrupted"
                    // Simulates the state that exists right after a Playwright tool
                    // call hits an empty extension token: pendingRetry* fields are
                    // populated, then we call the dispatch entrypoint.
                    let rest = String(command.dropFirst("testBrowserSetupRetry:".count))
                    let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 3, let provider = self.chatProvider else {
                        log("FloatingControlBarManager: testBrowserSetupRetry malformed — expected sessionKey:onboarding:text, got '\(rest)'")
                        return
                    }
                    let sessionKeyArg: String? = parts[0].isEmpty ? nil : parts[0]
                    let wasOnboarding = parts[1] == "1"
                    let text = parts[2]
                    provider.pendingRetryMessage = text
                    provider.pendingRetrySessionKey = sessionKeyArg
                    provider.pendingRetryIsOnboarding = wasOnboarding
                    log("FloatingControlBarManager: testBrowserSetupRetry seeded sessionKey=\(sessionKeyArg ?? "<nil>") onboarding=\(wasOnboarding) text='\(text.prefix(40))'")
                    provider.retryAfterBrowserSetup()
                } else {
                    log("FloatingControlBarManager: Unknown control command: \(command)")
                }
            }
        }

    }

    /// Write current floating bar state to /tmp/fazm-control-state.json for programmatic access.
    private func writeControlState() {
        let state = window?.state
        let voiceEnabled = UserDefaults.standard.bool(forKey: "voiceResponseEnabled")
        let workspace = UserDefaults.standard.string(forKey: "aiChatWorkingDirectory") ?? ""

        var dict: [String: Any] = [
            "model": ShortcutSettings.shared.selectedModel,
            "modelLabel": ShortcutSettings.shared.selectedModelShortLabel,
            "voiceEnabled": voiceEnabled,
            "workspace": workspace,
            "isVisible": window?.isVisible ?? false,
            "showingAIConversation": state?.streaming.showingAIConversation ?? false,
            "showingAIResponse": state?.streaming.showingAIResponse ?? false,
            "isAILoading": state?.streaming.isAILoading ?? false,
            "isVoiceListening": state?.voice.isVoiceListening ?? false,
            "chatHistoryCount": state?.streaming.chatHistory.count ?? 0,
            "displayedQuery": state?.streaming.displayedQuery ?? "",
            "queueCount": state?.input.messageQueue.count ?? 0,
            "isTutorialActive": state?.tutorial.isTutorialChatActive ?? false,
            "availableModels": ShortcutSettings.shared.availableModels.map { ["id": $0.id, "label": $0.label, "shortLabel": $0.shortLabel] }
        ]

        if let currentMessage = state?.streaming.currentAIMessage {
            dict["currentMessagePreview"] = String(currentMessage.text.prefix(200))
            dict["isStreaming"] = currentMessage.isStreaming
        }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? json.write(toFile: "/tmp/fazm-control-state.json", atomically: true, encoding: .utf8)
            log("FloatingControlBarManager: State written to /tmp/fazm-control-state.json")
        }
    }

    /// Dump every open detached pop-out to /tmp/fazm-control-popouts.json so external
    /// tools can enumerate sessions, target a specific one with sendQueryToWindow, or
    /// confirm cleanup after closeAllPopOuts. Used by the CPU-regression A/B harness.
    private func writePopOutsList() {
        let summaries = DetachedChatWindowController.shared.popOutsSummary()
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "openWindowCount": summaries.count,
            "popouts": summaries.map { $0.asDictionary }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? json.write(toFile: "/tmp/fazm-control-popouts.json", atomically: true, encoding: .utf8)
            log("FloatingControlBarManager: Pop-out list (\(summaries.count) windows) written to /tmp/fazm-control-popouts.json")
        }
    }

    /// Send SIGUSR2 to the running acp-bridge process so it dumps its session map
    /// to /tmp/fazm-bridge-state.json. The bridge handler at acp-bridge/src/index.ts
    /// writes the JSON synchronously, so the file is on disk by the time the
    /// caller checks it (about 50ms after the signal in practice).
    /// Uses pgrep because ACPBridge.process is private; this avoids threading a
    /// new public accessor through ChatProvider just for diagnostics.
    private func dumpBridgeState() {
        guard let bridgePid = findBridgePid() else {
            log("FloatingControlBarManager: getBridgeState — no acp-bridge process found")
            // Write a small marker so callers don't read stale data.
            let payload = "{\"error\":\"no_bridge_process_found\",\"timestamp\":\(Date().timeIntervalSince1970)}\n"
            try? payload.write(toFile: "/tmp/fazm-bridge-state.json", atomically: true, encoding: .utf8)
            return
        }
        let signalResult = kill(bridgePid, SIGUSR2)
        log("FloatingControlBarManager: getBridgeState — SIGUSR2 sent to bridge PID=\(bridgePid) (kill returned \(signalResult))")
    }

    /// Locate the running acp-bridge (dist/index.js) PID that belongs to THIS
    /// running Fazm app. Scoped by `Bundle.main.bundlePath` so we never signal
    /// a sibling install (e.g. prod Fazm.app from Fazm Dev.app or vice-versa)
    /// when both are running side-by-side during development.
    private func findBridgePid() -> pid_t? {
        // Scope to this bundle by including the bundle path in the pgrep pattern.
        // Example: "/Applications/Fazm Dev.app/Contents/Resources/acp-bridge/dist/index.js"
        let bundlePath = Bundle.main.bundlePath
        let pattern = "\(bundlePath)/Contents/Resources/acp-bridge/dist/index.js"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", pattern]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8) ?? ""
            // Validate each candidate is alive (kill -0). pgrep can return stale
            // entries during a fast respawn cycle.
            for line in str.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let pid = pid_t(trimmed), kill(pid, 0) == 0 {
                    return pid
                }
            }
        } catch {
            log("FloatingControlBarManager: pgrep failed: \(error)")
        }
        return nil
    }

    /// Terminate the running bridge subprocess. ChatProvider/ACPBridge will detect
    /// the exit on its next stdio read and relaunch the bridge automatically
    /// (the same path the parent-death watchdog already exercises). Useful for
    /// clearing leaked claude subprocesses or testing fixes without restarting Fazm.
    private func restartBridgeSubprocess() {
        guard let bridgePid = findBridgePid() else {
            log("FloatingControlBarManager: restartBridge — no acp-bridge process found")
            return
        }
        let result = kill(bridgePid, SIGTERM)
        log("FloatingControlBarManager: restartBridge — SIGTERM sent to bridge PID=\(bridgePid) (kill returned \(result)). ChatProvider should relaunch on next query.")
    }

    /// Whether the floating bar window is currently visible.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Show the floating bar and persist the preference.
    func show() {
        log("FloatingControlBarManager: show() called, window=\(window != nil), isVisible=\(window?.isVisible ?? false)")
        isEnabled = true
        window?.makeKeyAndOrderFront(nil)
        log("FloatingControlBarManager: show() done, frame=\(window?.frame ?? .zero)")

        // Show post-onboarding tutorial if needed
        if let barState = self.barState {
            PostOnboardingTutorialManager.shared.showIfNeeded(barState: barState)
        }

        // Browser profile migration popup for existing users
        BrowserProfileMigrationManager.shared.showIfNeeded()

        // Auto-focus input if AI conversation is open
        if let window = window, window.state.streaming.showingAIConversation && !window.state.streaming.showingAIResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.focusInputField()
            }
        }
    }

    /// Hide the floating bar and persist the preference.
    func hide() {
        isEnabled = false
        window?.orderOut(nil)
    }

    /// Show the floating bar temporarily without changing the user's persisted preference.
    /// Used when browser tools activate so the bar stays visible above Chrome.
    func showTemporarily() {
        guard window != nil else { return }
        log("FloatingControlBarManager: showTemporarily() — showing bar above Chrome")
        window?.makeKeyAndOrderFront(nil)
    }

    /// Suppress or restore click-outside-dismiss (used while browser/Playwright tools run).
    func setSuppressClickOutsideDismiss(_ suppress: Bool) {
        window?.suppressClickOutsideDismiss = suppress
    }

    /// Cancel any in-flight chat streaming.
    /// Also sends an ACP interrupt for the floating session so the bridge stops the
    /// agent immediately. Without this, an in-flight query would hang silently in the
    /// bridge for up to 600s after the user closed Ask Fazm, then fire a spurious
    /// `chat_agent_error` and pollute the next query on the same session.
    func cancelChat() {
        chatCancellable?.cancel()
        chatCancellable = nil
        messageObserver?.cancel()
        messageObserver = nil
        if let provider = chatProvider, provider.isSending(sessionKey: "floating") {
            provider.stopAgent(sessionKey: "floating")
        }
    }

    /// Whether there is an active ACP subscription receiving updates.
    /// Stays true through tool calls and gaps between streamed text — a stronger
    /// "agent is working" signal than `isStreaming` or `isAILoading`, which only
    /// cover token streaming and the initial wait.
    var isChatActive: Bool {
        chatCancellable != nil
    }

    /// Toggle visibility.
    func toggle() {
        guard let window = window else { return }
        if window.isVisible {
            AnalyticsManager.shared.floatingBarToggled(visible: false, source: "shortcut")
            hide()
        } else {
            AnalyticsManager.shared.floatingBarToggled(visible: true, source: "shortcut")
            show()
        }
    }

    /// Open the AI input panel.
    func openAIInput() {
        guard let window = window else { return }

        // Move to the active monitor before opening
        window.moveToActiveScreen()

        // Capture the last active app's window before Fazm activates and covers it
        captureScreenshotEarly()

        // Activate the app so the window can become key and accept keyboard input.
        // Without this, makeFirstResponder silently fails when triggered from a global shortcut.
        // Collect non-floating windows BEFORE activation so we can push them back afterward.
        // Exclude detached chat windows — they should stay visible alongside the floating bar.
        let otherWindows = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.level == .normal && !($0 is DetachedChatWindow)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Push non-floating windows back so they don't cover the user's other apps.
        // The floating bar has .floating level and stays on top regardless.
        for w in otherWindows {
            w.orderBack(nil)
        }

        // If a conversation is already showing, just focus the follow-up input
        if window.state.streaming.showingAIConversation && window.state.streaming.showingAIResponse {
            if !window.isVisible { show() }
            window.makeKeyAndOrderFront(nil)
            window.focusInputField()
            return
        }

        AnalyticsManager.shared.floatingBarAskFazmOpened(source: "shortcut")

        // Re-wire onSendQuery for the shared provider
        if let provider = self.chatProvider {
            window.onSendQuery = { [weak self, weak window, weak provider] message, attachments in
                guard let self = self, let window = window, let provider = provider else { return }
                Task { @MainActor in
                    await self.sendAIQuery(message, attachments: attachments, barWindow: window, provider: provider)
                }
            }
        }

        if !window.isVisible {
            show()
        }

        // Eagerly restore floating chat messages from local DB before showing the conversation.
        // This must complete before showAIConversation() so the history check on line 491 works.
        if let provider = self.chatProvider {
            Task { @MainActor in
                await provider.restoreFloatingChatIfNeeded()
                if window.state.lastConversation == nil && window.state.streaming.chatHistory.isEmpty
                    && !provider.floatingChatWasCleared {
                    let floatingMessages = provider.messages.filter { ($0.sessionKey ?? "floating") == "floating" }
                    if !floatingMessages.isEmpty {
                        window.state.loadHistory(from: floatingMessages)
                    }
                }
                window.showAIConversation()
                window.orderFrontRegardless()
            }
        } else {
            window.showAIConversation()
            window.orderFrontRegardless()
        }
    }

    /// Open AI input with a pre-filled transcription from PTT (inserts into input field without sending).
    func openAIInputWithQuery(_ query: String) {
        guard let window = window else { return }

        // Move to the active monitor before opening
        window.moveToActiveScreen()

        // Capture the last active app's window before Fazm activates and covers it
        captureScreenshotEarly()

        // Cancel stale subscriptions immediately to prevent old data from flashing
        chatCancellable?.cancel()
        chatCancellable = nil
        messageObserver?.cancel()
        messageObserver = nil
        window.cancelInputHeightObserver()

        // Reset state directly (no animation) to avoid contract-then-expand flicker
        window.state.streaming.showingAIConversation = false
        window.state.streaming.showingAIResponse = false
        window.state.input.aiInputText = ""
        window.state.streaming.currentAIMessage = nil
        window.state.voice.isVoiceFollowUp = false
        window.state.voice.voiceFollowUpTranscript = ""

        guard let provider = self.chatProvider else { return }

        // Re-wire the onSendQuery to use the shared provider
        window.onSendQuery = { [weak self, weak window, weak provider] message, attachments in
            guard let self = self, let window = window, let provider = provider else { return }
            Task { @MainActor in
                await self.sendAIQuery(message, attachments: attachments, barWindow: window, provider: provider)
            }
        }

        window.onInterruptAndFollowUp = { [weak provider] message in
            guard let provider = provider else { return }
            Task { @MainActor in
                await provider.interruptAndSend(message, sessionKey: "floating")
            }
        }

        window.onEnqueueMessage = { [weak provider] message in
            provider?.enqueueMessage(message, sessionKey: "floating")
        }

        window.onSendNowQueued = { [weak provider] item in
            guard let provider = provider else { return }
            Task { @MainActor in
                await provider.interruptAndSend(item.text, sessionKey: "floating")
            }
        }

        window.onDeleteQueued = { [weak provider] item in
            guard let provider = provider else { return }
            if let idx = provider.pendingMessageTexts.firstIndex(of: item.text) {
                provider.removePendingMessage(at: idx)
            }
        }

        window.onClearQueue = { [weak provider] in
            provider?.clearPendingMessages()
        }

        window.onReorderQueue = { [weak provider] source, dest in
            provider?.reorderPendingMessages(from: source, to: dest)
        }

        window.onStopAgent = { [weak provider] in
            provider?.stopAgent()
        }

        window.onChatObserverCardAction = { [weak provider] activityId, action in
            provider?.handleChatObserverCardAction(activityId: activityId, action: action)
        }

        // Activate the app so the window can become key and accept keyboard input.
        NSApp.activate(ignoringOtherApps: true)

        if !window.isVisible {
            show()
        }

        // Cancel any in-flight windowDidResignKey dismiss animation before saving the
        // pre-chat center. Without this, the stale completion block fires after the new
        // query opens and immediately closes it.
        window.cancelPendingDismiss()

        // Save pre-chat center so closeAIConversation can restore the original position.
        // Without this, Escape after a PTT query places the bar at the response window's
        // center instead of where it was before the chat opened.
        window.savePreChatCenterIfNeeded()

        // Eagerly restore floating chat messages from local DB before showing conversation.
        // Must complete before showAIConversation() so the history check works.
        Task { @MainActor in
            await provider.restoreFloatingChatIfNeeded()
            if window.state.streaming.chatHistory.isEmpty && !provider.floatingChatWasCleared {
                let floatingMessages = provider.messages.filter { ($0.sessionKey ?? "floating") == "floating" }
                if !floatingMessages.isEmpty {
                    window.state.loadHistory(from: floatingMessages)
                }
            }

            // Show the input view with the transcription pre-filled (user can edit before sending)
            window.state.clearLastConversation()
            window.state.input.aiInputText = query
            window.showAIConversation()
            // Override the empty text that showAIConversation sets
            window.state.input.aiInputText = query
            window.orderFrontRegardless()

            // Focus the input field so user can immediately edit or press Enter to send
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                window.focusInputField()
            }
        }
    }

    /// Insert a PTT transcription into the follow-up input field (user can edit before sending).
    func sendFollowUpQuery(_ query: String) {
        guard let window = window, window.state.streaming.showingAIResponse else {
            // No active conversation — fall back to new conversation
            openAIInputWithQuery(query)
            return
        }

        // Insert transcription into the follow-up input field
        window.state.input.pendingFollowUpText = query
        window.makeKeyAndOrderFront(nil)

        // Focus the follow-up input field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            window.focusInputField()
        }
    }

    /// Access the bar state for PTT updates.
    var barState: FloatingControlBarState? {
        return window?.state
    }

    /// Access the bar window frame for positioning other UI (e.g. tutorial overlay).
    var barWindowFrame: NSRect? {
        return window?.frame
    }

    /// Focus the text input field in the floating bar.
    func focusInputField() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            window.focusInputField()
        }
    }

    /// Expand the floating bar from collapsed state (used by PTT when bar was collapsed).
    func expandFromCollapsed(instant: Bool = false) {
        guard let window else { return }
        window.expandFromCollapsed(instant: instant)
    }

    /// Move the floating bar to the active monitor (where the foreground app is).
    func moveToActiveScreen() {
        window?.moveToActiveScreen()
    }

    /// Resize the floating bar for PTT state changes.
    func resizeForPTT(expanded: Bool) {
        window?.resizeForPTTState(expanded: expanded)
    }

    /// Close the AI conversation panel (used by PTT when no transcript was captured).
    func closeAIConversation() {
        window?.closeAIConversation()
    }

    /// Pop the current conversation out into a separate, normal macOS window.
    func popOutToWindow() {
        guard let window = window, let provider = chatProvider else { return }
        let state = window.state

        log("FloatingControlBarManager: Popping out conversation to detached window")
        AnalyticsManager.shared.floatingBarChatPoppedOut(
            historyCount: state.streaming.chatHistory.count
        )

        // Remove monitors before hiding the floating bar conversation
        window.removeGlobalClickOutsideMonitor()
        window.suppressClickOutsideDismiss = false
        state.isCollapsed = false

        // Snapshot conversation data before resetting
        let chatHistory = state.streaming.chatHistory
        let displayedQuery = state.streaming.displayedQuery
        let currentAIMessage = state.streaming.currentAIMessage
        let isAILoading = state.streaming.isAILoading
        // If a query is in-flight, subtract 1 so the detached window's subscriber
        // picks up streaming updates to the existing AI message (already in messages).
        let messageCountBefore = provider.messages.count - (isAILoading ? 1 : 0)

        // Cancel existing streaming subscription — the detached window will create its own
        chatCancellable?.cancel()
        chatCancellable = nil
        messageObserver?.cancel()
        messageObserver = nil

        // Transfer the ACP session from "floating" to a unique detached key.
        // This lets the detached window continue the same ACP conversation,
        // while the floating bar's "floating" key is cleared for a fresh session.
        let detachedSessionKey = "detached-\(UUID().uuidString)"
        provider.transferSession(fromKey: "floating", toKey: detachedSessionKey)

        // Show the detached window with its own state copy and session key
        DetachedChatWindowController.shared.show(
            chatHistory: chatHistory,
            displayedQuery: displayedQuery,
            currentAIMessage: currentAIMessage,
            isAILoading: isAILoading,
            chatProvider: provider,
            messageCountBefore: messageCountBefore,
            sessionKey: detachedSessionKey
        )

        // Clear floating bar state so closeAIConversation doesn't snapshot stale data
        state.streaming.chatHistory = []
        state.streaming.displayedQuery = ""
        state.streaming.currentAIMessage = nil
        state.input.aiInputText = ""  // Clear stale input so it isn't saved as a draft
        state.clearLastConversation()
        state.clearQueue()

        // Close the floating bar conversation and collapse back to pill
        window.closeAIConversation()
    }

    /// Create a new detached pop-out chat window with an empty conversation.
    /// Triggered by the global "New Pop-Out Chat" shortcut.
    func popOutNewChat() {
        guard let provider = chatProvider else { return }

        // Debounce rapid double-fires of the global shortcut (e.g. from key
        // repeat or impatient retap). Without this, two pop-outs are created
        // side-by-side with the same chatHistory snapshot.
        let now = ProcessInfo.processInfo.systemUptime
        if (now - lastPopOutNewChatTime) < 1.0 {
            log("FloatingControlBarManager: Ignored duplicate pop-out shortcut (\(Int((now - lastPopOutNewChatTime) * 1000))ms since last)")
            return
        }
        lastPopOutNewChatTime = now

        log("FloatingControlBarManager: Creating new pop-out chat window via global shortcut")
        AnalyticsManager.shared.floatingBarChatPoppedOut(historyCount: 0)

        // Claim the always-ready pre-warmed session so the first query is instant.
        let detachedSessionKey = provider.claimWarmDetachedSession()

        // If the user is currently focused on an existing pop-out, inherit its workspace
        // so the new window opens in the same project context. Falls back to the shared
        // provider's workspace if no pop-out is focused (e.g. shortcut fired from main app).
        let focusedPopOut = (NSApp.keyWindow as? DetachedChatWindow)
            ?? DetachedChatWindowController.shared.lastActiveWindow
        let inheritState = focusedPopOut?.state
        if let inheritState = inheritState {
            log("FloatingControlBarManager: Inheriting workspace from focused pop-out: '\(inheritState.workspace.workspaceDirectory)'")
        }

        DetachedChatWindowController.shared.show(
            chatHistory: [],
            displayedQuery: "",
            currentAIMessage: nil,
            isAILoading: false,
            chatProvider: provider,
            messageCountBefore: provider.messages.count,
            sessionKey: detachedSessionKey,
            inheritWorkspaceFrom: inheritState
        )
    }

    /// Re-send the pending message that was interrupted by browser extension setup.
    /// Opens the floating bar and routes through `sendAIQuery` so streaming is wired up.
    ///
    /// The bridge is stopped (not restarted) so that `sendMessage` → `ensureBridgeStarted()`
    /// does a full warmup with ACP session resume, preserving conversation history.
    /// Instead of repeating the original prompt (which the AI already saw), we send a
    /// continuation message so the AI picks up where it left off.
    func retryPendingQuery() {
        guard let provider = chatProvider,
              let _ = provider.pendingRetryMessage else { return }
        provider.clearPendingRetry()
        guard let window = window else { return }

        log("FloatingControlBarManager: Retrying pending query via floating bar (with session resume)")

        // Archive the interrupted exchange to chat history before clearing,
        // so the user's original query and any partial AI response remain visible.
        let currentQuery = window.state.streaming.displayedQuery
        if !currentQuery.isEmpty {
            let aiMessage = window.state.streaming.currentAIMessage ?? ChatMessage(
                id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
            )
            window.state.streaming.chatHistory.append(FloatingChatExchange(
                question: currentQuery,
                aiMessage: aiMessage,
                userMessageId: provider.mostRecentUserMessageId(text: currentQuery, scope: "floating")
            ))
        }
        window.state.flushPendingChatObserverExchanges()

        // Reset streaming state but keep chat history — the session will be resumed
        chatCancellable?.cancel()
        chatCancellable = nil
        messageObserver?.cancel()
        messageObserver = nil
        window.cancelInputHeightObserver()
        window.state.streaming.currentAIMessage = nil

        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { show() }
        window.cancelPendingDismiss()
        window.savePreChatCenterIfNeeded()
        window.showAIConversation()
        window.orderFrontRegardless()

        // The bridge was already restarted with session resume by testPlaywrightConnection().
        // Send a continuation message — the AI already has the original prompt in session history.
        let continuationMessage = "The browser extension is now connected and ready. Please continue with the task."
        Task { @MainActor in
            await self.sendAIQuery(continuationMessage, barWindow: window, provider: provider)
        }
    }

    // MARK: - AI Query

    private func sendAIQuery(_ message: String, attachments: [ChatAttachment] = [], barWindow: FloatingControlBarWindow, provider: ChatProvider) async {
        // If a query is already in-flight FOR THIS SESSION, enqueue instead of silently
        // dropping. The queue drains automatically after the current response finishes.
        // Check the per-session flag (not the global `isSending`) so a busy sibling
        // pop-out doesn't trap floating-bar submits in an undrainable queue while the
        // pop-out is doing long-running work. Matches the per-session gating already
        // used at line 1893 here and in DetachedChatWindow / interruptAndSend.
        if provider.isSending(sessionKey: "floating") {
            provider.enqueueMessage(message, sessionKey: "floating")
            // The SwiftUI wrapper no longer does optimistic UI on submit, so we
            // don't need to undo a stale displayedQuery here, the queue chip is
            // the only thing the user sees, which is correct.
            log("FloatingControlBarManager: Query enqueued (floating session busy): \(message.prefix(80))")
            return
        }

        // Not-busy path: optimistic UI here (moved out of the SwiftUI wrapper)
        // so the busy branch above doesn't double-render the message as both
        // displayedQuery and a queue chip.
        let streaming = barWindow.state.streaming
        let currentQuery = streaming.displayedQuery
        if !currentQuery.isEmpty {
            let aiMessage = streaming.currentAIMessage ?? ChatMessage(
                id: UUID().uuidString, text: "", createdAt: Date(), sender: .ai,
                isStreaming: false, rating: nil, isSynced: false, citations: [], contentBlocks: [], sessionKey: nil
            )
            streaming.chatHistory.append(FloatingChatExchange(
                question: currentQuery,
                aiMessage: aiMessage,
                userMessageId: provider.mostRecentUserMessageId(text: currentQuery, scope: "floating")
            ))
        }
        barWindow.state.flushPendingChatObserverExchanges()
        streaming.displayedQuery = message
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            streaming.isAILoading = true
            streaming.currentAIMessage = nil
        }

        // Restore previous floating chat messages and session on first interaction
        await provider.restoreFloatingChatIfNeeded()

        // Populate the floating bar's chat history from restored messages.
        //
        // Skip entirely if the floating chat was just cleared (e.g. by pop-out or
        // explicit new chat). Without this check, messages left alive in
        // `provider.messages` for an in-flight detached query would leak back into
        // the fresh floating bar. Note: `restoreFloatingChatIfNeeded` has an
        // in-memory `floatingChatRestored` one-shot guard that prevents its own
        // cleared-flag check from firing more than once per app launch, so we must
        // honor the flag here independently.
        //
        // Also filter by sessionKey == "floating" so any messages re-keyed to a
        // detached session (see `transferSession`) are never pulled into the
        // floating bar's exchange list.
        if barWindow.state.streaming.chatHistory.isEmpty && barWindow.state.streaming.currentAIMessage == nil
            && !provider.floatingChatWasCleared {
            let restored = provider.messages.filter { ($0.sessionKey ?? "floating") == "floating" }
            if !restored.isEmpty {
                // Pair up user/AI messages into exchanges for the history UI
                var i = 0
                while i < restored.count - 1 {
                    if restored[i].sender == .user, restored[i + 1].sender == .ai {
                        barWindow.state.streaming.chatHistory.append(
                            FloatingChatExchange(question: restored[i].text, aiMessage: restored[i + 1])
                        )
                        i += 2
                    } else {
                        i += 1
                    }
                }
                log("FloatingControlBarManager: Populated \(barWindow.state.streaming.chatHistory.count) exchanges from restored messages")
            }
        } else if provider.floatingChatWasCleared {
            log("FloatingControlBarManager: Skipping populate-from-messages (floating chat was cleared, e.g. pop-out)")
        }

        // Use pre-captured screenshot if available, otherwise capture now (e.g. follow-up in open bar)
        var screenshotPath = self.pendingScreenshotPath
        self.pendingScreenshotPath = nil
        if screenshotPath == nil {
            let targetPID = self.lastActiveAppPID
            screenshotPath = await Task.detached {
                if targetPID != 0 {
                    switch ScreenCaptureManager.captureAppWindow(pid: targetPID) {
                    case .success(let url): return url
                    case .permissionDenied: return nil as URL?
                    }
                } else {
                    return ScreenCaptureManager.captureScreen()
                }
            }.value
            if screenshotPath == nil && targetPID != 0 {
                flagScreenRecordingPermissionLost()
            }
        }

        // Record message count before sending so we can detect the new AI response
        let messageCountBefore = provider.messages.count
        log("[FloatingBar] sendAIQuery: messageCountBefore=\(messageCountBefore) chatHistory=\(barWindow.state.streaming.chatHistory.count)")

        // Shared pre-query setup: suggested replies, callbacks, analytics, referral
        ChatQueryLifecycle.prepareForQuery(
            state: barWindow.state,
            message: message,
            hasScreenshot: screenshotPath != nil,
            sendFollowUp: { [weak self, weak barWindow, weak chatProvider] message in
                guard let self = self, let barWindow = barWindow, let provider = chatProvider else { return }
                Task { @MainActor in
                    log("Auto-sending follow-up: \(message)")
                    await self.sendAIQuery(message, barWindow: barWindow, provider: provider)
                }
            }
        )

        // Observe messages for streaming response
        chatCancellable?.cancel()
        messageObserver?.cancel()
        messageObserver = nil
        barWindow.state.streaming.currentAIMessage = nil
        barWindow.state.streaming.isAILoading = true
        var hasSetUpResponseHeight = false
        log("[FloatingBar] subscribeToResponse: messageCountBefore=\(messageCountBefore) session=floating")
        // The array publisher only fires on add/remove now (ChatMessage is a
        // reference type, so element-field mutations don't change the array).
        // This sink fires once when the AI message lands; per-token granular
        // updates come from MessageObserver below.
        chatCancellable = provider.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak barWindow] messages in
                // Ignore updates if the conversation was closed (Esc pressed during streaming)
                guard let self, let barWindow = barWindow, barWindow.state.streaming.showingAIConversation else { return }
                guard messages.count > messageCountBefore else { return }
                // Only examine messages added since this subscription was created.
                // Searching ALL messages would re-set currentAIMessage to a prior AI
                // response when the user follow-up message is added (incrementing
                // messages.count) before the new AI response has arrived.
                let newMessages = messages[messageCountBefore...]
                guard let aiMessage = newMessages.last(where: { $0.sender == .ai && $0.sessionKey == "floating" }) else {
                    let dump = newMessages.map { m in
                        "[\(m.sender) key=\(m.sessionKey ?? "nil") text=\(m.text.prefix(20))]"
                    }.joined(separator: " ")
                    log("[FloatingBar] subscribeToResponse: \(newMessages.count) new message(s) but no new AI with session=floating — \(dump)")
                    return
                }

                log("[FloatingBar] subscribeToResponse: AI id=\(aiMessage.id) streaming=\(aiMessage.isStreaming)")
                // Store the full ChatMessage (preserves contentBlocks, tool calls, thinking)
                barWindow.state.streaming.currentAIMessage = aiMessage

                // Tear down any previous observer; install a new one keyed to
                // this message so token deltas drive isAILoading and the
                // streaming-completion side effects.
                self.messageObserver?.cancel()
                self.messageObserver = MessageObserver(message: aiMessage) { [weak barWindow, weak provider] msg in
                    guard let barWindow else { return }
                    // OR with sendingSessionKeys so the indicator stays on during
                    // the gap between agent turns (tool result roundtrips), where
                    // msg.isStreaming briefly looks false but the query is still
                    // live in ChatProvider.
                    let isSessionSending = provider?.isSending(sessionKey: "floating") ?? false
                    let newLoading = msg.isStreaming || isSessionSending
                    if barWindow.state.streaming.isAILoading != newLoading {
                        barWindow.state.streaming.isAILoading = newLoading
                    }
                    if msg.isStreaming, !hasSetUpResponseHeight {
                        hasSetUpResponseHeight = true
                        if !barWindow.state.streaming.showingAIResponse {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                barWindow.state.streaming.showingAIResponse = true
                            }
                        }
                        barWindow.resizeToResponseHeightPublic(animated: false)
                    }
                }
            }

        // Convert user attachments to bridge format
        let bridgeAttachments: [[String: String]]? = attachments.isEmpty ? nil : attachments.map { $0.bridgeDict }
        await provider.sendMessage(message, model: ShortcutSettings.shared.selectedModel, systemPromptSuffix: barWindow.state.tutorial.tutorialSystemPromptSuffix, systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent, sessionKey: "floating", attachments: bridgeAttachments)

        // Handle errors, credit exhaustion, auth, paywall, etc.
        ChatQueryLifecycle.handlePostQuery(provider: provider, state: barWindow.state, sessionKey: "floating", messageCountBefore: messageCountBefore)

        // Floating bar specific: resize window to fit the response/error.
        // Use animated:false — animated:true here triggers an uncaught NSException
        // in `_updateStructuralRegionsOnNextDisplayCycle` during the CA transaction
        // commit on macOS 26+ (Tahoe). The first stream-chunk resize at the call
        // site above already snaps to the response height non-animated; this final
        // call only fires for late growth and an instant snap is acceptable UX.
        if barWindow.state.streaming.showingAIResponse {
            barWindow.resizeToResponseHeightPublic(animated: false)
        }
    }
}

// Expose resizeToResponseHeight for the manager
extension FloatingControlBarWindow {
    func resizeToResponseHeightPublic(animated: Bool = false) {
        resizeToResponseHeight(animated: animated)
    }

    /// Snap the window to the pill position before opening a new chat.
    /// Uses the bar's current screen (not focus) since this is a transient snap before expansion.
    func savePreChatCenterIfNeeded() {
        let size = FloatingControlBarWindow.minBarSize
        let origin = NSPoint(
            x: defaultPillOrigin(followFocus: false).x,
            y: canonicalBottomY + FloatingControlBarWindow.collapsedYOffset
        )
        isResizingProgrammatically = true
        setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        isResizingProgrammatically = false
        pendingRestoreOrigin = nil
    }

    /// Invalidates any in-flight windowDidResignKey dismiss animation so a new PTT
    /// query won't be immediately closed by a stale completion block.
    func cancelPendingDismiss() {
        resignKeyAnimationToken += 1
    }
}
