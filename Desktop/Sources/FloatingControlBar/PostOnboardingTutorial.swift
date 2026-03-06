import Cocoa
import Combine
import GRDB
import SwiftUI

// MARK: - Tutorial Step

enum TutorialStep: Int, CaseIterable {
    case selectMic = 0
    case pressKey = 1
    case speaking = 2
    case done = 3
}

// MARK: - TutorialViewModel

@MainActor
class TutorialViewModel: ObservableObject {
    @Published var step: TutorialStep = .selectMic
    @Published var pulseScale: CGFloat = 1.0

    private var pulseTimer: Timer?

    func startPulse() {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.pulseScale = 1.15
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        self.pulseScale = 1.0
                    }
                }
            }
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    deinit {
        pulseTimer?.invalidate()
    }
}

// MARK: - PostOnboardingTutorialManager

@MainActor
class PostOnboardingTutorialManager {
    static let shared = PostOnboardingTutorialManager()

    private var window: PostOnboardingTutorialWindow?
    private var viewModel = TutorialViewModel()
    private var cancellables = Set<AnyCancellable>()
    private let userDefaultsKey = "hasSeenPostOnboardingTutorial"

    private init() {}

    func showIfNeeded(barState: FloatingControlBarState) {
        guard !UserDefaults.standard.bool(forKey: userDefaultsKey) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.show()
            self.observeVoiceState(barState: barState)
        }
    }

    private func show() {
        guard window == nil else {
            log("PostOnboardingTutorial: show() skipped — window already exists")
            return
        }

        let tutorialWindow = PostOnboardingTutorialWindow(viewModel: viewModel)
        self.window = tutorialWindow

        positionLeftOfBar(tutorialWindow)
        log("PostOnboardingTutorial: show() — window frame=\(tutorialWindow.frame), barFrame=\(FloatingControlBarManager.shared.barWindowFrame ?? .zero)")

        // Re-position when step changes (content size changes)
        viewModel.$step
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.window != nil else { return }
                // Small delay to let SwiftUI layout update
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.positionLeftOfBar(window)
                }
            }
            .store(in: &cancellables)

        tutorialWindow.alphaValue = 0
        tutorialWindow.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            tutorialWindow.animator().alphaValue = 1
        }
    }

    private func positionLeftOfBar(_ tutorialWindow: NSWindow) {
        // Let SwiftUI determine the ideal content size
        let fittingSize = tutorialWindow.contentView?.fittingSize ?? NSSize(width: 340, height: 160)
        let windowSize = NSSize(width: max(fittingSize.width, 340), height: max(fittingSize.height, 120))

        if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
            // Position to the left of the bar, aligned so the arrow points at the bar's vertical center
            let x = barFrame.minX - windowSize.width - 12
            let y = barFrame.midY - windowSize.height / 2 + 180

            // If it would go off the left edge, position to the right instead
            if x < (NSScreen.main?.visibleFrame.minX ?? 0) {
                let xRight = barFrame.maxX + 12
                tutorialWindow.setFrame(NSRect(origin: NSPoint(x: xRight, y: y), size: windowSize), display: true)
            } else {
                tutorialWindow.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: windowSize), display: true)
            }
        } else if let screen = NSScreen.main {
            let x = screen.frame.midX - windowSize.width / 2
            let y = screen.visibleFrame.minY + 80
            tutorialWindow.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: windowSize), display: true)
        }
    }

    private func observeVoiceState(barState: FloatingControlBarState) {
        barState.$isVoiceListening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isListening in
                guard let self else { return }
                switch self.viewModel.step {
                case .selectMic:
                    // If user presses PTT while on mic step, advance to speaking
                    if isListening {
                        self.viewModel.stopPulse()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.viewModel.step = .speaking
                        }
                    }
                case .pressKey:
                    if isListening {
                        self.viewModel.stopPulse()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.viewModel.step = .speaking
                        }
                    }
                case .speaking:
                    if !isListening {
                        // Wait briefly, then check if silence overlay appeared (no speech detected).
                        // If so, go back to selectMic step instead of completing.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak barState] in
                            guard let self, let barState else { return }
                            if barState.isSilenceOverlayVisible {
                                // No speech detected — reset to mic selection
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    self.viewModel.step = .selectMic
                                }
                            } else {
                                // Speech detected — dismiss overlay and transition to guided chat
                                self.dismiss()
                                // Show pulsating send button hint and focus the input field
                                barState.showSendButtonHint = true
                                FloatingControlBarManager.shared.focusInputField()
                                // Start the tutorial chat guide — it will observe the first
                                // response and then guide the user through more test prompts
                                TutorialChatGuide.shared.start(barState: barState)
                            }
                        }
                    }
                case .done:
                    break
                }
            }
            .store(in: &cancellables)
    }

    func dismiss() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        cancellables.removeAll()
        viewModel.stopPulse()

        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.window?.orderOut(nil)
                self?.window = nil
            }
        })
    }

    /// Force-replay the tutorial (for debugging / demos).
    func replay(barState: FloatingControlBarState) {
        // Tear down any existing tutorial immediately (no animation)
        cancellables.removeAll()
        viewModel.stopPulse()
        window?.orderOut(nil)
        window = nil

        // End any active tutorial chat guide
        TutorialChatGuide.shared.finish(barState: barState)

        // Reset state
        viewModel = TutorialViewModel()
        UserDefaults.standard.set(false, forKey: userDefaultsKey)

        // Show after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.show()
            self.observeVoiceState(barState: barState)
        }
    }
}

