import Combine
import SwiftUI

/// A single question/answer exchange in the floating bar chat history.
struct FloatingChatExchange: Identifiable, Equatable {
    let id: UUID
    let question: String
    var aiMessage: ChatMessage

    init(question: String, aiMessage: ChatMessage) {
        self.id = UUID()
        self.question = question
        self.aiMessage = aiMessage
    }

    static func == (lhs: FloatingChatExchange, rhs: FloatingChatExchange) -> Bool {
        lhs.id == rhs.id
            && lhs.question == rhs.question
            && lhs.aiMessage == rhs.aiMessage
    }
}

/// A message waiting in the queue to be sent after the current query finishes.
struct QueuedMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let text: String
    let timestamp: Date = Date()

    static func == (lhs: QueuedMessage, rhs: QueuedMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Lightweight observable for rapidly-changing PTT state that doesn't
/// trigger re-renders of the entire conversation view tree.
@MainActor
class AudioLevelState: ObservableObject {
    @Published var level: Float = 0.0
    @Published var transcript: String = ""
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
    @Published var isCompacting: Bool = false
    @Published var isObserverRunning: Bool = false
    @Published var aiInputText: String = ""
    @Published var currentAIMessage: ChatMessage? = nil
    @Published var displayedQuery: String = ""
    @Published var inputViewHeight: CGFloat = 146
    @Published var chatHistory: [FloatingChatExchange] = []
    /// Observer cards queued while a query is streaming — rendered below the current response.
    @Published var pendingObserverExchanges: [FloatingChatExchange] = []
    @Published var suggestedReplies: [String] = []
    @Published var suggestedReplyQuestion: String = ""

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


    // Audio level for PTT visualization — uses a separate observable
    // to avoid re-rendering the entire conversation view on every level change.
    let audioLevel = AudioLevelState()

    // Voice follow-up state (PTT while AI conversation is active)
    @Published var isVoiceFollowUp: Bool = false
    @Published var voiceFollowUpTranscript: String = ""

    /// Pre-filled text for the follow-up input (set by PTT, consumed by AIResponseView)
    @Published var pendingFollowUpText: String = ""

    /// Task queue: messages waiting to be sent after current query completes (max 10)
    @Published var messageQueue: [QueuedMessage] = []

    /// Maximum number of queued messages
    static let maxQueueSize = 10

    /// Append a message to the queue. Returns false if queue is full.
    @discardableResult
    func enqueue(_ text: String) -> Bool {
        guard messageQueue.count < Self.maxQueueSize else { return false }
        messageQueue.append(QueuedMessage(text: text))
        return true
    }

    /// Remove a queued message by ID
    func dequeue(_ id: UUID) {
        messageQueue.removeAll { $0.id == id }
    }

    /// Remove and return the first queued message
    @discardableResult
    func dequeueFirst() -> QueuedMessage? {
        guard !messageQueue.isEmpty else { return nil }
        return messageQueue.removeFirst()
    }

    /// Clear all queued messages
    func clearQueue() {
        messageQueue.removeAll()
    }

    /// Draft input text preserved when the conversation is dismissed without sending
    var draftInputText: String = ""

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

    // Claude account connection prompt (shown when auth is needed or credits exhausted)
    @Published var showConnectClaudeButton: Bool = false
    // Show "Upgrade" button when user hits personal Claude rate limit
    @Published var showUpgradeClaudeButton: Bool = false

    // Tutorial chat guide state
    @Published var isTutorialChatActive: Bool = false
    @Published var tutorialChatStep: Int = 0  // 0 = first prompt done (from overlay), 1-3 = guided prompts
    @Published var tutorialWaitingForResponse: Bool = false

    /// Dynamic tutorial prompts (personalized from onboarding data)
    var tutorialPrompts: [(instruction: String, description: String)] = []

    /// System prompt suffix injected during tutorial (cleared on finish)
    var tutorialSystemPromptSuffix: String?

    /// Move any pending observer cards into chatHistory (call when archiving the current exchange).
    func flushPendingObserverExchanges() {
        guard !pendingObserverExchanges.isEmpty else { return }
        chatHistory.append(contentsOf: pendingObserverExchanges)
        pendingObserverExchanges.removeAll()
    }

    /// Pre-populate chatHistory from ChatProvider's messages so previous conversation is visible on fresh launch.
    func loadHistory(from messages: [ChatMessage]) {
        var exchanges: [FloatingChatExchange] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            if msg.sender == .user, i + 1 < messages.count, messages[i + 1].sender == .ai {
                exchanges.append(FloatingChatExchange(question: msg.text, aiMessage: messages[i + 1]))
                i += 2
            } else {
                i += 1
            }
        }
        chatHistory = exchanges
    }

    // Model selection
    @Published var selectedModel: String = "claude-opus-4-6"

    /// Available models for the floating bar picker
    static let availableModels: [(id: String, label: String)] = [
        ("claude-opus-4-6", "Opus"),
        ("claude-sonnet-4-6", "Sonnet"),
    ]

}
