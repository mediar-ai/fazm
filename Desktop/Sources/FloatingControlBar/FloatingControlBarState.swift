import Combine
import SwiftUI

/// A single question/answer exchange in the floating bar chat history.
struct FloatingChatExchange: Identifiable, Equatable {
    let id: UUID
    let question: String
    var aiMessage: ChatMessage
    /// The id of the user-side ChatMessage that produced `question`. Set when
    /// the exchange is reconstructed from `ChatProvider.messages` (via
    /// `loadHistory`) so the edit-and-resubmit affordance can find the source
    /// message in the provider's messages array. nil for placeholder /
    /// observer-only exchanges and for live appends that don't have a message
    /// id available at construction time — those exchanges just don't surface
    /// the edit affordance.
    var userMessageId: String?

    init(question: String, aiMessage: ChatMessage, userMessageId: String? = nil) {
        self.id = UUID()
        self.question = question
        self.aiMessage = aiMessage
        self.userMessageId = userMessageId
    }

    static func == (lhs: FloatingChatExchange, rhs: FloatingChatExchange) -> Bool {
        lhs.id == rhs.id
            && lhs.question == rhs.question
            && lhs.aiMessage == rhs.aiMessage
            && lhs.userMessageId == rhs.userMessageId
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

/// Streaming AI response state. Split from `FloatingControlBarState` so views
/// that don't render streaming content (input box, voice meter, settings panes)
/// don't re-render on every streaming state change.
///
/// Pair this with `ChatMessage` being `@Observable`: token deltas mutate the
/// message instance directly, causing only views that read `message.text` to
/// re-render. State transitions tracked here (currentAIMessage assignment,
/// isAILoading flips, chatHistory append) are rare and only invalidate views
/// that explicitly observe `StreamingResponseState`.
@MainActor
final class StreamingResponseState: ObservableObject {
    @Published var showingAIConversation: Bool = false
    @Published var showingAIResponse: Bool = false
    @Published var isAILoading: Bool = true
    @Published var isCompacting: Bool = false
    /// True while the ACP bridge is cold-starting. Mirrored from
    /// `ChatProvider.isBridgeWarmingUp` so the header can show "preparing
    /// assistant…" instead of a bare "thinking" spinner when a query is queued
    /// behind first-launch warmup.
    @Published var isBridgeWarmingUp: Bool = false
    @Published var isChatObserverRunning: Bool = false
    @Published var currentAIMessage: ChatMessage? = nil
    @Published var displayedQuery: String = ""
    @Published var chatHistory: [FloatingChatExchange] = []
    /// Chat observer cards queued while a query is streaming — rendered below the current response.
    @Published var pendingChatObserverExchanges: [FloatingChatExchange] = []
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

    /// Move any pending chat observer cards into chatHistory (call when archiving the current exchange).
    func flushPendingChatObserverExchanges() {
        guard !pendingChatObserverExchanges.isEmpty else { return }
        chatHistory.append(contentsOf: pendingChatObserverExchanges)
        pendingChatObserverExchanges.removeAll()
    }

    /// Pre-populate chatHistory from ChatProvider's messages so previous conversation is visible on fresh launch.
    func loadHistory(from messages: [ChatMessage]) {
        var exchanges: [FloatingChatExchange] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            if msg.sender == .user, i + 1 < messages.count, messages[i + 1].sender == .ai {
                exchanges.append(FloatingChatExchange(
                    question: msg.text,
                    aiMessage: messages[i + 1],
                    userMessageId: msg.id
                ))
                i += 2
            } else {
                i += 1
            }
        }
        chatHistory = exchanges
    }
}

/// User input state — typed text, attachments, queued messages, drag overlay.
/// Split from `FloatingControlBarState` so the input box doesn't re-render on
/// streaming/voice/settings changes.
@MainActor
final class InputState: ObservableObject {
    @Published var aiInputText: String = ""
    @Published var pendingFollowUpText: String = ""
    @Published var pendingAttachments: [ChatAttachment] = []
    @Published var isDragOverChat: Bool = false
    @Published var inputViewHeight: CGFloat = 146
    @Published var messageQueue: [QueuedMessage] = []

    /// Draft input text preserved when the conversation is dismissed without sending.
    var draftInputText: String = ""

    /// Maximum number of queued messages.
    static let maxQueueSize = 10

    /// Append a message to the queue. Returns false if queue is full.
    @discardableResult
    func enqueue(_ text: String) -> Bool {
        guard messageQueue.count < Self.maxQueueSize else { return false }
        messageQueue.append(QueuedMessage(text: text))
        return true
    }

    /// Remove a queued message by ID.
    func dequeue(_ id: UUID) {
        messageQueue.removeAll { $0.id == id }
    }

    /// Remove and return the first queued message.
    @discardableResult
    func dequeueFirst() -> QueuedMessage? {
        guard !messageQueue.isEmpty else { return nil }
        return messageQueue.removeFirst()
    }