// MARK: - TutorialChatGuide

/// Manages the guided tutorial chat experience in the floating bar.
/// After the overlay tutorial completes, this takes over and guides the user
/// through 3 test prompts via chat messages in the floating bar.
///
/// Key design:
/// - Prompts are personalized from onboarding data (ai_user_profiles + knowledge graph)
/// - The AI controls step progression via a [[TUTORIAL_STEP_DONE]] marker
/// - If the user says something off-topic, the AI redirects them
/// - On finish, the floating session is reset so tutorial context doesn't consume tokens
@MainActor
class TutorialChatGuide {
    static let shared = TutorialChatGuide()

    private var cancellables = Set<AnyCancellable>()

    /// Fallback prompts used when no onboarding data is available.
    static let defaultPrompts: [(instruction: String, description: String)] = [
        (
            "Open Safari and search for 'best productivity apps 2026'",
            "browser automation — opening apps and searching the web"
        ),
        (
            "Take a screenshot and describe what you see on my screen",
            "screen awareness — understanding what's on your display"
        ),
        (
            "Write a short email draft about rescheduling a meeting to tomorrow at 3pm",
            "text generation — drafting content for you"
        ),
    ]

    private init() {}

    /// Start the tutorial chat guide after the overlay tutorial's first successful voice interaction.
    func start(barState: FloatingControlBarState) {
        barState.isTutorialChatActive = true
        barState.tutorialChatStep = 0
        // The first voice query is already in flight when start() is called,
        // so mark as waiting so the response observer can detect [[TUTORIAL_STEP_DONE]].
        barState.tutorialWaitingForResponse = true

        // Load personalized prompts from onboarding data, then set up the tutorial
        Task {
            let prompts = await Self.buildPersonalizedPrompts()
            barState.tutorialPrompts = prompts
            barState.tutorialSystemPromptSuffix = Self.buildTutorialSuffix(step: 0, prompts: prompts)

            // Observe AI responses for the step-done marker
            self.observeResponses(barState: barState)
        }
    }

    /// Build personalized tutorial prompts from onboarding data.
    private static func buildPersonalizedPrompts() async -> [(instruction: String, description: String)] {
        // Fetch user profile and knowledge graph nodes
        let profile = await AIUserProfileService.shared.getLatestProfile()
        let nodes = await fetchKGNodes()

        guard let profileText = profile?.profileText, !profileText.isEmpty else {
            return defaultPrompts
        }

        // Extract useful context from KG nodes
        let projectNodes = nodes.filter { $0.nodeType == "thing" || $0.nodeType == "concept" }
        let toolNodes = nodes.filter { $0.nodeType == "concept" }
        let personNodes = nodes.filter { $0.nodeType == "person" }

        // Build personalized prompts based on what we know
        var prompts = defaultPrompts

        // Step 1: Browser automation — personalize the search query
        if let project = projectNodes.first {
            prompts[0] = (
                "Open Safari and search for '\(project.label) latest news'",
                "browser automation — opening apps and searching the web"
            )
        }

        // Step 2: Screen awareness — always useful as-is (screenshot + describe)

        // Step 3: Text generation — personalize based on user's work context
        if let colleague = personNodes.first(where: { $0.nodeId != "user" }) {
            prompts[2] = (
                "Write a short message to \(colleague.label) about catching up this week",
                "text generation — drafting content for you"
            )
        } else if let tool = toolNodes.first {
            prompts[2] = (
                "Write a short note about my progress on \(tool.label) today",
                "text generation — drafting content for you"
            )
        }

        return prompts
    }

