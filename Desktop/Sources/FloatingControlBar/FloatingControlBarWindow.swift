import Cocoa
import Combine
import SwiftUI

/// NSWindow subclass for the floating control bar.
class FloatingControlBarWindow: NSWindow, NSWindowDelegate {
    private static let positionKey = "FloatingControlBarPosition"
    private static let sizeKey = "FloatingControlBarSize"
    private static let defaultSize = NSSize(width: 40, height: 10)
    private static let minBarSize = NSSize(width: 40, height: 10)
    static let expandedBarSize = NSSize(width: 210, height: 50)
    private static let maxBarSize = NSSize(width: 1200, height: 1000)
    private static let expandedWidth: CGFloat = 430
    /// Minimum window height when AI response first appears.
    private static let minResponseHeight: CGFloat = 250
    /// Base height used as the reference for 2× cap (same as current default response height).
    private static let defaultBaseResponseHeight: CGFloat = 430
    /// Overhead (px) added to measured scroll content to account for control bar, header, follow-up input, and padding.
    private static let responseViewOverhead: CGFloat = 190

    let state = FloatingControlBarState()
    private var hostingView: NSHostingView<AnyView>?
    private var isResizingProgrammatically = false
    private var isUserDragging = false
    /// Set by ResizeHandleNSView while the user is manually dragging the corner.
    /// Prevents the response-height observer from fighting manual resize.
    var isUserResizing = false
    /// Suppresses hover resizes during close animation to prevent position drift.
    private var suppressHoverResize = false
    /// The canonical bottom-edge Y position. Set once during initial positioning and
    /// only updated by explicit user drag. ALL resizing reads from this value instead
    /// of frame.origin.y, making vertical drift structurally impossible.
    private var canonicalBottomY: CGFloat = 0
    private var inputHeightCancellable: AnyCancellable?
    private var responseHeightCancellable: AnyCancellable?
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
    /// When true, clicks outside the app don't dismiss the chat (e.g. browser tool running).
    var suppressClickOutsideDismiss = false

    var onPlayPause: (() -> Void)?
    var onAskAI: (() -> Void)?
    var onHide: (() -> Void)?
    var onSendQuery: ((String) -> Void)?
    var onInterruptAndFollowUp: ((String) -> Void)?
    var onStopAgent: (() -> Void)?
    var onResetSession: (() -> Void)?

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

        self.appearance = NSAppearance(named: .vibrantDark)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.delegate = self
        self.minSize = FloatingControlBarWindow.minBarSize
        self.maxSize = FloatingControlBarWindow.maxBarSize

        setupViews()

