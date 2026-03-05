import Combine
import SwiftUI

/// A single question/answer exchange in the floating bar chat history.
struct FloatingChatExchange: Identifiable {
    let id = UUID()
    let question: String
    let aiMessage: ChatMessage
}

/// Observable object holding the state for the floating control bar.
@MainActor
class FloatingControlBarState: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var duration: Int = 0
    @Published var isInitialising: Bool = false
    @Published var isDragging: Bool = false

    // AI conversation state
    @Published var showingAIConversation: Bool = false
    @Published var showingAIResponse: Bool = false
    @Published var isAILoading: Bool = true
    @Published var aiInputText: String = ""
    @Published var currentAIMessage: ChatMessage? = nil
    @Published var displayedQuery: String = ""
    @Published var inputViewHeight: CGFloat = 120
    @Published var responseContentHeight: CGFloat = 0
    @Published var chatHistory: [FloatingChatExchange] = []

    /// Convenience accessor for plain-text response (used by window geometry and error handling).
    var aiResponseText: String {
        get { currentAIMessage?.text ?? "" }
        set {
            if currentAIMessage != nil {
                currentAIMessage?.text = newValue
            } else {
                currentAIMessage = ChatMessage(text: newValue, sender: .ai)
            }
        }
    }

    // Push-to-talk state
    @Published var isVoiceListening: Bool = false
    @Published var isVoiceLocked: Bool = false
    @Published var isVoiceFinalizing: Bool = false
    @Published var voiceTranscript: String = ""

    // Audio level for PTT visualization
    @Published var voiceAudioLevel: Float = 0.0

    // Voice follow-up state (PTT while AI conversation is active)
    @Published var isVoiceFollowUp: Bool = false
    @Published var voiceFollowUpTranscript: String = ""

    /// Pre-filled text for the follow-up input (set by PTT, consumed by AIResponseView)
    @Published var pendingFollowUpText: String = ""

    // Silence detection overlay
    @Published var isSilenceOverlayVisible: Bool = false
    private var silenceOverlayDismissWork: DispatchWorkItem?

    func showSilenceOverlay() {
        silenceOverlayDismissWork?.cancel()
        isSilenceOverlayVisible = true

        if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
            SilenceOverlayWindow.shared.show(below: barFrame)
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.dismissSilenceOverlay()
            }
        }
        silenceOverlayDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func dismissSilenceOverlay() {
        silenceOverlayDismissWork?.cancel()
        silenceOverlayDismissWork = nil
        isSilenceOverlayVisible = false
        SilenceOverlayWindow.shared.dismiss()
    }

    // Last conversation (in-memory only, survives dismiss but not app restart)
    var lastConversation: (history: [FloatingChatExchange], lastQuestion: String, lastMessage: ChatMessage)?

    var hasLastConversation: Bool { lastConversation != nil }

    func clearLastConversation() { lastConversation = nil }

    // Collapsed mode (half-height, semi-transparent, shown when clicking away)
    @Published var isCollapsed: Bool = false

    // Send button hint (pulsating animation during tutorial)
    @Published var showSendButtonHint: Bool = false

    // Tutorial chat guide state
    @Published var isTutorialChatActive: Bool = false
    @Published var tutorialChatStep: Int = 0  // 0 = first prompt done (from overlay), 1-3 = guided prompts
    @Published var tutorialWaitingForResponse: Bool = false

    /// Dynamic tutorial prompts (personalized from onboarding data)
    var tutorialPrompts: [(instruction: String, description: String)] = []

    /// System prompt suffix injected during tutorial (cleared on finish)
    var tutorialSystemPromptSuffix: String?

    // Model selection
    @Published var selectedModel: String = "claude-opus-4-6"

    /// Available models for the floating bar picker
    static let availableModels: [(id: String, label: String)] = [
        ("claude-opus-4-6", "Opus"),
        ("claude-sonnet-4-6", "Sonnet"),
    ]
}