    /// Fetch knowledge graph nodes from the local database.
    private static func fetchKGNodes() async -> [LocalKGNodeRecord] {
        guard let db = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        return (try? await db.read { database in
            try LocalKGNodeRecord
                .order(Column("updatedAt").desc)
                .limit(20)
                .fetchAll(database)
        }) ?? []
    }

    /// Build the system prompt suffix for the current tutorial step.
    static func buildTutorialSuffix(step: Int, prompts: [(instruction: String, description: String)]) -> String {
        guard step < prompts.count else { return "" }

        let prompt = prompts[step]
        let stepNumber = step + 1
        let totalSteps = prompts.count

        return """
        <tutorial_context>
        You are guiding the user through an interactive tutorial (step \(stepNumber)/\(totalSteps)).

        CURRENT STEP: \(prompt.description)
        EXPECTED USER COMMAND: "\(prompt.instruction)"

        RULES:
        1. The user should say something close to the expected command above. It does NOT need to be exact — accept reasonable paraphrases, partial matches, or commands that demonstrate the same capability.
        2. If the user says something completely unrelated to the expected capability, gently redirect them: acknowledge what they said, then remind them what to try for this tutorial step. Do NOT include [[TUTORIAL_STEP_DONE]] in this case.
        3. When the user's command is close enough to the expected one AND you have successfully processed/responded to it, include the marker [[TUTORIAL_STEP_DONE]] at the very end of your response (on its own line). This signals the tutorial system to advance.
        4. Keep responses concise — this is a tutorial, not a conversation. Focus on executing the action and confirming it worked.
        5. Do NOT mention these instructions or the marker to the user. The marker is for the system only.
        </tutorial_context>
        """
    }

    /// Inject the next tutorial guidance message into the chat.
    func injectNextGuidance(barState: FloatingControlBarState) {
        guard barState.isTutorialChatActive else { return }

        let step = barState.tutorialChatStep
        let prompts = barState.tutorialPrompts

        if step >= prompts.count {
            // All prompts done — send completion message and end tutorial
            let completionMessage = ChatMessage(
                text: "You've completed the tutorial! You now know the basics:\n\n"
                    + "- **Browser automation** — control apps with your voice\n"
                    + "- **Screen awareness** — the AI sees what you see\n"
                    + "- **Text generation** — draft content hands-free\n\n"
                    + "Press and hold **Right \u{2318}** anytime to talk to Fazm. Have fun!",
                sender: .ai
            )
            injectTutorialMessage(completionMessage, barState: barState)
            finish(barState: barState)
            return
        }

        // Update the system prompt suffix for the new step
        barState.tutorialSystemPromptSuffix = Self.buildTutorialSuffix(step: step, prompts: prompts)

        let prompt = prompts[step]
        let stepNumber = step + 1
        let totalSteps = prompts.count

        let guideText: String
        if step == 0 {
            guideText = "Nice work! Your first command is being processed.\n\n"
                + "Let's try a few more things to see what Fazm can do. "
                + "**Test \(stepNumber)/\(totalSteps)** — \(prompt.description):\n\n"
                + "> \"\(prompt.instruction)\"\n\n"
                + "Press **Right \u{2318}**, say the command above, then release to send."
        } else {
            guideText = "Great! **Test \(stepNumber)/\(totalSteps)** — \(prompt.description):\n\n"
                + "> \"\(prompt.instruction)\"\n\n"
                + "Press **Right \u{2318}**, say it, then release."
        }

        let guideMessage = ChatMessage(text: guideText, sender: .ai)
        injectTutorialMessage(guideMessage, barState: barState)
        barState.tutorialWaitingForResponse = false
    }