        if ShortcutSettings.shared.draggableBarEnabled,
           let savedPosition = UserDefaults.standard.string(forKey: FloatingControlBarWindow.positionKey) {
            let origin = NSPointFromString(savedPosition)
            // Verify saved position is on a visible screen
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(NSPoint(x: origin.x + 14, y: origin.y + 14)) }
            if onScreen {
                self.setFrameOrigin(origin)
                canonicalBottomY = origin.y
            } else {
                centerOnMainScreen()
            }
        } else {
            centerOnMainScreen()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc closes the AI conversation only — never hides the entire bar
        if event.keyCode == 53 { // Escape
            if state.showingAIConversation {
                closeAIConversation()
            }
            return
        }
        super.keyDown(with: event)
    }

    private func setupViews() {
        let swiftUIView = FloatingControlBarView(
            window: self,
            onPlayPause: { [weak self] in self?.onPlayPause?() },
            onAskAI: { [weak self] in self?.handleAskAI() },
            onHide: { [weak self] in self?.hideBar() },
            onSendQuery: { [weak self] message in self?.onSendQuery?(message) },
            onCloseAI: { [weak self] in self?.closeAIConversation() },
            onNewChat: { [weak self] in self?.startNewChat() },
            onInterruptAndFollowUp: { [weak self] message in self?.onInterruptAndFollowUp?(message) },
            onStopAgent: { [weak self] in self?.onStopAgent?() }
        ).environmentObject(state)

        hostingView = NSHostingView(rootView: AnyView(
            swiftUIView
                .withFontScaling()
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
        ))
        hostingView?.appearance = NSAppearance(named: .vibrantDark)

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

        NotificationCenter.default.addObserver(
            forName: .floatingBarDragDidStart, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isUserDragging = true
                self?.state.isDragging = true
            }
        }

        NotificationCenter.default.addObserver(
            forName: .floatingBarDragDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isUserDragging = false
                self?.state.isDragging = false
            }
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
        if state.showingAIConversation && !state.showingAIResponse {
            // Already showing input, close it
            closeAIConversation()
        } else if state.showingAIConversation && state.showingAIResponse {
            // Showing response — focus the follow-up input instead of closing
            makeKeyAndOrderFront(nil)
            focusInputField()
        } else {
            AnalyticsManager.shared.floatingBarAskFazmOpened(source: "button")
            onAskAI?()
        }
    }

    /// Focus the text input field by finding the NSTextView in the view hierarchy.
    /// Returns `true` if the text view was found and focused.
    @discardableResult
    func focusInputField() -> Bool {
        guard let contentView = self.contentView else { return false }
        // Find the NSTextView inside the hosting view hierarchy
        func findTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for subview in view.subviews {
                if let found = findTextView(in: subview) { return found }
            }
            return nil
        }
        if let textView = findTextView(in: contentView) {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(textView)
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
        if state.isTutorialChatActive {
            TutorialChatGuide.shared.finish(barState: state)
        }

        // Cancel any in-flight chat streaming to prevent re-expansion
        FloatingControlBarManager.shared.cancelChat()

        // Cancel dynamic response-height observer and reset its state
        responseHeightCancellable?.cancel()
        responseHeightCancellable = nil
        state.responseContentHeight = 0

        // Cancel PTT if in follow-up mode
        if state.isVoiceFollowUp {
            PushToTalkManager.shared.cancelListening()
        }

        // Snapshot the conversation before clearing so user can resume it later
        if let msg = state.currentAIMessage, !msg.text.isEmpty {
            var fullHistory = state.chatHistory
            if !state.displayedQuery.isEmpty {
                fullHistory.append(FloatingChatExchange(question: state.displayedQuery, aiMessage: msg))
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

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.showingAIConversation = false
            state.showingAIResponse = false
            state.aiInputText = ""
            state.currentAIMessage = nil
            state.chatHistory = []
            state.isVoiceFollowUp = false
            state.voiceFollowUpTranscript = ""
        }
        // Suppress hover resizes while the close animation plays, otherwise onHover
        // fires mid-animation, reads an intermediate frame, and causes position drift.
        suppressHoverResize = true

        // Restore the pill using canonicalBottomY — the single source of truth for Y.
        let size = FloatingControlBarWindow.minBarSize
        let restoreOrigin = NSPoint(
            x: defaultPillOrigin().x,
            y: canonicalBottomY
        )

        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        styleMask.remove(.resizable)
        isResizingProgrammatically = true
        // Record the animation target so savePreChatCenterIfNeeded() can snap to it
        // if a new PTT query fires while this restore animation is still running.
        pendingRestoreOrigin = restoreOrigin
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0.3
        NSAnimationContext.current.allowsImplicitAnimation = false
        NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.setFrame(NSRect(origin: restoreOrigin, size: size), display: true, animate: true)
        NSAnimationContext.endGrouping()
        let targetFrame = NSRect(origin: restoreOrigin, size: size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            self.isResizingProgrammatically = false
            self.pendingRestoreOrigin = nil
            // Safety net: only snap if no new AI session was opened while the animation ran.
            // Without this guard, a rapid PTT query that fires within 0.35s gets collapsed
            // back to the pill position by this stale completion block.
            guard !self.state.showingAIConversation else { return }
            if self.frame != targetFrame {
                self.setFrame(targetFrame, display: true, animate: false)
            }
        }

        // Allow hover resizes again after the animation settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.suppressHoverResize = false
        }
    }

    // MARK: - Click-Outside Monitor

    /// Installs a global event monitor that fires when the user clicks outside the app.
    /// `windowDidResignKey` only detects in-app focus changes reliably; when the user
    /// clicks on another app or the desktop, `NSApp.currentEvent` doesn't contain a
    /// mouse-down from our process, so the resign-key check misses it.
    private func installGlobalClickOutsideMonitor() {
        removeGlobalClickOutsideMonitor()
        globalClickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.state.showingAIConversation, !self.suppressClickOutsideDismiss, !self.state.isCollapsed, !self.state.isVoiceListening else { return }
            // Don't collapse while AI is generating a response
            if self.state.showingAIResponse, self.state.currentAIMessage?.isStreaming == true || self.state.isAILoading { return }
            self.dismissConversationAnimated()
        }
    }

    private func removeGlobalClickOutsideMonitor() {
        if let monitor = globalClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickOutsideMonitor = nil
        }
    }

    /// Shared dismiss animation used by both windowDidResignKey (in-app) and global click monitor (cross-app).
    /// Collapses to half height and semi-transparent instead of fully closing.
    private func dismissConversationAnimated() {
        guard state.showingAIResponse, state.currentAIMessage != nil else {
            // No response to show — fully close
            closeAIConversation()
            return
        }

        resignKeyAnimationToken += 1
        state.isCollapsed = true
        preCollapseHeight = frame.height

        // Collapse to half height
        let halfHeight = frame.height / 2
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.5
        })
        resizeAnchored(to: NSSize(width: frame.width, height: halfHeight), makeResizable: false, animated: true)
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
        AnalyticsManager.shared.floatingBarToggled(visible: false, source: state.showingAIConversation ? "escape_ai" : "bar_button")
        onHide?()
    }

    // MARK: - Public State Updates

    func updateRecordingState(isRecording: Bool, duration: Int, isInitialising: Bool) {
        state.isRecording = isRecording
        state.duration = duration
        state.isInitialising = isInitialising
    }

    func showAIConversation() {
        // Resize window BEFORE changing state so SwiftUI content doesn't render
        // in the old 28x28 frame (which causes a visible jump).

        // Anchor from bottom so the control bar stays visually in place, chat grows upward.
        // 146 = default text editor(40) + overhead(106) — matches the inputViewHeight formula.
        let inputSize = NSSize(width: FloatingControlBarWindow.expandedWidth, height: 146)
        resizeAnchored(to: inputSize, makeResizable: false, animated: true)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.showingAIConversation = true
            state.showingAIResponse = false
            state.isAILoading = false
            state.aiInputText = ""
            state.currentAIMessage = nil
            // Match the explicit resize height so the observer doesn't immediately override it
            state.inputViewHeight = 146
        }
        setupInputHeightObserver()
        installGlobalClickOutsideMonitor()

        // Make the window key so the FazmTextEditor's focusOnAppear can take effect.
        // The text editor itself handles focusing via updateNSView once it's in the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.makeKeyAndOrderFront(nil)
        }

        // Fallback: explicitly focus the input after SwiftUI layout settles.
        // The AutoFocusScrollView.viewDidMoveToWindow() fires once and can miss
        // if the window isn't yet key at that moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.focusInputField()
        }

        // Auto-resume the last conversation if one was saved (click-away preserves chat)
        if let last = state.lastConversation {
            state.chatHistory = last.history
            state.displayedQuery = last.lastQuestion
            state.currentAIMessage = last.lastMessage
            state.isAILoading = false
            state.showingAIResponse = true
            state.clearLastConversation()
            resizeToResponseHeight(animated: true)
        }
    }

    func startNewChat() {
        // End tutorial chat guide if active
        if state.isTutorialChatActive {
            TutorialChatGuide.shared.finish(barState: state)
        }

        state.chatHistory = []
        state.displayedQuery = ""
        state.currentAIMessage = nil
        state.isAILoading = false
        state.showingAIResponse = false
        state.aiInputText = ""

        // Clear persisted messages and reset ACP session so restart doesn't reload old chat
        onResetSession?()

        let inputSize = NSSize(width: FloatingControlBarWindow.expandedWidth, height: 146)
        resizeAnchored(to: inputSize, makeResizable: false, animated: true)
        state.inputViewHeight = 146
        setupInputHeightObserver()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.focusInputField()
        }
    }

    private func setupInputHeightObserver() {
        inputHeightCancellable?.cancel()
        inputHeightCancellable = state.$inputViewHeight
            .removeDuplicates()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] height in
                guard let self = self,
                      self.state.showingAIConversation,
                      !self.state.showingAIResponse
                else { return }
                self.resizeToFixedHeight(height)
            }
    }

    func cancelInputHeightObserver() {
        inputHeightCancellable?.cancel()
        inputHeightCancellable = nil
    }

    func updateAIResponse(type: String, text: String) {
        guard state.showingAIConversation else { return }

        switch type {
        case "data":
            if state.isAILoading {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    state.isAILoading = false
                    state.showingAIResponse = true
                }
                resizeToResponseHeight(animated: true)
            }
            state.aiResponseText += text
        case "done":
            withAnimation(.easeOut(duration: 0.2)) {
                state.isAILoading = false
            }
            if !text.isEmpty {
                state.aiResponseText = text
            }
        case "error":
            withAnimation(.easeOut(duration: 0.2)) {
                state.isAILoading = false
            }
            state.aiResponseText = text.isEmpty ? "An unknown error occurred." : text
        default:
            break
        }
    }

    // MARK: - Window Geometry

    /// Bottom-center: keeps bottom edge at canonicalBottomY, centers horizontally.
    /// Uses the stored canonical Y instead of frame.origin.y to prevent drift.
    private func originForBottomCenterAnchor(newSize: NSSize) -> NSPoint {
        NSPoint(
            x: frame.midX - newSize.width / 2,
            y: canonicalBottomY
        )
    }

    private func resizeAnchored(to size: NSSize, makeResizable: Bool, animated: Bool = false) {
        // Cancel any pending resizeToFixedHeight work item to prevent stale resizes
        resizeWorkItem?.cancel()
        resizeWorkItem = nil

        let constrainedSize = NSSize(
            width: max(size.width, FloatingControlBarWindow.minBarSize.width),
            height: max(size.height, FloatingControlBarWindow.minBarSize.height)
        )
        let newOrigin = originForBottomCenterAnchor(newSize: constrainedSize)

        log("FloatingControlBar: resizeAnchored to \(constrainedSize) origin=\(newOrigin) resizable=\(makeResizable) animated=\(animated) from=\(frame.size) fromOrigin=\(frame.origin) canonicalY=\(canonicalBottomY)")

        if makeResizable {
            styleMask.insert(.resizable)
        } else {
            styleMask.remove(.resizable)
        }

        isResizingProgrammatically = true

        // On macOS 26+ (Tahoe), animated setFrame triggers NSHostingView.updateAnimatedWindowSize
        // which invalidates safe area insets -> view graph -> requestUpdate -> setNeedsUpdateConstraints,
        // causing an infinite constraint update loop (OMI-COMPUTER-1J). Disable implicit animations
        // during the resize to prevent the updateAnimatedWindowSize code path.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = animated ? 0.3 : 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.setFrame(NSRect(origin: newOrigin, size: constrainedSize), display: true, animate: animated)
        NSAnimationContext.endGrouping()

        self.isResizingProgrammatically = false
    }

    private func resizeToFixedHeight(_ height: CGFloat, animated: Bool = false) {
        resizeWorkItem?.cancel()
        let width = FloatingControlBarWindow.expandedWidth
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
        guard !state.showingAIConversation, !state.isVoiceListening, !suppressHoverResize else { return }
        resizeWorkItem?.cancel()
        resizeWorkItem = nil

        let targetSize = expanded ? FloatingControlBarWindow.expandedBarSize : FloatingControlBarWindow.minBarSize

        let doResize: () -> Void = { [weak self] in
            guard let self = self else { return }
            let newOrigin = self.originForBottomCenterAnchor(newSize: targetSize)
            self.styleMask.remove(.resizable)
            self.isResizingProgrammatically = true
            self.setFrame(NSRect(origin: newOrigin, size: targetSize), display: true, animate: false)
            self.isResizingProgrammatically = false
        }

        if expanded {
            // Expand synchronously so the window is already large enough when
            // SwiftUI re-evaluates body with isHovering=true.
            doResize()
        } else {
            // Collapse async to avoid blocking SwiftUI body evaluation during unhover.
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
        // Determine the 2× cap from the user's saved (or default) preferred height.
        let savedSize = UserDefaults.standard.string(forKey: FloatingControlBarWindow.sizeKey)
            .map(NSSizeFromString)
        let baseHeight = savedSize.map { max($0.height, Self.defaultBaseResponseHeight) } ?? Self.defaultBaseResponseHeight
        let maxHeight = baseHeight * 2

        // Start at the larger of minResponseHeight or current frame height so we never
        // shrink the window (e.g. during follow-up exchanges where it's already expanded).
        let startHeight = max(Self.minResponseHeight, frame.height)
        let initialSize = NSSize(width: Self.expandedWidth, height: startHeight)
        resizeAnchored(to: initialSize, makeResizable: true, animated: animated)
        setupResponseHeightObserver(maxHeight: maxHeight)
    }

    /// Observes `state.responseContentHeight` and expands the window to fit content,
    /// capped at `maxHeight`. Never shrinks automatically.
    private func setupResponseHeightObserver(maxHeight: CGFloat) {
        responseHeightCancellable?.cancel()
        responseHeightCancellable = state.$responseContentHeight
            .removeDuplicates()
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] contentHeight in
                guard let self = self,
                      self.state.showingAIResponse,
                      !self.isUserResizing,
                      contentHeight > 0
                else { return }
                let targetHeight = (contentHeight + Self.responseViewOverhead).rounded()
                let clampedHeight = min(max(targetHeight, Self.minResponseHeight), maxHeight)
                // Only expand, never auto-shrink.
                guard clampedHeight > self.frame.height + 2 else { return }
                self.resizeAnchored(
                    to: NSSize(width: Self.expandedWidth, height: clampedHeight),
                    makeResizable: true,
                    animated: true
                )
            }
    }

    /// Compute the default origin for the collapsed pill (bottom-center of the key screen).
    /// Used by closeAIConversation in non-draggable mode and centerOnMainScreen.
    private func defaultPillOrigin() -> NSPoint {
        let size = FloatingControlBarWindow.minBarSize
        let targetScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return .zero }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + 20
        return NSPoint(x: x, y: y)
    }

    /// Center the bar near the bottom of the main screen.
    private func centerOnMainScreen() {
        // Use the screen that has the key window, or fall back to main screen
        let targetScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else {
            self.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - frame.width / 2
        let y = visibleFrame.minY + 20  // 20pt from bottom, just above dock
        self.setFrameOrigin(NSPoint(x: x, y: y))
        canonicalBottomY = y
        log("FloatingControlBarWindow: centered at (\(x), \(y)) on screen \(visibleFrame)")
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
        guard state.showingAIConversation else { return }

        // Don't dismiss when already collapsed or during push-to-talk
        guard !state.isCollapsed, !state.isVoiceListening else { return }

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

        // Don't collapse while AI is generating a response
        if state.showingAIResponse, state.currentAIMessage?.isStreaming == true || state.isAILoading { return }

        dismissConversationAnimated()
    }

    @objc func windowDidMove(_ notification: Notification) {
        // Only persist position when the user is physically dragging the bar.
        // Programmatic moves (resize animations, chat open/close) should not
        // overwrite the saved position — that causes silent drift.
        guard isUserDragging else { return }
        canonicalBottomY = self.frame.origin.y
        UserDefaults.standard.set(
            NSStringFromPoint(self.frame.origin), forKey: FloatingControlBarWindow.positionKey
        )
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, FloatingControlBarWindow.minBarSize.width),
            height: max(frameSize.height, FloatingControlBarWindow.minBarSize.height)
        )
    }

    func windowDidResize(_ notification: Notification) {
        if !isResizingProgrammatically && !isUserResizing && state.showingAIResponse {
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
    private(set) var chatProvider: ChatProvider?
    private var workspaceObserver: Any?

    /// PID of the last active app before Fazm. Used to capture that app's window for screenshots.
    private(set) var lastActiveAppPID: pid_t = 0

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

    /// Create the floating bar window and wire up AppState bindings.
    func setup(appState: AppState, chatProvider: ChatProvider) {
        guard window == nil else {
            log("FloatingControlBarManager: setup() called but window already exists")
            return
        }
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
        barWindow.onAskAI = { [weak barWindow] in
            barWindow?.showAIConversation()
            barWindow?.makeKeyAndOrderFront(nil)
        }

        // Hide persists the preference so bar stays hidden across restarts
        barWindow.onHide = { [weak self] in
            self?.isEnabled = false
        }

        // Reuse the sidebar's ChatProvider (bridge is already warm from app startup)
        self.chatProvider = chatProvider

        barWindow.onSendQuery = { [weak self, weak barWindow, weak chatProvider] message in
            guard let self = self, let barWindow = barWindow, let provider = chatProvider else { return }
            Task { @MainActor in
                await self.sendAIQuery(message, barWindow: barWindow, provider: provider)
            }
        }

        barWindow.onInterruptAndFollowUp = { [weak chatProvider] message in
            guard let provider = chatProvider else { return }
            Task { @MainActor in
                await provider.sendFollowUp(message)
            }
        }

        barWindow.onStopAgent = { [weak chatProvider] in
            chatProvider?.stopAgent()
        }

        barWindow.onResetSession = { [weak chatProvider] in
            guard let provider = chatProvider else { return }
            Task { @MainActor in
                await provider.resetSession(key: "floating")
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
        // Trigger from terminal: `defaults write com.omi.computer-macos hasSeenPostOnboardingTutorial -bool false && /usr/bin/notifyutil -p com.omi.replayTutorial`
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.omi.replayTutorial"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let barState = self.barState else { return }
                log("FloatingControlBarManager: Replaying post-onboarding tutorial")
                PostOnboardingTutorialManager.shared.replay(barState: barState)
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

                // Show the bar and set up the UI as if the user typed the query
                if !window.isVisible { self.show() }
                window.state.displayedQuery = text
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    window.state.showingAIResponse = true
                }
                window.showAIConversation()

                await self.sendAIQuery(text, barWindow: window, provider: provider)
            }
        }
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

        // Auto-focus input if AI conversation is open
        if let window = window, window.state.showingAIConversation && !window.state.showingAIResponse {
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
    func cancelChat() {
        chatCancellable?.cancel()
        chatCancellable = nil
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

        // Activate the app so the window can become key and accept keyboard input.
        // Without this, makeFirstResponder silently fails when triggered from a global shortcut.
        NSApp.activate(ignoringOtherApps: true)

        // If a conversation is already showing, just focus the follow-up input
        if window.state.showingAIConversation && window.state.showingAIResponse {
            if !window.isVisible { show() }
            window.makeKeyAndOrderFront(nil)
            window.focusInputField()
            return
        }

        AnalyticsManager.shared.floatingBarAskFazmOpened(source: "shortcut")
        if !window.isVisible {
            show()
        }
        window.showAIConversation()
        window.orderFrontRegardless()
    }

    /// Open AI input with a pre-filled transcription from PTT (inserts into input field without sending).
    func openAIInputWithQuery(_ query: String) {
        guard let window = window else { return }

        // Cancel stale subscriptions immediately to prevent old data from flashing
        chatCancellable?.cancel()
        chatCancellable = nil
        window.cancelInputHeightObserver()

        // Reset state directly (no animation) to avoid contract-then-expand flicker
        window.state.showingAIConversation = false
        window.state.showingAIResponse = false
        window.state.aiInputText = ""
        window.state.currentAIMessage = nil
        window.state.chatHistory = []
        window.state.isVoiceFollowUp = false
        window.state.voiceFollowUpTranscript = ""

        guard let provider = self.chatProvider else { return }

        // Re-wire the onSendQuery to use the shared provider
        window.onSendQuery = { [weak self, weak window, weak provider] message in
            guard let self = self, let window = window, let provider = provider else { return }
            Task { @MainActor in
                await self.sendAIQuery(message, barWindow: window, provider: provider)
            }
        }

        window.onInterruptAndFollowUp = { [weak provider] message in
            guard let provider = provider else { return }
            Task { @MainActor in
                await provider.sendFollowUp(message)
            }
        }

        window.onStopAgent = { [weak provider] in
            provider?.stopAgent()
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

        // Show the input view with the transcription pre-filled (user can edit before sending)
        window.state.clearLastConversation()
        window.state.aiInputText = query
        window.showAIConversation()
        // Override the empty text that showAIConversation sets
        window.state.aiInputText = query
        window.orderFrontRegardless()

        // Focus the input field so user can immediately edit or press Enter to send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            window.focusInputField()
        }
    }

    /// Insert a PTT transcription into the follow-up input field (user can edit before sending).
    func sendFollowUpQuery(_ query: String) {
        guard let window = window, window.state.showingAIResponse else {
            // No active conversation — fall back to new conversation
            openAIInputWithQuery(query)
            return
        }

        // Insert transcription into the follow-up input field
        window.state.pendingFollowUpText = query
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

    /// Resize the floating bar for PTT state changes.
    func resizeForPTT(expanded: Bool) {
        window?.resizeForPTTState(expanded: expanded)
    }

    /// Close the AI conversation panel (used by PTT when no transcript was captured).
    func closeAIConversation() {
        window?.closeAIConversation()
    }

    /// Re-send the pending message that was interrupted by browser extension setup.
    /// Opens the floating bar and routes through `sendAIQuery` so streaming is wired up.
    func retryPendingQuery() {
        guard let provider = chatProvider,
              let text = provider.pendingRetryMessage else { return }
        provider.pendingRetryMessage = nil
        guard let window = window else { return }

        log("FloatingControlBarManager: Retrying pending query via floating bar")

        // Reset stale state
        chatCancellable?.cancel()
        chatCancellable = nil
        window.cancelInputHeightObserver()
        window.state.showingAIConversation = false
        window.state.showingAIResponse = false
        window.state.aiInputText = ""
        window.state.currentAIMessage = nil
        window.state.chatHistory = []
        window.state.clearLastConversation()

        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { show() }
        window.cancelPendingDismiss()
        window.savePreChatCenterIfNeeded()
        window.showAIConversation()
        window.orderFrontRegardless()

        // Restart the bridge so it picks up the newly-saved Playwright token,
        // then send the query through the normal streaming path.
        Task { @MainActor in
            await provider.restartBridgeForNewToken()
            await self.sendAIQuery(text, barWindow: window, provider: provider)
        }
    }

    // MARK: - AI Query

    private func sendAIQuery(_ message: String, barWindow: FloatingControlBarWindow, provider: ChatProvider) async {
        // Restore previous floating chat messages and session on first interaction
        await provider.restoreFloatingChatIfNeeded()

        // Populate the floating bar's chat history from restored messages
        if barWindow.state.chatHistory.isEmpty && barWindow.state.currentAIMessage == nil {
            let restored = provider.messages
            if !restored.isEmpty {
                // Pair up user/AI messages into exchanges for the history UI
                var i = 0
                while i < restored.count - 1 {
                    if restored[i].sender == .user, restored[i + 1].sender == .ai {
                        barWindow.state.chatHistory.append(
                            FloatingChatExchange(question: restored[i].text, aiMessage: restored[i + 1])
                        )
                        i += 2
                    } else {
                        i += 1
                    }
                }
                log("FloatingControlBarManager: Populated \(barWindow.state.chatHistory.count) exchanges from restored messages")
            }
        }

        // Capture the last active app's window (not the full desktop)
        let targetPID = self.lastActiveAppPID
        let needsHideBar = targetPID == 0 // Only hide for full-screen capture
        if needsHideBar {
            barWindow.orderOut(nil)
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms for window to disappear
        }
        let screenshotData = await Task.detached { () -> Data? in
            let url: URL?
            if targetPID != 0 {
                url = ScreenCaptureManager.captureAppWindow(pid: targetPID)
            } else {
                url = ScreenCaptureManager.captureScreen()
            }
            guard let url else { return nil }
            return try? Data(contentsOf: url)
        }.value
        if needsHideBar {
            barWindow.makeKeyAndOrderFront(nil)
        }

        AnalyticsManager.shared.floatingBarQuerySent(messageLength: message.count, hasScreenshot: screenshotData != nil)

        // Provider is already initialized by ViewModelContainer at app launch

        // Record message count before sending so we can detect the new AI response
        // in a shared provider that may already have many messages
        let messageCountBefore = provider.messages.count

        // Observe messages for streaming response
        chatCancellable?.cancel()
        barWindow.state.currentAIMessage = nil
        barWindow.state.isAILoading = true
        var hasSetUpResponseHeight = false
        chatCancellable = provider.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak barWindow] messages in
                // Find the AI response message added after our query
                guard messages.count > messageCountBefore,
                      let aiMessage = messages.last,
                      aiMessage.sender == .ai else { return }

                // Store the full ChatMessage (preserves contentBlocks, tool calls, thinking)
                barWindow?.state.currentAIMessage = aiMessage

                if aiMessage.isStreaming {
                    barWindow?.state.isAILoading = false
                    if let barWindow = barWindow, !hasSetUpResponseHeight {
                        hasSetUpResponseHeight = true
                        if !barWindow.state.showingAIResponse {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                barWindow.state.showingAIResponse = true
                            }
                        }
                        barWindow.resizeToResponseHeightPublic(animated: true)
                    }
                } else {
                    barWindow?.state.isAILoading = false
                }
            }

        await provider.sendMessage(message, model: ShortcutSettings.shared.selectedModel, systemPromptSuffix: barWindow.state.tutorialSystemPromptSuffix, systemPromptPrefix: ChatProvider.floatingBarSystemPromptPrefixCurrent, sessionKey: "floating", imageData: screenshotData)

        // Handle errors after sendMessage completes
        barWindow.state.isAILoading = false

        if let errorText = provider.errorMessage {
            // Provider reported an error (timeout, bridge crash, etc.)
            // Show it even if there's partial content — append to existing or create new message
            if barWindow.state.currentAIMessage != nil && !barWindow.state.aiResponseText.isEmpty {
                barWindow.state.currentAIMessage?.text += "\n\n⚠️ \(errorText)"
            } else {
                barWindow.state.currentAIMessage = ChatMessage(text: "⚠️ \(errorText)", sender: .ai)
            }
        } else if barWindow.state.currentAIMessage == nil || barWindow.state.aiResponseText.isEmpty {
            // No error message and no response — something else went wrong
            barWindow.state.currentAIMessage = ChatMessage(text: "Failed to get a response. Please try again.", sender: .ai)
        }

        // Ensure the response view is visible and resized (handles the case where
        // the sink never fired because no streaming data arrived before the error)
        if !barWindow.state.showingAIResponse {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                barWindow.state.showingAIResponse = true
            }
            barWindow.resizeToResponseHeightPublic(animated: true)
        }
    }
}

// Expose resizeToResponseHeight for the manager
extension FloatingControlBarWindow {
    func resizeToResponseHeightPublic(animated: Bool = false) {
        resizeToResponseHeight(animated: animated)
    }

    /// Snap the window to the pill position before opening a new chat.
    /// Always uses canonicalBottomY for Y to prevent any position jumps.
    func savePreChatCenterIfNeeded() {
        let size = FloatingControlBarWindow.minBarSize
        let origin = NSPoint(
            x: defaultPillOrigin().x,
            y: canonicalBottomY
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