    /// Clear all queued messages.
    func clearQueue() {
        messageQueue.removeAll()
    }
}

/// Push-to-talk and voice state — listening flags, recording timer, silence overlay.
/// Split from `FloatingControlBarState` so PTT updates (which fire several times
/// per second while the user holds the key) don't re-render unrelated subtrees.
@MainActor
final class VoiceState: ObservableObject {
    @Published var isVoiceListening: Bool = false
    @Published var isVoiceLocked: Bool = false
    @Published var isVoiceFinalizing: Bool = false
    @Published var isVoiceFollowUp: Bool = false
    @Published var voiceFollowUpTranscript: String = ""
    @Published var isRecording: Bool = false
    @Published var duration: Int = 0
    @Published var isInitialising: Bool = false
    @Published var isSilenceOverlayVisible: Bool = false
}

/// Per-window workspace + model selection. Pop-out windows track their own
/// model and working directory independently, plus discovered project metadata
/// (CLAUDE.md, skills) for the workspace.
@MainActor
final class WorkspaceSettingsState: ObservableObject {
    @Published var selectedModel: String = ShortcutSettings.shared.selectedModel
    @Published var workspaceDirectory: String = ""
    @Published var projectClaudeMdContent: String?
    @Published var projectClaudeMdPath: String?
    @Published var projectDiscoveredSkills: [(name: String, description: String, path: String)] = []
}

/// Tutorial chat guide state. Active during onboarding's "guided prompt" phase;
/// pure settings/UI flags otherwise.
@MainActor
final class TutorialState: ObservableObject {
    @Published var isTutorialChatActive: Bool = false
    @Published var tutorialChatStep: Int = 0  // 0 = first prompt done (from overlay), 1-3 = guided prompts
    @Published var tutorialWaitingForResponse: Bool = false

    /// Dynamic tutorial prompts (personalized from onboarding data).
    var tutorialPrompts: [(instruction: String, description: String)] = []

    /// System prompt suffix injected during tutorial (cleared on finish).
    var tutorialSystemPromptSuffix: String?
}

/// Observable object holding the state for the floating control bar.
///
/// Streaming-related fields live on `streaming` (a child `StreamingResponseState`)
/// rather than directly on this class, so high-frequency streaming updates only
/// invalidate views that explicitly observe `StreamingResponseState` — not the
/// entire UI tree of every view that takes `FloatingControlBarState` as an
/// `@EnvironmentObject`.
@MainActor
class FloatingControlBarState: NSObject, ObservableObject {
    /// Streaming AI response state — currentAIMessage, chatHistory, isAILoading, etc.
    /// Inject into views via `.environmentObject(state.streaming)` and observe
    /// directly with `@EnvironmentObject var streaming: StreamingResponseState`
    /// in views that render streaming content.
    let streaming = StreamingResponseState()

    /// User input state — typed text, attachments, queued messages, drag overlay.
    let input = InputState()

    /// Voice / push-to-talk state.
    let voice = VoiceState()

    /// Per-window workspace + model + project CLAUDE.md/skills.
    let workspace = WorkspaceSettingsState()

    /// Tutorial guide state.
    let tutorial = TutorialState()

    @Published var isDragging: Bool = false

    // Audio level for PTT visualization — uses a separate observable
    // to avoid re-rendering the entire conversation view on every level change.
    let audioLevel = AudioLevelState()

    // Silence detection overlay (visibility flag lives on `voice`).
    private var silenceOverlayDismissWork: DispatchWorkItem?

    func showSilenceOverlay() {
        silenceOverlayDismissWork?.cancel()
        voice.isSilenceOverlayVisible = true

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
        voice.isSilenceOverlayVisible = false
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

    /// Forwarder for `streaming.flushPendingChatObserverExchanges()`.
    /// Kept on the parent so existing `state.flushPendingChatObserverExchanges()`
    /// call sites continue to compile.
    func flushPendingChatObserverExchanges() {
        streaming.flushPendingChatObserverExchanges()
    }

    /// Forwarder for `streaming.loadHistory(from:)`. Kept on the parent so
    /// existing `state.loadHistory(...)` call sites continue to compile.
    func loadHistory(from messages: [ChatMessage]) {
        streaming.loadHistory(from: messages)
    }

    /// Forwarders for the queue helpers, since callsites currently invoke them on
    /// the parent state. Long-term these can move to direct `state.input.X` calls.
    @discardableResult
    func enqueue(_ text: String) -> Bool { input.enqueue(text) }
    func dequeue(_ id: UUID) { input.dequeue(id) }
    @discardableResult
    func dequeueFirst() -> QueuedMessage? { input.dequeueFirst() }
    func clearQueue() { input.clearQueue() }

    /// Forwarder for the queue size limit so existing
    /// `FloatingControlBarState.maxQueueSize` references continue to compile.
    static let maxQueueSize = InputState.maxQueueSize

    override init() {
        super.init()
    }
}