    /// Observe AI responses for the [[TUTORIAL_STEP_DONE]] marker to advance steps.
    private func observeResponses(barState: FloatingControlBarState) {
        cancellables.removeAll()

        // Watch for response text containing the step-done marker
        barState.$currentAIMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak barState] message in
                guard let self, let barState, barState.isTutorialChatActive else { return }
                guard !message.isStreaming, barState.tutorialWaitingForResponse else { return }
                guard message.text.contains("[[TUTORIAL_STEP_DONE]]") else { return }

                // Strip the marker from displayed text
                barState.currentAIMessage?.text = message.text
                    .replacingOccurrences(of: "[[TUTORIAL_STEP_DONE]]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // Advance to next step
                barState.tutorialWaitingForResponse = false
                barState.tutorialChatStep += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak barState] in
                    guard let self, let barState, barState.isTutorialChatActive else { return }
                    self.injectNextGuidance(barState: barState)
                }
            }
            .store(in: &cancellables)

        // Watch for when a new query is sent
        barState.$displayedQuery
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak barState] query in
                guard let barState, barState.isTutorialChatActive, !query.isEmpty else { return }
                barState.tutorialWaitingForResponse = true
            }
            .store(in: &cancellables)
    }

    /// Inject a tutorial message into the chat as a continuation of the conversation.
    private func injectTutorialMessage(_ message: ChatMessage, barState: FloatingControlBarState) {
        // Archive current exchange to history if there is one
        if let currentMessage = barState.currentAIMessage,
           !barState.displayedQuery.isEmpty,
           !currentMessage.text.isEmpty {
            barState.chatHistory.append(
                FloatingChatExchange(question: barState.displayedQuery, aiMessage: currentMessage)
            )
        }

        // Set empty query so the question bar is hidden, showing just the guide message
        barState.displayedQuery = ""
        barState.currentAIMessage = message
        barState.isAILoading = false
        if !barState.showingAIResponse {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                barState.showingAIResponse = true
            }
        }
    }

    /// End the tutorial chat guide and reset the floating session to free context.
    func finish(barState: FloatingControlBarState) {
        barState.isTutorialChatActive = false
        barState.tutorialWaitingForResponse = false
        barState.tutorialSystemPromptSuffix = nil
        barState.tutorialPrompts = []
        cancellables.removeAll()

        // Reset the floating ACP session so tutorial conversation history
        // doesn't consume context in future queries
        Task {
            if let provider = FloatingControlBarManager.shared.chatProvider {
                await provider.resetSession(key: "floating")
                log("TutorialChatGuide: Reset floating session to clear tutorial context")
            }
        }
    }
}

// MARK: - PostOnboardingTutorialWindow

class PostOnboardingTutorialWindow: NSWindow {
    init(viewModel: TutorialViewModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 540, height: 380)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.appearance = NSAppearance(named: .vibrantDark)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView: PostOnboardingTutorialView(viewModel: viewModel, onSkip: { [weak self] in
            Task { @MainActor in
                PostOnboardingTutorialManager.shared.dismiss()
                _ = self  // prevent unused capture warning
            }
        }))
        self.contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - PostOnboardingTutorialView

struct PostOnboardingTutorialView: View {
    @ObservedObject var viewModel: TutorialViewModel
    var onSkip: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Card
            VStack(spacing: 12) {
                stepContent
                    .animation(.easeInOut(duration: 0.3), value: viewModel.step)

                // Progress dots
                HStack(spacing: 8) {
                    ForEach(TutorialStep.allCases, id: \.rawValue) { step in
                        Circle()
                            .fill(step == viewModel.step ? FazmColors.purplePrimary : Color.white.opacity(0.3))
                            .frame(width: step == viewModel.step ? 8 : 6, height: step == viewModel.step ? 8 : 6)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.step)
                    }
                }

