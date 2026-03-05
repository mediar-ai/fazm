import Cocoa
import Combine
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
            // Position to the left of the bar, vertically centered on it
            let x = barFrame.minX - windowSize.width - 12
            let y = barFrame.midY - windowSize.height / 2

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
@MainActor
class TutorialChatGuide {
    static let shared = TutorialChatGuide()

    private var cancellables = Set<AnyCancellable>()

    /// The test prompts the tutorial guides the user through.
    static let testPrompts: [(instruction: String, description: String)] = [
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
        barState.tutorialWaitingForResponse = false

        // Observe when AI responses complete to inject next tutorial guidance
        observeResponses(barState: barState)
    }

    /// Inject the next tutorial guidance message into the chat.
    /// Called after a response finishes to tell the user what to try next.
    func injectNextGuidance(barState: FloatingControlBarState) {
        guard barState.isTutorialChatActive else { return }

        let step = barState.tutorialChatStep

        if step >= Self.testPrompts.count {
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

        let prompt = Self.testPrompts[step]
        let stepNumber = step + 1
        let totalSteps = Self.testPrompts.count

        let guideText: String
        if step == 0 {
            // First guided prompt — introduce what we're doing
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

    /// Observe when the AI finishes responding so we can inject the next tutorial step.
    private func observeResponses(barState: FloatingControlBarState) {
        cancellables.removeAll()

        // Watch for when currentAIMessage.isStreaming transitions to false (response complete).
        // Use map + removeDuplicates to only fire when the streaming flag actually changes.
        barState.$currentAIMessage
            .map { $0?.isStreaming ?? false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak barState] isStreaming in
                guard let self, let barState, barState.isTutorialChatActive else { return }
                guard !isStreaming, barState.tutorialWaitingForResponse else { return }
                // Response finished streaming
                barState.tutorialWaitingForResponse = false
                barState.tutorialChatStep += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak barState] in
                    guard let self, let barState, barState.isTutorialChatActive else { return }
                    self.injectNextGuidance(barState: barState)
                }
            }
            .store(in: &cancellables)

        // Watch for when a new query is sent (displayedQuery changes to non-empty)
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

    /// End the tutorial chat guide.
    func finish(barState: FloatingControlBarState) {
        barState.isTutorialChatActive = false
        barState.tutorialWaitingForResponse = false
        cancellables.removeAll()
    }
}

// MARK: - PostOnboardingTutorialWindow

class PostOnboardingTutorialWindow: NSWindow {
    init(viewModel: TutorialViewModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 320, height: 160)),
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
            .frame(width: 320)
            .floatingBackground(cornerRadius: 16)

            // Right-pointing arrow toward the floating bar
            RightTriangle()
                .fill(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
                .frame(width: 8, height: 16)
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
                KeyCapView(pulseScale: viewModel.pulseScale)
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

    var body: some View {
        Text("\"\(text)\"")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: FazmColors.purplePrimary.opacity(0.6), radius: 4 + glowPhase * 4, x: 0, y: 0)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(FazmColors.purplePrimary.opacity(0.12 + glowPhase * 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(FazmColors.purplePrimary.opacity(0.3 + glowPhase * 0.2), lineWidth: 1)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    glowPhase = 1
                }
            }
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