                if viewModel.step != .done {
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(.system(size: 12))
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(width: viewModel.step == .pressKey ? 520 : 320)
            .background(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
            )

            // Right-pointing arrow toward the floating bar (offset down to align with bar center)
            RightTriangle()
                .fill(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
                .frame(width: 8, height: 16)
                .offset(y: 180)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .selectMic:
            VStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(FazmColors.purplePrimary)
                Text("Select your microphone")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Make sure you see the level bars move when you speak")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                TutorialMicPicker()
                    .padding(.top, 2)

                Button {
                    viewModel.startPulse()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        viewModel.step = .pressKey
                    }
                } label: {
                    Text("Next")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(FazmColors.purplePrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .transition(.opacity)

        case .pressKey:
            VStack(spacing: 8) {
                KeyboardBottomRowView(pulseScale: viewModel.pulseScale)
                Text("Press and hold Right ⌘ to talk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your voice becomes your cursor")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)

        case .speaking:
            VStack(spacing: 10) {
                ActiveListeningIndicator()
                    .frame(height: 28)

                VStack(spacing: 4) {
                    Text("Say:")
                        .font(.system(size: 12))
                        .foregroundColor(FazmColors.textTertiary)

                    SpeakingPromptText(text: "Google fazm.ai, click the first result, read through the website, then go to my Twitter and draft a post about it")
                }

                Text("Then release ⌘ to send")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)

        case .done:
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(FazmColors.purplePrimary)
                Text("You're ready!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FazmColors.textPrimary)
                Text("Right ⌘ → speak → release, anytime")
                    .font(.system(size: 12))
                    .foregroundColor(FazmColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - SpeakingPromptText

struct SpeakingPromptText: View {
    let text: String
    @State private var glowPhase: CGFloat = 0
    @State private var scalePhase: CGFloat = 1.0

    var body: some View {
        Text("\"\(text)\"")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: FazmColors.purplePrimary.opacity(0.5 + glowPhase * 0.5), radius: 6 + glowPhase * 10, x: 0, y: 0)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(FazmColors.purplePrimary.opacity(0.1 + glowPhase * 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(FazmColors.purplePrimary.opacity(0.4 + glowPhase * 0.4), lineWidth: 1.5)
            )
            .scaleEffect(scalePhase)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    glowPhase = 1
                }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    scalePhase = 1.03
                }
            }
    }
}

// MARK: - KeyboardBottomRowView

/// Full Mac keyboard layout with the Right ⌘ key highlighted and animated.
struct KeyboardBottomRowView: View {
    var pulseScale: CGFloat

    @State private var isPressed = false

    private let kh: CGFloat = 28       // standard key height
    private let khSmall: CGFloat = 14  // half-height arrow keys
    private let gap: CGFloat = 2
    private let keyColor = Color(nsColor: NSColor(white: 0.15, alpha: 1.0))
    private let keyBorder = Color(nsColor: NSColor(white: 0.28, alpha: 1.0))

    var body: some View {
        VStack(spacing: gap) {
            // Row 1: Esc + F-keys
            HStack(spacing: gap) {
                key("esc", w: 30)
                Spacer().frame(width: 8)
                key("F1", w: 30); key("F2", w: 30); key("F3", w: 30); key("F4", w: 30)
                Spacer().frame(width: 4)
                key("F5", w: 30); key("F6", w: 30); key("F7", w: 30); key("F8", w: 30)
                Spacer().frame(width: 4)
                key("F9", w: 30); key("F10", w: 28); key("F11", w: 28); key("F12", w: 28)
            }

            // Row 2: Number row
            HStack(spacing: gap) {
                key("`", w: 28)
                key("1", w: 28); key("2", w: 28); key("3", w: 28); key("4", w: 28); key("5", w: 28)
                key("6", w: 28); key("7", w: 28); key("8", w: 28); key("9", w: 28); key("0", w: 28)
                key("-", w: 28); key("=", w: 28)
                key("⌫", w: 42)
            }

            // Row 3: QWERTY
            HStack(spacing: gap) {
                key("⇥", w: 38)
                key("Q", w: 28); key("W", w: 28); key("E", w: 28); key("R", w: 28); key("T", w: 28)
                key("Y", w: 28); key("U", w: 28); key("I", w: 28); key("O", w: 28); key("P", w: 28)
                key("[", w: 28); key("]", w: 28)
                key("\\", w: 38)
            }

            // Row 4: ASDF
            HStack(spacing: gap) {
                key("⇪", w: 46)
                key("A", w: 28); key("S", w: 28); key("D", w: 28); key("F", w: 28); key("G", w: 28)
                key("H", w: 28); key("J", w: 28); key("K", w: 28); key("L", w: 28)
                key(";", w: 28); key("'", w: 28)
                key("⏎", w: 50)
            }

            // Row 5: ZXCV
            HStack(spacing: gap) {
                key("⇧", w: 62)
                key("Z", w: 28); key("X", w: 28); key("C", w: 28); key("V", w: 28); key("B", w: 28)
                key("N", w: 28); key("M", w: 28); key(",", w: 28); key(".", w: 28); key("/", w: 28)
                key("⇧", w: 62)
            }

            // Row 6: Bottom modifier row
            HStack(spacing: gap) {
                key("fn", w: 28)
                key("⌃", w: 28)
                key("⌥", w: 34)
                key("⌘", w: 38)
                key("", w: 130)  // space bar
                rightCommandKey   // Right ⌘ — highlighted
                key("⌥", w: 34)
                // Arrow cluster
                HStack(spacing: 1) {
                    key("◀", w: 20)
                    VStack(spacing: 1) {
                        key("▲", w: 20, h: khSmall)
                        key("▼", w: 20, h: khSmall)
                    }
                    key("▶", w: 20)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(white: 0.08, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear {
            startPressAnimation()
        }
    }

    private func startPressAnimation() {
        withAnimation(.easeIn(duration: 0.15)) {
            isPressed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.15)) {
                isPressed = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                startPressAnimation()
            }
        }
    }

    private var rightCommandKey: some View {
        Text("⌘")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 38, height: kh)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(FazmColors.purplePrimary.opacity(isPressed ? 0.6 : 0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(FazmColors.purplePrimary.opacity(isPressed ? 1.0 : 0.7), lineWidth: 1.5)
            )
            .shadow(color: FazmColors.purplePrimary.opacity(isPressed ? 0.8 : 0.4), radius: isPressed ? 12 : 5, x: 0, y: 0)
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isPressed)
    }

    private func key(_ label: String, w: CGFloat, h: CGFloat? = nil) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color.white.opacity(0.4))
            .frame(width: w, height: h ?? kh)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(keyColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(keyBorder, lineWidth: 0.5)
            )
    }
}

// MARK: - KeyCapView

struct KeyCapView: View {
    var pulseScale: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text("⌘")
                .font(.system(size: 16, weight: .medium))
            Text("Right")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(FazmColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor(white: 0.18, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(FazmColors.purplePrimary.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: FazmColors.purplePrimary.opacity(0.4), radius: 8 * pulseScale, x: 0, y: 0)
        .scaleEffect(pulseScale)
    }
}

// MARK: - ActiveListeningIndicator

struct ActiveListeningIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FazmColors.purplePrimary)
                    .frame(width: 3, height: animating ? barHeight(for: index) : 4)
                    .animation(
                        .easeInOut(duration: 0.4 + Double(index) * 0.1)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [12, 20, 28, 18, 14]
        return heights[index]
    }
}

// MARK: - TutorialMicPicker

/// Compact mic picker + audio level bars for the tutorial's first step.
private struct TutorialMicPicker: View {
    @ObservedObject private var deviceManager = AudioDeviceManager.shared

    private var selectedDeviceName: String {
        if let uid = deviceManager.selectedDeviceUID,
           let device = deviceManager.devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                showMicMenu()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                    Text(selectedDeviceName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            AudioLevelBarsSettingsView(level: deviceManager.currentAudioLevel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { deviceManager.startLevelMonitoring() }
        .onDisappear { deviceManager.stopLevelMonitoring() }
    }

    private func showMicMenu() {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(TutorialMicMenuTarget.selectDevice(_:)), keyEquivalent: "")
        defaultItem.target = TutorialMicMenuTarget.shared
        defaultItem.representedObject = nil as String?
        if deviceManager.selectedDeviceUID == nil {
            defaultItem.state = .on
        }
        menu.addItem(defaultItem)
        menu.addItem(NSMenuItem.separator())

        for device in deviceManager.devices {
            let item = NSMenuItem(title: device.name, action: #selector(TutorialMicMenuTarget.selectDevice(_:)), keyEquivalent: "")
            item.target = TutorialMicMenuTarget.shared
            item.representedObject = device.uid
            if deviceManager.selectedDeviceUID == device.uid {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private class TutorialMicMenuTarget: NSObject {
    static let shared = TutorialMicMenuTarget()

    @objc func selectDevice(_ sender: NSMenuItem) {
        Task { @MainActor in
            AudioDeviceManager.shared.selectedDeviceUID = sender.representedObject as? String
        }
    }
}

// MARK: - Triangle Shapes

/// Right-pointing triangle (arrow pointing toward the floating bar).
struct RightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
