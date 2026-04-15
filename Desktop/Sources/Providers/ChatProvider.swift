import SwiftUI
import Combine
import GRDB
import Sentry

extension Notification.Name {
    /// Posted by ChatProvider when it dequeues and starts processing a pending message.
    /// userInfo contains "text" key with the dequeued message text.
    static let chatProviderDidDequeue = Notification.Name("chatProviderDidDequeue")
}

// MARK: - UserDefaults Extension for KVO

extension UserDefaults {
    @objc dynamic var playwrightUseExtension: Bool {
        return bool(forKey: "playwrightUseExtension")
    }
    @objc dynamic var playwrightExtensionToken: String? {
        return string(forKey: "playwrightExtensionToken")
    }
    @objc dynamic var voiceResponseEnabled: Bool {
        return bool(forKey: "voiceResponseEnabled")
    }
}


// MARK: - Content Block Model

/// Structured tool input for inline display
struct ToolCallInput: Equatable {
    /// Short summary for inline display (e.g., file path, command)
    let summary: String
    /// Full JSON details for expanded view
    let details: String?
}

/// Button for chat observer cards (auto-accepted; only "Deny" shown for rollback)
struct ObserverCardButton: Identifiable, Equatable {
    let id: String
    let label: String
    let action: String  // "dismiss" (rollback), "approve" (internal only)
}

/// A block of content within an AI message (text or tool call indicator)
enum ChatContentBlock: Identifiable, Equatable {
    case text(id: String, text: String)
    case toolCall(id: String, name: String, status: ToolCallStatus,
                  toolUseId: String? = nil,
                  input: ToolCallInput? = nil,
                  output: String? = nil)
    case thinking(id: String, text: String)
    /// Collapsible card showing a summary with expandable full text (used for AI profile/discovery)
    case discoveryCard(id: String, title: String, summary: String, fullText: String)
    /// Chat observer card — auto-accepted inline element, user can deny to rollback
    case observerCard(id: String, activityId: Int64, type: String, content: String, buttons: [ObserverCardButton], actedAction: String? = nil)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .toolCall(let id, _, _, _, _, _): return id
        case .thinking(let id, _): return id
        case .discoveryCard(let id, _, _, _): return id
        case .observerCard(let id, _, _, _, _, _): return id
        }
    }

    /// Human-friendly display name for a tool
    static func displayName(for toolName: String) -> String {
        // Strip MCP prefix (e.g., "mcp__fazm-tools__execute_sql" → "execute_sql")
        let cleanName: String
        if toolName.hasPrefix("mcp__") {
            cleanName = String(toolName.split(separator: "__").last ?? Substring(toolName))
        } else {
            cleanName = toolName
        }

        // Handle tool names with embedded details (e.g. "WebSearch: \"query\"")
        if cleanName.hasPrefix("WebSearch:") {
            let query = String(cleanName.dropFirst("WebSearch: ".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return query.isEmpty ? "Searching the web" : "Searching: \(query)"
        }
        if cleanName.hasPrefix("WebFetch:") {
            return "Fetching page"
        }

        switch cleanName {
        case "execute_sql": return "Querying database"
        case "Read": return "Reading file"
        case "Write": return "Writing file"
        case "Edit": return "Editing file"
        case "Bash": return "Running command"
        case "Grep": return "Searching code"
        case "Glob": return "Finding files"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Fetching page"
        default: return "Using \(cleanName)"
        }
    }

    /// Extracts a short summary from tool input for inline display
    static func toolInputSummary(for toolName: String, input: [String: Any]) -> ToolCallInput? {
        let cleanName: String
        if toolName.hasPrefix("mcp__") {
            cleanName = String(toolName.split(separator: "__").last ?? Substring(toolName))
        } else {
            cleanName = toolName
        }

        let summary: String?
        switch cleanName {
        case "Read":
            summary = Self.shortenPath(input["file_path"] as? String)
        case "Write", "Edit":
            summary = Self.shortenPath(input["file_path"] as? String)
        case "Bash", "Terminal":
            if let cmd = input["command"] as? String {
                summary = cmd.count > 80 ? String(cmd.prefix(80)) + "…" : cmd
            } else {
                summary = nil
            }
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = Self.shortenPath(input["path"] as? String)
            summary = path != nil ? "\"\(pattern)\" in \(path!)" : "\"\(pattern)\""
        case "Glob":
            summary = input["pattern"] as? String
        case "WebSearch":
            if let query = input["query"] as? String {
                summary = "\"\(query)\""
            } else {
                summary = nil
            }
        case "WebFetch":
            summary = input["url"] as? String
        case "execute_sql":
            if let query = input["query"] as? String {
                summary = query.count > 100 ? String(query.prefix(100)) + "…" : query
            } else {
                summary = nil
            }
        case "request_permission":
            summary = input["type"] as? String
        case "ask_followup":
            summary = input["question"] as? String
        default:
            // Try common key names, shorten paths
            if let filePath = input["file_path"] as? String {
                summary = Self.shortenPath(filePath)
            } else if let path = input["path"] as? String {
                summary = Self.shortenPath(path)
            } else if let query = input["query"] as? String {
                summary = query
            } else if let cmd = input["command"] as? String {
                summary = cmd.count > 80 ? String(cmd.prefix(80)) + "…" : cmd
            } else {
                summary = nil
            }
        }

        guard let summary = summary, !summary.isEmpty else { return nil }

        // Build full details JSON
        let details: String?
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            details = str
        } else {
            details = nil
        }

        return ToolCallInput(summary: summary, details: details)
    }

    /// Shorten a file path to just the filename (or last two components if useful)
    private static func shortenPath(_ path: String?) -> String? {
        guard let path = path, !path.isEmpty else { return nil }
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }
}

enum ToolCallStatus: Equatable {
    case running
    case completed
}

// MARK: - Chat Message Model

/// A file attached to a chat message (image, PDF, text file)
struct ChatAttachment: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let mimeType: String
    /// Thumbnail image data for display (JPEG, small)
    var thumbnailData: Data?

    init(id: String = UUID().uuidString, path: String, name: String, mimeType: String, thumbnailData: Data? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.mimeType = mimeType
        self.thumbnailData = thumbnailData
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isPDF: Bool { mimeType == "application/pdf" }

    /// Convert to the dict format expected by ACPBridge
    var bridgeDict: [String: String] {
        ["path": path, "name": name, "mimeType": mimeType]
    }
}

/// A single chat message
struct ChatMessage: Identifiable, Equatable {
    var id: String  // Mutable to sync with server-generated ID
    var text: String
    let createdAt: Date
    let sender: ChatSender
    var isStreaming: Bool
    /// Rating: 1 = thumbs up, -1 = thumbs down, nil = no rating
    var rating: Int?
    /// Whether the message has been synced with the backend (has valid server ID)
    var isSynced: Bool
    /// Citations extracted from the AI response
    var citations: [Citation]
    /// Structured content blocks for AI messages (text interspersed with tool calls)
    var contentBlocks: [ChatContentBlock]
    /// Which chat session this message belongs to (e.g. "floating", "detached-UUID")
    var sessionKey: String?
    /// Files attached by the user (images, PDFs, text files)
    var attachments: [ChatAttachment]

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.isStreaming == rhs.isStreaming
            && lhs.rating == rhs.rating
            && lhs.isSynced == rhs.isSynced
            && lhs.contentBlocks == rhs.contentBlocks
            && lhs.attachments == rhs.attachments
    }

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(), sender: ChatSender, isStreaming: Bool = false, rating: Int? = nil, isSynced: Bool = false, citations: [Citation] = [], contentBlocks: [ChatContentBlock] = [], sessionKey: String? = nil, attachments: [ChatAttachment] = []) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sender = sender
        self.isStreaming = isStreaming
        self.rating = rating
        self.isSynced = isSynced
        self.citations = citations
        self.contentBlocks = contentBlocks
        self.sessionKey = sessionKey
        self.attachments = attachments
    }
}

enum ChatSender: Equatable {
    case user
    case ai
}

extension ChatMessage {
    /// Convert a backend message to a local ChatMessage
    init(from db: ChatMessageDB) {
        self.init(
            id: db.id,
            text: db.text,
            createdAt: db.createdAt ?? Date(),
            sender: db.sender == "human" ? .user : .ai,
            isStreaming: false,
            rating: db.rating,
            isSynced: true
        )
    }
}

// MARK: - Citation Model

/// A citation referencing a source conversation or memory
struct Citation: Identifiable {
    let id: String
    let sourceType: CitationSourceType
    let title: String
    let preview: String
    let emoji: String?
    let createdAt: Date?

    enum CitationSourceType {
        case conversation
        case memory
    }
}

// MARK: - Chat Mode

/// Controls whether the AI agent can perform write actions (Act) or is restricted to read-only (Ask)
enum ChatMode: String, CaseIterable {
    case ask
    case act
}

/// State management for chat functionality with Claude Agent SDK
/// Uses hybrid architecture: Swift → Claude Agent (via Node.js bridge) for AI, Backend for persistence + context
@MainActor
class ChatProvider: ObservableObject {

    // MARK: - Floating Bar System Prompt Prefix
    /// Build the floating bar system prompt prefix based on compactness and proactiveness levels.
    static func floatingBarSystemPromptPrefix(compactness: ShortcutSettings.FloatingBarCompactness, proactiveness: ShortcutSettings.ProactivenessLevel) -> String {
        var lines: [String] = [
            "================================================================================",
            "🚨 FLOATING BAR MODE — READ THIS FIRST BEFORE ANYTHING ELSE 🚨",
            "================================================================================",
        ]
        switch compactness {
        case .off:
            break
        case .soft:
            lines.append("Be concise — prefer short answers (1-3 sentences) unless the question needs more detail. No unnecessary lists or headers.")
        case .strict:
            lines.append("Respond in exactly 1 sentence. No lists. No headers. No follow-up questions.")
        }
        switch proactiveness {
        case .passive:
            break
        case .balanced:
            lines.append("Take obvious actions that the user clearly needs. For ambiguous requests, ask for confirmation before proceeding. Use good judgment about when to act vs ask.")
        case .proactive:
            lines.append("Assume the user needs things done on their computer. Proactively find programmatic ways to accomplish tasks — use tools, scripts, and LLM-based approaches. Just work on the task and get it done without involving the user unless clarifications are truly needed. When starting a task, check what tools, libraries, or dependencies are needed and install them automatically (e.g. brew install, pip install, npm install) — don't fail or ask the user just because something isn't installed yet.")
        }
        lines.append("You have a `capture_screenshot` tool available. Use it when the user's query seems related to what's on their screen and visual context would help you answer. Never mention the screenshot to the user unless they explicitly ask about it.")
        lines.append("================================================================================")
        return lines.joined(separator: "\n")
    }

    /// Convenience property that reads the current compactness and proactiveness settings.
    static var floatingBarSystemPromptPrefixCurrent: String {
        floatingBarSystemPromptPrefix(compactness: ShortcutSettings.shared.floatingBarCompactness, proactiveness: ShortcutSettings.shared.proactivenessLevel)
    }

    // MARK: - Published State
    @Published var chatMode: ChatMode = .act
    @Published var draftText = ""
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var isSending = false
    /// Per-session send state. Enables concurrent queries across sessions
    /// (pop-out windows) while preserving the global `isSending` for legacy bindings.
    @Published private(set) var sendingSessionKeys: Set<String> = []
    @Published var isStopping = false
    /// Number of pending messages at the time the user clicked Stop.
    /// Messages enqueued after this point should still be drained on completion.
    private var pendingCountAtStop = 0
    /// When true, the bridge will be restarted after the current query completes
    /// (e.g., voice toggle changed mid-query).
    private var pendingBridgeRestart = false
    /// Incremented each time a new query starts (from any source: desktop, phone, etc.)
    @Published var queryStartedCount = 0
    @Published var isClearing = false

    /// When a mode switch is requested while a query is in-flight (`isSending`),
    /// the target mode is stored here and applied after the query completes.
    private var pendingBridgeModeSwitch: String?
    @Published var errorMessage: String?
    @Published var showCreditExhaustedAlert = false
    /// True while the agent is compacting conversation context
    @Published var isCompacting = false
    /// The session key of the currently compacting session (nil when not compacting)
    @Published var compactingSessionKey: String?

    // MARK: - Rate Limit State
    /// Latest rate limit status from Claude API ("allowed", "allowed_warning", "rejected")
    @Published var rateLimitStatus: String?
    /// Unix timestamp when the current rate limit resets
    @Published var rateLimitResetsAt: Double?
    /// Type of rate limit ("five_hour", "seven_day", etc.)
    @Published var rateLimitType: String?
    /// Current utilization (0-1) of the rate limit
    @Published var rateLimitUtilization: Double?

    /// Set to true during onboarding so the ACP session ID is persisted for restart recovery.
    var isOnboarding = false

    // MARK: - Floating Chat Session Persistence

    /// Per-mode UserDefaults key so sessions from one mode aren't mistakenly
    /// resumed by a different mode (builtin API key vs personal OAuth).
    private var floatingSessionIdKey: String { "floatingACPSessionId_\(bridgeMode)" }
    private var mainSessionIdKey: String { "mainACPSessionId_\(bridgeMode)" }
    /// Maximum number of messages to restore from local DB on startup
    private static let floatingRestoreLimit = 50
    /// UserDefaults key: when true, the user started a new chat and restore should be skipped
    private static let floatingChatClearedKey = "floatingChatWasCleared"

    /// Whether we've already restored floating chat messages this session
    private var floatingChatRestored = false
    /// Saved ACP session ID for resuming the floating chat after restart
    private var pendingFloatingResume: String?
    /// Conversation session ID for grouping messages within the chat_messages table.
    /// A new UUID is generated each time the user starts a new chat.
    private var floatingChatSessionId: String = UUID().uuidString
    @Published var sessionsLoadError: String?
    @Published var selectedAppId: String?
    @Published var hasMoreMessages = false
    @Published var isLoadingMoreMessages = false

    /// Triggered when a browser tool is called but the extension token isn't configured.
    /// The UI should observe this and present BrowserExtensionSetup.
    @Published var needsBrowserExtensionSetup = false

    /// The user's message text that was interrupted by browser extension setup.
    /// After setup completes, the UI should call retryPendingMessage() to re-send it.
    var pendingRetryMessage: String?

    /// Set when the agent is stopped due to browser extension setup.
    /// Prevents `sendMessage` from clearing `pendingRetryMessage` on completion.
    private var stoppedForBrowserSetup = false

    /// Working directory for Claude Agent SDK file-system tools (Read, Write, Bash, etc.)
    /// Working directory for Claude Agent SDK file-system tools (Read, Write, Bash, etc.).
    var workingDirectory: String?

    /// Override app ID for message routing (e.g. "task-chat" to isolate task messages).
    /// When set, messages are saved with this app_id so the backend routes them
    /// to the correct session instead of the default chat.
    var overrideAppId: String?

    /// Override the Claude model for this provider's queries.
    /// Reads the user's currently selected model from ShortcutSettings so all
    /// queries (main chat, follow-ups, retries) respect the user's model choice.
    var modelOverride: String? { ShortcutSettings.shared.selectedModel }

    /// Bridge mode: "personal" (user's Claude OAuth), "builtin" (bundled Anthropic API key)
    @AppStorage("bridgeMode") var bridgeMode: String = "builtin"

    // MARK: - Web Relay (phone → desktop tunnel)
    let webRelay = WebRelay()

    // MARK: - Bridge (prefers user's Claude session, falls back to bundled Anthropic API key)
    private lazy var acpBridge: ACPBridge = {
        return createBridge()
    }()
    private var acpBridgeStarted = false

    /// Whether the paywall should be shown (blocks AI response until subscription)
    @Published var showPaywall = false

    /// Whether the ACP bridge requires authentication (shown as sheet in UI)
    @Published var isClaudeAuthRequired = false
    @Published var claudeAuthTimedOut = false
    /// Whether the token exchange was rejected (e.g. 403 forbidden)
    @Published var claudeAuthFailed = false
    @Published var claudeAuthFailedReason: String?
    /// Cooldown: earliest time the user can retry after a 403 failure
    @Published var claudeAuthRetryCooldownEnd: Date?
    /// Auth methods returned by ACP bridge
    @Published var claudeAuthMethods: [[String: Any]] = []
    /// OAuth URL to open in browser (sent by bridge when auth is needed)
    @Published var claudeAuthUrl: String?
    /// When true, auto-open the next auth URL that arrives from the bridge
    /// (set when startClaudeAuth restarts the bridge because no URL was available)
    private var pendingAutoOpenAuth = false
    /// Whether the user has a cached Claude OAuth token
    @Published var isClaudeConnected = false
    /// Cumulative tokens used in the current session
    @Published var sessionTokensUsed: Int = 0

    // MARK: - Built-in API Key Usage Cap ($10)

    /// Maximum spend allowed on the built-in API key before auto-switching to personal mode
    static let builtinCostCapUsd: Double = 10.0

    /// Cumulative cost tracked locally (seeded from Firestore on startup)
    @AppStorage("builtinCumulativeCostUsd") var builtinCumulativeCostUsd: Double = 0.0

    private let messagesPageSize = 50
    private let maxMessagesInMemory = 200
    private var playwrightExtensionObserver: AnyCancellable?
    private var playwrightTokenObserver: AnyCancellable?
    private var voiceResponseObserver: AnyCancellable?

    // MARK: - Claude Session Detection

    // MARK: - Bridge Creation & Mode Switching

    /// Create an ACPBridge based on the current bridgeMode setting
    private func createBridge() -> ACPBridge {
        if bridgeMode == "builtin" {
            // Bundled API key mode: direct Anthropic API (fastest path)
            let apiKey = KeyService.shared.anthropicAPIKey ?? ""
            if !apiKey.isEmpty {
                log("ChatProvider: Using bundled Anthropic API key (direct API)")
                return ACPBridge(mode: .bundledKey(apiKey: apiKey))
            }
            log("ChatProvider: No bundled key available, falling back to personal OAuth")
            return ACPBridge(mode: .personalOAuth)
        } else {
            // Personal mode: always use OAuth
            log("ChatProvider: Using personal OAuth mode")
            return ACPBridge(mode: .personalOAuth)
        }
    }

    // MARK: - Rate Limit Handling

    /// Process rate limit events from the Claude API (forwarded via ACP bridge).
    /// Updates published state so the UI can show warnings or upgrade prompts.
    func handleRateLimitEvent(status: String, resetsAt: Double?, rateLimitType limitType: String?, utilization: Double?) {
        rateLimitStatus = status
        rateLimitResetsAt = resetsAt
        rateLimitType = limitType
        rateLimitUtilization = utilization

        let typeLabel = Self.rateLimitTypeLabel(limitType)

        switch status {
        case "allowed_warning":
            let pct = utilization.map { Int($0 * 100) } ?? 0
            log("ChatProvider: Rate limit warning — \(pct)% of \(typeLabel) used")
            AnalyticsManager.shared.rateLimitEvent(status: status, rateLimitType: limitType, utilization: utilization, resetsAt: resetsAt)
        case "rejected":
            let resetDesc = Self.formatResetTime(resetsAt)
            log("ChatProvider: Rate limit REJECTED — \(typeLabel), resets \(resetDesc)")
            AnalyticsManager.shared.rateLimitEvent(status: status, rateLimitType: limitType, utilization: utilization, resetsAt: resetsAt)
        default:
            // "allowed" — clear any previous warning
            break
        }
    }

    /// Human-readable label for rate limit types
    static func rateLimitTypeLabel(_ type: String?) -> String {
        switch type {
        case "five_hour": return "session limit"
        case "seven_day": return "weekly limit"
        case "seven_day_opus": return "Opus weekly limit"
        case "seven_day_sonnet": return "Sonnet weekly limit"
        case "overage": return "extra usage limit"
        default: return "usage limit"
        }
    }

    /// Format a Unix timestamp into a user-friendly reset time string
    static func formatResetTime(_ resetsAt: Double?) -> String {
        guard let resetsAt else { return "soon" }
        let resetDate = Date(timeIntervalSince1970: resetsAt)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = .current
        return formatter.string(from: resetDate)
    }

    /// Switch bridge mode, tearing down old bridge and setting up new one.
    /// If a query is in-flight (`isSending`), the switch is deferred until the query completes.
    func switchBridgeMode(to newMode: String) async {
        let oldMode = bridgeMode
        guard newMode != oldMode else {
            log("ChatProvider: switchBridgeMode(\(newMode)) — already in this mode, skipping restart")
            pendingBridgeModeSwitch = nil
            return
        }

        // Defer the switch if a query is in-flight — killing the bridge mid-query
        // causes the query to hang until the process-exit handler fires.
        if isSending {
            log("ChatProvider: deferring switchBridgeMode(\(newMode)) — query in progress")
            pendingBridgeModeSwitch = newMode
            return
        }

        pendingBridgeModeSwitch = nil
        log("ChatProvider: switching bridge mode to \(newMode) (current stored: \(oldMode))")

        // Track the mode switch in analytics
        AnalyticsManager.shared.chatBridgeModeChanged(from: oldMode, to: newMode)

        // Stop current bridge
        await acpBridge.stop()
        acpBridgeStarted = false

        bridgeMode = newMode
        acpBridge = createBridge()

        // Re-register global auth handlers
        setupBridgeAuthHandlers()

        // When switching to personal mode, start the bridge immediately so the
        // OAuth flow triggers right away instead of waiting for the first message.
        // If the user already has a valid Claude session (e.g. clicking back and forth),
        // this will just reconnect without showing the auth sheet.
        if newMode == "personal" {
            log("ChatProvider: Starting personal bridge eagerly")
            _ = await ensureBridgeStarted()

            // If the bridge started successfully with existing credentials (no auth_required
            // event fired), clear the credit exhaustion alert since the user can already use
            // their personal account without any further action.
            if !isClaudeAuthRequired {
                log("ChatProvider: Personal bridge started with existing creds, clearing credit exhaustion alert")
                showCreditExhaustedAlert = false
                isClaudeConnected = true
            }
        }
    }

    /// Apply a deferred bridge restart that was requested while a query was in-flight
    /// (e.g., voice toggle changed mid-query).
    private func applyPendingBridgeRestart() async {
        guard pendingBridgeRestart else { return }
        pendingBridgeRestart = false
        guard acpBridgeStarted else { return }
        log("ChatProvider: applying deferred bridge restart (voice setting changed mid-query)")
        await acpBridge.stop()
        acpBridgeStarted = false
    }

    /// Apply a deferred bridge mode switch that was requested while a query was in-flight.
    private func applyPendingBridgeModeSwitch() async {
        guard let pending = pendingBridgeModeSwitch else { return }
        pendingBridgeModeSwitch = nil
        log("ChatProvider: applying deferred bridge mode switch to \(pending)")
        await switchBridgeMode(to: pending)
    }

    private func setupBridgeAuthHandlers() {
        Task {
            await acpBridge.setGlobalAuthHandlers(
                onAuthRequired: { [weak self] methods, authUrl in
                    Task { @MainActor in
                        self?.isClaudeAuthRequired = true
                        self?.claudeAuthMethods = methods
                        self?.claudeAuthUrl = authUrl
                        if self?.pendingAutoOpenAuth == true, let url = authUrl {
                            self?.pendingAutoOpenAuth = false
                            log("ChatProvider: Auto-opening auth URL after bridge restart")
                            BrowserExtensionSetup.openURLInChrome(url)
                            self?.scheduleOAuthAutoReopen(url)
                        }
                    }
                },
                onAuthSuccess: { [weak self] in
                    Task { @MainActor in
                        self?.oauthAutoReopenTask?.cancel()
                        self?.isClaudeAuthRequired = false
                        self?.isClaudeConnected = true
                        // Retry any query that was interrupted by the auth flow
                        self?.retryPendingMessage()
                    }
                },
                onAuthTimeout: { [weak self] reason in
                    Task { @MainActor in
                        self?.claudeAuthTimedOut = true
                        log("ChatProvider: Auth timeout: \(reason)")
                    }
                },
                onAuthFailed: { [weak self] reason, httpStatus in
                    Task { @MainActor in
                        log("ChatProvider: Auth failed (HTTP \(httpStatus ?? 0)): \(reason)")
                        self?.claudeAuthFailed = true
                        self?.claudeAuthFailedReason = reason
                        self?.claudeAuthRetryCooldownEnd = Date().addingTimeInterval(30)
                    }
                }
            )
        }
    }

    // MARK: - Cross-Platform Message Polling
    /// Polls for new messages from other platforms (mobile) every 15 seconds.
    /// Polls every 15 seconds.
    private var messagePollTimer: AnyCancellable?
    private static let messagePollInterval: TimeInterval = 15.0

    // MARK: - Streaming Buffer
    /// Accumulates text deltas during streaming and flushes them to the published
    /// messages array at most once per ~100ms, reducing SwiftUI re-render frequency.
    private var streamingTextBuffer: String = ""
    private var streamingThinkingBuffer: String = ""
    private var streamingBufferMessageId: String?
    private var streamingFlushWorkItem: DispatchWorkItem?
    private let streamingFlushInterval: TimeInterval = 0.1
    /// When true, the next text buffer flush creates a new .text content block
    /// instead of appending to the existing one. Set by text_block_boundary events.
    private var forceNewTextBlock: Bool = false

    // MARK: - Cached Context for Prompts
    private var cachedAIProfile: String = ""
    private var aiProfileLoaded = false
    private var cachedDatabaseSchema: String = ""
    private var schemaLoaded = false
    /// System prompt built once at warmup and reused for every query.
    /// The ACP session is pre-warmed with this prompt via session/new.
    /// On subsequent queries the bridge reuses the same session, so the
    /// system prompt is ignored — it is only re-applied if the session is
    /// invalidated (e.g. cwd change) and a new session/new is triggered.
    /// Conversation history from before app launch IS included (via buildConversationHistory());
    /// after session/new the ACP SDK tracks ongoing history natively.
    private var cachedMainSystemPrompt: String = ""

    // MARK: - CLAUDE.md & Skills (Global)
    @Published var claudeMdContent: String?
    @Published var claudeMdPath: String?
    @Published var discoveredSkills: [(name: String, description: String, path: String)] = []
    @AppStorage("claudeMdEnabled") var claudeMdEnabled = true
    @AppStorage("disabledSkillsJSON") private var disabledSkillsJSON: String = ""

    // MARK: - Project-level CLAUDE.md & Skills
    @AppStorage("aiChatWorkingDirectory") var aiChatWorkingDirectory: String = ""
    @Published var projectClaudeMdContent: String?
    @Published var projectClaudeMdPath: String?
    @Published var projectDiscoveredSkills: [(name: String, description: String, path: String)] = []
    @AppStorage("projectClaudeMdEnabled") var projectClaudeMdEnabled = true

    // MARK: - Voice Response (TTS)
    @AppStorage("voiceResponseEnabled") var voiceResponseEnabled = true

    // MARK: - Dev Mode
    @AppStorage("devModeEnabled") var devModeEnabled = false
    private var devModeContext: String?

    // MARK: - Current Model
    var currentModel: String {
        "Claude"
    }

    // MARK: - System Prompt
    // Prompts are defined in ChatPrompts.swift (converted from Python backend)

    init() {
        log("ChatProvider initialized, will start Claude bridge on first use")

        // Check if user has an active Claude Code CLI session and auto-switch to personal mode.
        // The keychain check is async (runs in Task.detached), so we must trigger the mode
        // switch from within the completion — not from a synchronous read of isClaudeConnected.
        checkClaudeConnectionStatus(autoSwitchToPersonal: false)

        // Poll for new messages from other platforms (mobile) every 15 seconds
        messagePollTimer = Timer.publish(every: Self.messagePollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.pollForNewMessages()
                }
            }

        // Observe changes to Playwright extension mode setting — restart bridge to pick up new env vars
        playwrightExtensionObserver = UserDefaults.standard.publisher(for: \.playwrightUseExtension)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard !self.isSending else {
                        log("ChatProvider: Skipping bridge restart — query in progress")
                        return
                    }
                    guard self.acpBridgeStarted else { return }
                    log("ChatProvider: Playwright extension setting changed, restarting ACP bridge")
                    self.acpBridgeStarted = false
                    do {
                        try await self.acpBridge.restart()
                        self.acpBridgeStarted = true
                        log("ChatProvider: ACP bridge restarted with new Playwright settings")
                    } catch {
                        logError("Failed to restart ACP bridge after Playwright setting change", error: error)
                    }
                }
            }

        // Observe changes to Playwright extension token — restart bridge to pick up new token.
        // If the token changed because of browser extension setup (stoppedForBrowserSetup),
        // skip the restart — retryPendingQuery() will handle it with proper session resume.
        playwrightTokenObserver = UserDefaults.standard.publisher(for: \.playwrightExtensionToken)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard !self.isSending else {
                        log("ChatProvider: Skipping bridge restart for token change — query in progress")
                        return
                    }
                    if self.pendingRetryMessage != nil {
                        log("ChatProvider: Skipping bridge restart for token change — retry pending (will restart with session resume)")
                        return
                    }
                    guard self.acpBridgeStarted else { return }
                    log("ChatProvider: Playwright extension token changed, restarting ACP bridge")
                    self.acpBridgeStarted = false
                    do {
                        try await self.acpBridge.restart()
                        self.acpBridgeStarted = true
                        log("ChatProvider: ACP bridge restarted with new Playwright token")
                    } catch {
                        logError("Failed to restart ACP bridge after Playwright token change", error: error)
                    }
                }
            }

        // Observe changes to voice response setting — restart bridge so next query
        // uses the updated system prompt (with or without voice instructions).
        voiceResponseObserver = UserDefaults.standard.publisher(for: \.voiceResponseEnabled)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    // Clear saved floating session so the next bridge start creates a fresh
                    // session with the updated system prompt (voice instructions added/removed).
                    UserDefaults.standard.removeObject(forKey: self.floatingSessionIdKey)
                    guard self.acpBridgeStarted else { return }
                    // If a query is in-flight, defer the bridge restart until the query
                    // completes. Stopping mid-query kills the agent task (BridgeError.stopped).
                    if self.isSending {
                        log("ChatProvider: Voice response setting changed, deferring bridge restart (query in-flight)")
                        self.pendingBridgeRestart = true
                        return
                    }
                    log("ChatProvider: Voice response setting changed, stopping bridge (will restart on next query)")
                    await self.acpBridge.stop()
                    self.acpBridgeStarted = false
                }
            }

        // Start web relay for phone → desktop tunnel
        setupWebRelay()

        // Kill ACP bridge subprocess on app quit to prevent orphaned Node.js processes.
        // This runs synchronously (stop() is sync) to ensure cleanup completes before exit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.webRelay.stop()
                let bridge = self.acpBridge
                Task.detached { await bridge.stop() }
            }
        }
    }

    private var terminationObserver: NSObjectProtocol?

    // MARK: - Web Relay Setup

    private func setupWebRelay() {
        webRelay.onQuery = { [weak self] text, sessionKey in
            guard let self else { return }
            await self.sendMessage(text, sessionKey: sessionKey)
        }

        webRelay.onHistoryRequest = { [weak self] in
            guard let self else { return [] }
            return self.messages.map { msg in
                [
                    "id": msg.id,
                    "text": msg.text,
                    "sender": msg.sender == .user ? "user" : "ai",
                ] as [String: Any]
            }
        }

        // Start web relay — findNode() calls NodeBinaryHelper which does blocking I/O,
        // but that's moved off the main thread inside WebRelay.start() (FAZM-9W fix).
        Task { @MainActor in
            webRelay.start()
        }
    }

    /// Pre-start the active bridge so the first query doesn't wait for process launch
    func warmupBridge() async {
        _ = await ensureBridgeStarted()
    }

    /// Test that the Playwright Chrome extension is connected and working.
    /// Stops the bridge and restarts via `ensureBridgeStarted()` which does a full
    /// warmup with session resume, preserving conversation history across the setup flow.
    /// Retries up to 3 times with a short delay to allow the Playwright MCP server
    /// to establish its WebSocket connection to the Chrome extension after startup.
    func testPlaywrightConnection() async throws -> Bool {
        // If a query is in progress, skip the bridge restart — it would kill the
        // in-flight query. The token is already saved in UserDefaults and will be
        // picked up on the next bridge restart.
        guard !isSending else {
            log("ChatProvider: Skipping Playwright connection test — query in progress, token saved for next restart")
            AnalyticsManager.shared.browserExtensionConnectionTested(success: true, skipped: true)
            return true
        }
        // Stop bridge so ensureBridgeStarted() restarts with new token + session resume.
        // ensureBridgeStarted() reads the saved session ID from UserDefaults and passes
        // it to warmup, preserving conversation history across the setup flow.
        await acpBridge.stop()
        acpBridgeStarted = false
        guard await ensureBridgeStarted() else {
            throw NSError(domain: "ChatProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to restart bridge for Playwright test"])
        }
        // Retry with backoff: the Playwright MCP server may need a moment to connect
        // to the Chrome extension via WebSocket after the bridge starts.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let connected = try await acpBridge.testPlaywrightConnection()
                if connected {
                    log("ChatProvider: Playwright connection test succeeded on attempt \(attempt)")
                    return true
                }
            } catch {
                log("ChatProvider: Playwright connection test attempt \(attempt) error: \(error)")
                if attempt == maxAttempts { throw error }
            }
            if attempt < maxAttempts {
                let delay = Double(attempt) * 2.0
                log("ChatProvider: Retrying Playwright connection test in \(delay)s (attempt \(attempt)/\(maxAttempts))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return false
    }

    /// Ensure the ACP bridge is started (restarts if the process died)
    private func ensureBridgeStarted() async -> Bool {
        if acpBridgeStarted {
            let alive = await acpBridge.isAlive
            if !alive {
                log("ChatProvider: ACP bridge process died, will restart")
                acpBridgeStarted = false
            }
        }

        // Even if bridge is running, check if it started in the wrong mode.
        // This happens when keys weren't available at first launch (cold start timeout,
        // missing env vars) and the bridge fell back to personalOAuth.
        if acpBridgeStarted && bridgeMode == "builtin" && acpBridge.mode.isPersonalOAuth {
            await KeyService.shared.ensureKeys()
            if let key = KeyService.shared.anthropicAPIKey, !key.isEmpty {
                log("ChatProvider: API key now available — restarting bridge in bundledKey mode (was personalOAuth fallback)")
                await acpBridge.stop()
                acpBridge = createBridge()
                acpBridgeStarted = false
            }
        }

        guard !acpBridgeStarted else { return true }

        // Ensure API keys are fetched before checking availability
        await KeyService.shared.ensureKeys()

        do {
            try await acpBridge.start()
            acpBridgeStarted = true
            log("ChatProvider: ACP bridge started successfully")
            // Set up global auth handlers so auth_required during warmup is handled
            await acpBridge.setGlobalAuthHandlers(
                onAuthRequired: { [weak self] methods, authUrl in
                    Task { @MainActor [weak self] in
                        self?.claudeAuthMethods = methods
                        self?.claudeAuthUrl = authUrl
                        self?.isClaudeAuthRequired = true
                        if self?.pendingAutoOpenAuth == true, let url = authUrl {
                            self?.pendingAutoOpenAuth = false
                            log("ChatProvider: Auto-opening auth URL after bridge restart")
                            BrowserExtensionSetup.openURLInChrome(url)
                            self?.scheduleOAuthAutoReopen(url)
                        }
                    }
                },
                onAuthSuccess: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.oauthAutoReopenTask?.cancel()
                        self?.isClaudeAuthRequired = false
                        self?.claudeAuthTimedOut = false
                        self?.claudeAuthFailed = false
                        self?.claudeAuthFailedReason = nil
                        self?.claudeAuthRetryCooldownEnd = nil
                        self?.isClaudeConnected = true
                        // Retry any query that was interrupted by the auth flow
                        self?.retryPendingMessage()
                    }
                },
                onAuthTimeout: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        log("ChatProvider: Claude OAuth timed out: \(reason)")
                        self?.claudeAuthTimedOut = true
                    }
                },
                onAuthFailed: { [weak self] reason, httpStatus in
                    Task { @MainActor [weak self] in
                        log("ChatProvider: Claude OAuth failed (HTTP \(httpStatus ?? 0)): \(reason)")
                        self?.claudeAuthFailed = true
                        self?.claudeAuthFailedReason = reason
                        self?.claudeAuthRetryCooldownEnd = Date().addingTimeInterval(30)
                    }
                }
            )
            // Set up chat observer poll handler — when the chat observer finishes a batch,
            // poll observer_activity for new pending cards, auto-accept them, and inject into chat
            await acpBridge.setChatObserverPollHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.pollChatObserverCards()
                }
            }
            await acpBridge.setChatObserverStatusHandler { running in
                Task { @MainActor in
                    FloatingControlBarManager.shared.barState?.isChatObserverRunning = running
                }
            }
            // Set up background tool call handler for observer session tool calls
            // (execute_sql, etc.) that arrive when no main query is active
            await acpBridge.setBackgroundToolCallHandler { callId, name, input in
                let toolCall = ToolCall(name: name, arguments: input, thoughtSignature: nil)
                let result = await ChatToolExecutor.execute(toolCall)
                log("Background tool \(name) executed for callId=\(callId)")
                return result
            }
            // Restore floating chat messages from SQLite BEFORE building the system prompt.
            // This ensures buildConversationHistory() has access to prior messages, so if
            // ACP session resume fails, the fallback new session gets seeded with context.
            // Without this, messages is empty at warmup time and the user loses all history.
            await restoreFloatingChatIfNeeded()

            // Pre-warm ACP sessions with their respective system prompts.
            // This is the only place the system prompt is built and applied.
            let mainSystemPrompt = buildSystemPrompt(contextString: "")
            cachedMainSystemPrompt = mainSystemPrompt
            let floatingSystemPrompt = Self.floatingBarSystemPromptPrefixCurrent + "\n\n" + mainSystemPrompt
            let savedFloatingSessionId = UserDefaults.standard.string(forKey: floatingSessionIdKey)
            let savedMainSessionId = UserDefaults.standard.string(forKey: mainSessionIdKey)
            let chatObserverUserName = AuthService.shared.displayName.isEmpty ? "the user" : AuthService.shared.givenName
            let chatObserverSystemPrompt = ChatPromptBuilder.buildChatObserverSession(
                userName: chatObserverUserName,
                databaseSchema: cachedDatabaseSchema
            )
            await acpBridge.warmupSession(cwd: workingDirectory, sessions: [
                .init(key: "main", model: "claude-sonnet-4-6", systemPrompt: mainSystemPrompt, resume: savedMainSessionId),
                .init(key: "floating", model: "claude-sonnet-4-6", systemPrompt: floatingSystemPrompt, resume: savedFloatingSessionId),
                .init(key: "observer", model: "claude-sonnet-4-6", systemPrompt: chatObserverSystemPrompt)
            ])
            // Resume is now handled at warmup — clear pendingFloatingResume so query() doesn't try again
            pendingFloatingResume = nil

            // Track if the bundled node binary was broken (Sparkle update corruption)
            if NodeBinaryHelper.bundledNodeWasBroken {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let hadSparkle = UserDefaults.standard.bool(forKey: "hasSuccessfullyInstalledSparkleUpdate")
                let installMethod = hadSparkle ? "sparkle" : "other"
                log("ChatProvider: ⚠️ Bundled node binary was corrupted, recovered via temp copy (install=\(installMethod))")
                AnalyticsManager.shared.nodeBinaryCorrupted(version: version, installMethod: installMethod)
            }

            return true
        } catch {
            logError("Failed to start ACP bridge", error: error)
            errorMessage = "AI not available: \(error.localizedDescription)"
            return false
        }
    }

    /// Reset a named ACP session so the next query starts fresh (no history).
    /// Messages are kept in the DB for history — only the in-memory and ACP state is cleared.
    func resetSession(key: String) async {
        await acpBridge.resetSession(key: key)
        if key == "main" {
            UserDefaults.standard.removeObject(forKey: mainSessionIdKey)
        }
        if key == "floating" {
            UserDefaults.standard.removeObject(forKey: floatingSessionIdKey)
            UserDefaults.standard.set(true, forKey: Self.floatingChatClearedKey)
            pendingFloatingResume = nil
            // Only remove floating-session messages; preserve detached-session messages
            // so in-flight queries in popped-out windows aren't destroyed.
            messages.removeAll { ($0.sessionKey ?? "floating") == "floating" }
            pendingMessages.removeAll { ($0.sessionKey ?? "floating") == "floating" }
            floatingChatSessionId = UUID().uuidString
        }
    }

    /// Transfer the ACP session from one key to another without resetting it.
    /// Used when popping out the floating bar conversation to a detached window —
    /// the detached window continues the same ACP session under a new key,
    /// while the floating bar's key is cleared so the next query starts fresh.
    func transferSession(fromKey: String, toKey: String) {
        // Move the saved ACP session ID to the new key
        let sessionIdKey = "acpSessionId_\(toKey)_\(bridgeMode)"
        if fromKey == "floating" {
            if let savedId = UserDefaults.standard.string(forKey: floatingSessionIdKey) {
                UserDefaults.standard.set(savedId, forKey: sessionIdKey)
                log("ChatProvider: Transferred session ID \(savedId) from '\(fromKey)' to '\(toKey)'")
            } else if let pendingId = pendingFloatingResume {
                UserDefaults.standard.set(pendingId, forKey: sessionIdKey)
                log("ChatProvider: Transferred pending resume ID \(pendingId) from '\(fromKey)' to '\(toKey)'")
            }
            // Clear the floating key so next floating query starts fresh
            UserDefaults.standard.removeObject(forKey: floatingSessionIdKey)
            UserDefaults.standard.set(true, forKey: Self.floatingChatClearedKey)
            pendingFloatingResume = nil
            // Re-key existing messages so the detached window's subscriber can find them.
            // The subscriber filters by sessionKey == toKey; without this, in-flight
            // streaming messages still carry "floating" and the detached window never
            // picks up the completion, leaving a stuck loading spinner.
            for i in messages.indices where messages[i].sessionKey == fromKey {
                messages[i].sessionKey = toKey
            }
            // Don't clear messages here — an in-flight query may still be streaming
            // into the last AI message. The detached window's subscriber needs it alive.
            // Messages are cleared lazily: either when the detached window's subscriber
            // calls clearFloatingMessages() after the query finishes, or when the
            // floating bar starts a new chat (resetSession).
            pendingMessages.removeAll { ($0.sessionKey ?? "floating") == "floating" }
            floatingChatSessionId = UUID().uuidString

            // Re-key the bridge's in-memory session from "floating" to the detached key
            // so the detached window's first query finds it instantly (no resume needed).
            // Then reset "floating" so the next floating bar query starts fresh.
            let bridge = acpBridge
            Task {
                await bridge.transferSession(fromKey: "floating", toKey: toKey)
                await bridge.resetSession(key: "floating")
            }
        }
    }

    /// Whether the floating chat was cleared (e.g. by pop-out or explicit new chat)
    /// and is awaiting a fresh start on the next floating bar interaction. The caller
    /// is expected to skip any restore/populate-from-messages logic when this is true.
    /// The flag is consumed by `clearTransferredMessages()` once the detached window's
    /// in-flight query finishes streaming, so we only read it here (don't clear).
    var floatingChatWasCleared: Bool {
        UserDefaults.standard.bool(forKey: Self.floatingChatClearedKey)
    }

    /// Clear messages that were kept alive during a floating→detached session transfer.
    /// Called by the detached window's subscriber once the in-flight query finishes streaming.
    func clearTransferredMessages() {
        // Only clear if the floating bar cleared flag is set (meaning a transfer happened).
        // Clear the flag immediately so this only fires once per pop-out. Without this,
        // every subsequent query completion in the detached window would wipe the messages
        // array, causing responses to vanish ("Chat response arrived after session switch").
        guard UserDefaults.standard.bool(forKey: Self.floatingChatClearedKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.floatingChatClearedKey)
        // Only remove floating-session messages; preserve active detached-session messages.
        messages.removeAll { ($0.sessionKey ?? "floating") == "floating" }
    }

    /// Get the saved ACP session ID for a detached session key, consuming it for resume.
    func detachedSessionResumeId(for key: String) -> String? {
        let sessionIdKey = "acpSessionId_\(key)_\(bridgeMode)"
        let id = UserDefaults.standard.string(forKey: sessionIdKey)
        return id
    }

    /// Start Claude OAuth authentication
    /// Opens the OAuth URL (provided by the bridge) in Chrome (where the user's sessions live).
    /// The bridge handles the full OAuth flow: local callback server, token exchange,
    /// credential storage, and ACP subprocess restart.
    func startClaudeAuth() {
        if let urlString = claudeAuthUrl, URL(string: urlString) != nil {
            log("ChatProvider: Opening Claude OAuth URL in Chrome: \(urlString.prefix(200))")
            BrowserExtensionSetup.openURLInChrome(urlString)
            scheduleOAuthAutoReopen(urlString)
        } else {
            // No auth URL yet — restart the bridge to trigger a fresh OAuth flow.
            // This happens when isClaudeAuthRequired was set by error-handling paths
            // (credit exhaustion, auth errors) without an active OAuth flow.
            log("ChatProvider: No auth URL available, restarting bridge to trigger OAuth")
            pendingAutoOpenAuth = true
            Task {
                acpBridgeStarted = false
                await acpBridge.stop()
                _ = await ensureBridgeStarted()
                // After restart, the bridge will fire auth_required with a URL.
                // The pendingAutoOpenAuth flag tells the auth handler to auto-open it.
            }
        }
    }

    /// Previously auto-reopened the OAuth URL after a delay, but this caused more
    /// harm than good — it would fire during login (user hadn't finished signing in)
    /// or after auth completed (before Swift received auth_success). The "Open Sign-in
    /// Again" button in ClaudeAuthSheet is the better UX for handling first-attempt failures.
    private var oauthAutoReopenTask: Task<Void, Never>?

    private func scheduleOAuthAutoReopen(_ urlString: String) {
        // No-op: auto-reopen removed. Users can click "Open Sign-in Again" if needed.
    }

    /// Navigate Chrome's active tab to a URL (instead of opening a new tab).
    /// Falls back to opening a new tab if AppleScript fails.
    private static func navigateChromeActiveTab(to urlString: String) {
        let script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set URL of active tab of front window to "\(urlString)"
            else
                make new window
                set URL of active tab of front window to "\(urlString)"
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            BrowserExtensionSetup.openURLInChrome(urlString)
            return
        }
        // NSAppleScript is not Sendable but is safe here — created on main, used exclusively on the background queue.
        nonisolated(unsafe) let unsafeScript = appleScript
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            unsafeScript.executeAndReturnError(&error)
            if error != nil {
                DispatchQueue.main.async {
                    BrowserExtensionSetup.openURLInChrome(urlString)
                }
            }
        }
    }

    /// Cancel the active Claude OAuth flow so the next attempt starts fresh
    func cancelClaudeAuth() {
        log("ChatProvider: Cancelling Claude OAuth")
        oauthAutoReopenTask?.cancel()
        isClaudeAuthRequired = false
        claudeAuthUrl = nil
        pendingAutoOpenAuth = false
        Task {
            await acpBridge.cancelAuth()
        }
    }

    /// Retry Claude OAuth after a timeout by restarting the ACP bridge
    func retryClaudeAuth() {
        log("ChatProvider: Retrying Claude OAuth")
        claudeAuthTimedOut = false
        claudeAuthFailed = false
        claudeAuthFailedReason = nil
        claudeAuthRetryCooldownEnd = nil
        isClaudeAuthRequired = false
        acpBridgeStarted = false
        Task {
            // Restart bridge — this triggers a new OAuth flow
            await acpBridge.stop()
            _ = await ensureBridgeStarted()
        }
    }

    /// Check whether the user has Claude OAuth credentials stored in the macOS Keychain.
    /// Our OAuth flow stores tokens under the "Claude Code-credentials" service name.
    ///
    /// - Parameter autoSwitchToPersonal: When true (used at init), automatically switches
    ///   to personal mode if credentials are found and we're not already in personal mode.
    func checkClaudeConnectionStatus(autoSwitchToPersonal: Bool = false) {
        Task.detached { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let hasCredentials = proc.terminationStatus == 0
                log("ChatProvider: Keychain Claude credentials → \(hasCredentials ? "found" : "not found")")
                let capturedSelf = self
                await MainActor.run {
                    guard let capturedSelf else { return }
                    capturedSelf.isClaudeConnected = hasCredentials
                    if hasCredentials && !UserDefaults.standard.bool(forKey: "didReportClaudeCliCredentials") {
                        UserDefaults.standard.set(true, forKey: "didReportClaudeCliCredentials")
                        AnalyticsManager.shared.claudeCliCredentialsDetected()
                        log("ChatProvider: Reported claude_cli_credentials_detected (one-time)")
                    }
                    if autoSwitchToPersonal && hasCredentials && capturedSelf.bridgeMode != "personal" {
                        log("ChatProvider: Active Claude CLI session detected, auto-switching to personal mode")
                        Task { await capturedSelf.switchBridgeMode(to: "personal") }
                    }
                }
            } catch {
                logError("ChatProvider: Failed to check Keychain for Claude credentials", error: error)
                let capturedSelf = self
                await MainActor.run { capturedSelf?.isClaudeConnected = false }
            }
        }
    }

    /// Disconnect from Claude: stop bridge, clear OAuth token, switch back to free mode
    func disconnectClaude() async {
        log("ChatProvider: Disconnecting Claude account")

        // 1. Stop the ACP bridge
        await acpBridge.stop()
        acpBridgeStarted = false

        // 2. Clear the OAuth token from config file
        let configPath = NSString(string: "~/Library/Application Support/Claude/config.json").expandingTildeInPath
        if let data = FileManager.default.contents(atPath: configPath),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json.removeValue(forKey: "oauth:tokenCache")
            if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? updatedData.write(to: URL(fileURLWithPath: configPath))
            }
        }

        // 3. Clear OAuth credentials from macOS Keychain
        //    The Keychain item is owned by Claude Desktop/CLI, so SecItemDelete fails
        //    with errSecInvalidOwnerEdit. Use the `security` CLI which runs as the user.
        let secProcess = Process()
        secProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        secProcess.arguments = ["delete-generic-password", "-s", "Claude Code-credentials"]
        secProcess.standardOutput = FileHandle.nullDevice
        secProcess.standardError = FileHandle.nullDevice
        do {
            try secProcess.run()
            secProcess.waitUntilExit()
            if secProcess.terminationStatus == 0 {
                log("ChatProvider: Cleared Claude Code credentials from Keychain")
            } else {
                log("ChatProvider: No Claude Code credentials found in Keychain (status=\(secProcess.terminationStatus))")
            }
        } catch {
            log("ChatProvider: Failed to run security command: \(error.localizedDescription)")
        }

        // 4. Update state
        isClaudeConnected = false

        // 5. Switch back to builtin mode and recreate bridge
        AnalyticsManager.shared.claudeDisconnected()
        await switchBridgeMode(to: "builtin")
        log("ChatProvider: Claude account disconnected, switched to builtin mode")
    }

    /// Check if an error message from the ACP bridge indicates an auth/OAuth failure.
    ///
    /// The bridge handles auth internally (OAuth flow + retries). It only emits a plain
    /// `error` message with auth content when it exhausts retries, producing the specific
    /// string: "Authentication required. Please disconnect and reconnect your Claude account..."
    /// We match that precisely to avoid false positives from unrelated errors that happen
    /// to contain broad substrings like "auth" or "login".
    static func isAuthRelatedError(_ message: String) -> Bool {
        let lower = message.lowercased()
        // Exact phrase the bridge emits after exhausting auth retries
        if lower.contains("authentication required") { return true }
        // HTTP 401 surfaced directly as an agentError (shouldn't happen but guard it)
        if lower.contains("401") && (lower.contains("unauthorized") || lower.contains("unauthenticated")) { return true }
        return false
    }

    /// Check if an error indicates the user's personal account cannot access the requested model.
    /// This happens when CLI credentials exist but the account/plan doesn't support the model.
    static func isModelAccessError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("may not exist") && lower.contains("not have access") { return true }
        if lower.contains("model") && lower.contains("not found") { return true }
        if lower.contains("model") && lower.contains("not available") { return true }
        return false
    }

    /// Check if an error indicates Anthropic updated their Terms of Service and the user
    /// hasn't accepted them yet. These are 400 invalid_request_error responses that contain
    /// actionable instructions (go to claude.ai and accept). We surface them verbatim
    /// rather than triggering a re-auth flow, since re-authing won't fix it.
    static func isTermsAcceptanceRequired(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("consumer terms") { return true }
        if lower.contains("terms of service") && lower.contains("accept") { return true }
        if lower.contains("terms and privacy") { return true }
        if lower.contains("updated our") && lower.contains("policy") { return true }
        return false
    }

    // MARK: - Load Context

    // MARK: - Load AI User Profile

    /// Fetches the latest AI-generated user profile from local database
    private func loadAIProfileIfNeeded() async {
        guard !aiProfileLoaded else { return }

        if let profile = await AIUserProfileService.shared.getLatestProfile() {
            cachedAIProfile = profile.profileText
            log("ChatProvider loaded AI profile (generated \(profile.generatedAt))")
        }
        aiProfileLoaded = true
    }

    /// Formats AI profile into a prompt section
    private func formatAIProfileSection() -> String {
        guard !cachedAIProfile.isEmpty else { return "" }
        return "\n<ai_user_profile>\n\(cachedAIProfile)\n</ai_user_profile>"
    }

    // MARK: - Load Database Schema

    /// Queries sqlite_master to build an up-to-date schema description for the prompt
    private func loadSchemaIfNeeded() async {
        guard !schemaLoaded else { return }

        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
            log("ChatProvider: database not available for schema introspection")
            schemaLoaded = true
            return
        }

        do {
            let tables = try await dbQueue.read { db -> [(name: String, sql: String)] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT name, sql FROM sqlite_master
                    WHERE type='table' AND sql IS NOT NULL
                    ORDER BY name
                """)
                return rows.compactMap { row -> (name: String, sql: String)? in
                    guard let name: String = row["name"],
                          let sql: String = row["sql"] else { return nil }
                    return (name: name, sql: sql)
                }
            }

            cachedDatabaseSchema = formatSchema(tables: tables)
            schemaLoaded = true
            log("ChatProvider loaded schema for \(tables.count) tables")
        } catch {
            logError("Failed to load database schema", error: error)
            schemaLoaded = true
        }
    }

    /// Formats raw DDL into a compact, LLM-friendly schema block
    private func formatSchema(tables: [(name: String, sql: String)]) -> String {
        var lines: [String] = ["**Database schema (fazm.db):**", ""]

        for (name, sql) in tables {
            // Skip internal/FTS tables
            if ChatPrompts.excludedTables.contains(name) { continue }
            if ChatPrompts.excludedTablePrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            if name.contains("_fts") { continue } // catches all FTS virtual + internal tables

            // Extract column names only, stripping types, constraints, and infrastructure columns
            let columnNames = extractColumns(from: sql).compactMap { col -> String? in
                let name = col.components(separatedBy: .whitespaces).first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) ?? ""
                return ChatPrompts.excludedColumns.contains(name) ? nil : name
            }.filter { !$0.isEmpty }
            guard !columnNames.isEmpty else { continue }

            // Table header with annotation
            let annotation = ChatPrompts.tableAnnotations[name] ?? ""
            let header = annotation.isEmpty ? name : "\(name) — \(annotation)"
            lines.append(header)

            // Column names as compact one-liner
            lines.append("  \(columnNames.joined(separator: ", "))")
            lines.append("")
        }

        // Append FTS table note
        lines.append(ChatPrompts.schemaFooter)

        return lines.joined(separator: "\n")
    }

    /// Extracts column definitions from a CREATE TABLE SQL statement
    /// Produces compact representations like: "id INTEGER PRIMARY KEY", "name TEXT NOT NULL"
    private func extractColumns(from sql: String) -> [String] {
        // Find content between first ( and last )
        guard let openParen = sql.firstIndex(of: "("),
              let closeParen = sql.lastIndex(of: ")") else { return [] }

        let body = String(sql[sql.index(after: openParen)..<closeParen])

        // Split by commas, but respect parentheses (for REFERENCES(...) etc.)
        var columns: [String] = []
        var current = ""
        var depth = 0
        for char in body {
            if char == "(" { depth += 1 }
            else if char == ")" { depth -= 1 }

            if char == "," && depth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { columns.append(trimmed) }
                current = ""
            } else {
                current.append(char)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { columns.append(trimmed) }

        // Filter out table constraints (UNIQUE, CHECK, FOREIGN KEY, etc.) — keep only column defs
        return columns.filter { col in
            let upper = col.uppercased().trimmingCharacters(in: .whitespaces)
            return !upper.hasPrefix("UNIQUE") && !upper.hasPrefix("CHECK") &&
                   !upper.hasPrefix("FOREIGN") && !upper.hasPrefix("CONSTRAINT") &&
                   !upper.hasPrefix("PRIMARY KEY")
        }.map { col in
            // Normalize whitespace
            col.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    // MARK: - Build System Prompt with Variables

    /// Builds the system prompt for ACP session initialization.
    /// Called once at warmup (via ensureBridgeStarted) and cached in cachedMainSystemPrompt.
    /// Conversation history is injected here so the brand-new ACP session starts with context
    /// from before the app launch. After session/new the ACP SDK owns history natively.
    private func buildSystemPrompt(contextString: String) -> String {
        // Get user name from AuthService
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName

        let aiProfileSection = formatAIProfileSection()

        var prompt = ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            aiProfileSection: aiProfileSection,
            databaseSchema: cachedDatabaseSchema
        )

        // Inject conversation history so the new ACP session has context from before app launch.
        // The ACP SDK maintains history natively after this via session/prompt — this only matters
        // at session creation time.
        let history = buildConversationHistory()
        if !history.isEmpty {
            prompt += "\n\n<conversation_history>\nBelow is recent conversation history. The user can see these messages and expects you to be aware of them. For older conversations, query chat_messages with execute_sql.\n\(history)\n</conversation_history>"
        }

        // Append global CLAUDE.md instructions if enabled
        if claudeMdEnabled, let claudeMd = claudeMdContent {
            prompt += "\n\n<claude_md>\n\(claudeMd)\n</claude_md>"
        }

        // Append project CLAUDE.md instructions if enabled
        if projectClaudeMdEnabled, let projectClaudeMd = projectClaudeMdContent {
            prompt += "\n\n<project_claude_md>\n\(projectClaudeMd)\n</project_claude_md>"
        }

        // Append enabled skills as available context (global + project)
        // dev-mode is included in the list when devModeEnabled; full content loaded on demand via Skill tool
        let enabledSkillNames = getEnabledSkillNames()
        if !enabledSkillNames.isEmpty {
            let allSkills = discoveredSkills + projectDiscoveredSkills
            let skillNames = allSkills
                .filter { enabledSkillNames.contains($0.name) && ($0.name != "dev-mode" || devModeEnabled) }
                .map { $0.name }
                .joined(separator: ", ")
            if !skillNames.isEmpty {
                prompt += "\n\n<available_skills>\nAvailable skills: \(skillNames)\nUse the Skill tool to load full instructions for any skill before using it.\n</available_skills>"
            }
        }

        // Append current app settings so the AI can read and change them
        let currentLang = AssistantSettings.shared.transcriptionLanguage
        let autoDetect = AssistantSettings.shared.transcriptionAutoDetect
        let voiceOn = voiceResponseEnabled
        prompt += "\n\n<app_settings>\nTranscription language: \(currentLang) (auto-detect: \(autoDetect ? "on" : "off"))\nVoice response (TTS): \(voiceOn ? "enabled" : "disabled")\nTo change these, use `set_user_preferences` with language and/or voice parameters.\n</app_settings>"

        // Append voice response instructions if enabled
        if voiceResponseEnabled {
            prompt += "\n\n<voice_response>\nVoice response is enabled. On EVERY final response, you MUST call the speak_response tool with a short, natural spoken summary of your answer (1-3 sentences). This plays audio to the user through their speakers. Keep the spoken text conversational and concise — it complements your written response, not replaces it. Call speak_response BEFORE writing your final text response.\n\nIMPORTANT: Only use speak_response when the conversation is in a supported language: English, Spanish, French, German, Italian, Dutch, or Japanese. If the user is chatting in any other language (e.g. Russian, Chinese, Korean, Portuguese, Arabic), do NOT call speak_response — just provide the text response without voice. The TTS engine only supports these 7 languages.\n</voice_response>"
        }

        // Log prompt context summary
        let historyInjected = !history.isEmpty
        let historyMessages = messages.filter { !$0.text.isEmpty && !$0.isStreaming }
        let historyCount = min(historyMessages.count, 20)
        log("ChatProvider: prompt built — schema: \(!cachedDatabaseSchema.isEmpty ? "yes" : "no"), ai_profile: \(!cachedAIProfile.isEmpty ? "yes" : "no"), history: \(historyInjected ? "injected (\(historyCount) msgs)" : "none"), claude_md: \(claudeMdEnabled && claudeMdContent != nil ? "yes" : "no"), project_claude_md: \(projectClaudeMdEnabled && projectClaudeMdContent != nil ? "yes" : "no"), skills: \(enabledSkillNames.count), dev_mode_in_skills: \(devModeEnabled && devModeContext != nil ? "yes" : "no"), prompt_length: \(prompt.count) chars")

        // Log per-section character breakdown
        let baseTemplate = ChatPromptBuilder.buildDesktopChat(
            userName: userName, aiProfileSection: "", databaseSchema: "")
        let allSkillsForSize = (discoveredSkills + projectDiscoveredSkills)
            .filter { enabledSkillNames.contains($0.name) && ($0.name != "dev-mode" || devModeEnabled) }
            .map { $0.name }.joined(separator: ", ")
        let skillsSectionSize = allSkillsForSize.isEmpty ? 0 : allSkillsForSize.count + 80 // names + wrapper
        log("ChatProvider: prompt breakdown — " +
            "base_template:\(baseTemplate.count)c, " +
            "ai_profile:\(aiProfileSection.count)c, " +
            "schema:\(cachedDatabaseSchema.count)c, " +
            "history:\(history.count)c, " +
            "claude_md:\(claudeMdContent?.count ?? 0)c, " +
            "project_claude_md:\(projectClaudeMdContent?.count ?? 0)c, " +
            "skills:\(skillsSectionSize)c")

        return prompt
    }

    /// Build system prompt for task chat sessions.
    func buildTaskChatSystemPrompt() -> String {
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName
        let aiProfileSection = formatAIProfileSection()

        var prompt = ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            aiProfileSection: aiProfileSection,
            databaseSchema: cachedDatabaseSchema
        )

        // NO conversation_history — SDK handles this via resume

        if claudeMdEnabled, let claudeMd = claudeMdContent {
            prompt += "\n\n<claude_md>\n\(claudeMd)\n</claude_md>"
        }
        if projectClaudeMdEnabled, let projectClaudeMd = projectClaudeMdContent {
            prompt += "\n\n<project_claude_md>\n\(projectClaudeMd)\n</project_claude_md>"
        }

        let enabledSkillNames = getEnabledSkillNames()
        if !enabledSkillNames.isEmpty {
            let allSkills = discoveredSkills + projectDiscoveredSkills
            let skillNames = allSkills
                .filter { enabledSkillNames.contains($0.name) && ($0.name != "dev-mode" || devModeEnabled) }
                .map { $0.name }
                .joined(separator: ", ")
            if !skillNames.isEmpty {
                prompt += "\n\n<available_skills>\nAvailable skills: \(skillNames)\nUse the Skill tool to load full instructions for any skill before using it.\n</available_skills>"
            }
        }

        log("ChatProvider: task chat prompt built — prompt_length: \(prompt.count) chars")
        return prompt
    }

    /// Builds a minimal system prompt (for simple messages)
    private func buildSystemPromptSimple() -> String {
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName
        return ChatPromptBuilder.buildDesktopChat(userName: userName)
    }


    /// Formats the last 30 non-empty messages in the current session as a conversation history string.
    /// Used to seed new ACP sessions with context from the existing chat UI history.
    /// This is critical when session resume fails after an app restart or update, as it is
    /// the only mechanism that preserves conversational context for the new session.
    private func buildConversationHistory() -> String {
        let recent = messages.filter { !$0.text.isEmpty }.suffix(30)
        return recent.map { msg in
            let role = msg.sender == .user ? "User" : "Assistant"
            return "\(role): \(msg.text)"
        }.joined(separator: "\n")
    }

    /// Restore floating chat messages and session from local DB.
    /// Called eagerly during warmup (so conversation history is available for the system prompt)
    /// and idempotently on the first floating bar interaction.
    func restoreFloatingChatIfNeeded() async {
        guard !floatingChatRestored else { return }
        floatingChatRestored = true

        // User started a new chat before the app quit — don't restore old messages
        if UserDefaults.standard.bool(forKey: Self.floatingChatClearedKey) {
            UserDefaults.standard.removeObject(forKey: Self.floatingChatClearedKey)
            log("ChatProvider: Skipping floating chat restore (new chat was started)")
            return
        }

        let savedMessages = await ChatMessageStore.loadMessages(
            context: "__floating__",
            limit: Self.floatingRestoreLimit
        )
        guard !savedMessages.isEmpty else {
            log("ChatProvider: No floating chat messages to restore")
            return
        }

        messages = savedMessages
        log("ChatProvider: Restored \(savedMessages.count) floating chat messages from local DB")

        // Load saved ACP session ID for resume
        if let savedSessionId = UserDefaults.standard.string(forKey: floatingSessionIdKey) {
            pendingFloatingResume = savedSessionId
            log("ChatProvider: Will resume floating ACP session \(savedSessionId)")
        }
    }

    /// Initialize chat: fetch sessions and load messages
    func initialize() async {
        // Seed cumulative builtin cost from Firestore (background, no latency impact)
        Task.detached(priority: .background) { [weak self] in
            guard let serverCost = await APIClient.shared.fetchTotalBuiltinCost() else { return }
            guard let self else { return }
            await MainActor.run {
                // Always trust the server value — it's the authoritative total
                self.builtinCumulativeCostUsd = serverCost
                log("ChatProvider: Seeded builtin cumulative cost from Firestore: $\(String(format: "%.4f", serverCost))")

                // If already over cap and still in builtin mode, switch immediately
                if self.bridgeMode == "builtin" && serverCost >= Self.builtinCostCapUsd {
                    log("ChatProvider: Builtin cost already at $\(String(format: "%.2f", serverCost)) on startup — switching to personal mode")
                    self.showCreditExhaustedAlert = true
                    Task { await self.switchBridgeMode(to: "personal") }
                }
            }
        }

        // Load default chat messages (syncs with Flutter mobile app)
        await loadDefaultChatMessages()
        await loadAIProfileIfNeeded()
        await loadSchemaIfNeeded()
        await discoverClaudeConfig()

        // Set working directory for Claude Agent SDK if workspace is configured
        if workingDirectory == nil, !aiChatWorkingDirectory.isEmpty {
            workingDirectory = aiChatWorkingDirectory
        }

        // Pre-load floating chat from DB so PTT doesn't block on first invocation
        await restoreFloatingChatIfNeeded()
    }

    /// Reinitialize after settings change
    func reinitialize() async {
        messages = []
        await initialize()
    }

    /// Retry loading after a failure — clears error state and re-runs initialize
    func retryLoad() async {
        sessionsLoadError = nil
        await initialize()
    }

    // MARK: - CLAUDE.md & Skills Discovery

    /// Results from background Claude config discovery
    private struct ClaudeConfigResult: Sendable {
        let claudeMdContent: String?
        let claudeMdPath: String?
        let skills: [(name: String, description: String, path: String)]
        let projectClaudeMdContent: String?
        let projectClaudeMdPath: String?
        let projectSkills: [(name: String, description: String, path: String)]
        let devModeContext: String?
    }

    /// Perform all file I/O for Claude config discovery off the main thread
    private nonisolated static func loadClaudeConfigFromDisk(workspace: String) -> ClaudeConfigResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeDir = "\(home)/.claude"
        let fm = FileManager.default

        // Discover global CLAUDE.md
        let mdPath = "\(claudeDir)/CLAUDE.md"
        var globalMdContent: String?
        var globalMdPath: String?
        if fm.fileExists(atPath: mdPath),
           let content = try? String(contentsOfFile: mdPath, encoding: .utf8) {
            globalMdContent = content
            globalMdPath = mdPath
        }

        // Discover global skills
        var skills: [(name: String, description: String, path: String)] = []
        let skillsDir = "\(claudeDir)/skills"
        if let skillDirs = try? fm.contentsOfDirectory(atPath: skillsDir) {
            for dir in skillDirs.sorted() {
                let skillPath = "\(skillsDir)/\(dir)/SKILL.md"
                if fm.fileExists(atPath: skillPath),
                   let content = try? String(contentsOfFile: skillPath, encoding: .utf8) {
                    let desc = extractSkillDescription(from: content)
                    skills.append((name: dir, description: desc, path: skillPath))
                }
            }
        }

        // Discover project-level config from workspace directory
        var projMdContent: String?
        var projMdPath: String?
        var projectSkills: [(name: String, description: String, path: String)] = []

        if !workspace.isEmpty, fm.fileExists(atPath: workspace) {
            let projectMdPath = "\(workspace)/CLAUDE.md"
            if fm.fileExists(atPath: projectMdPath),
               let content = try? String(contentsOfFile: projectMdPath, encoding: .utf8) {
                projMdContent = content
                projMdPath = projectMdPath
            }

            let projectSkillsDir = "\(workspace)/.claude/skills"
            if let skillDirs = try? fm.contentsOfDirectory(atPath: projectSkillsDir) {
                for dir in skillDirs.sorted() {
                    let skillPath = "\(projectSkillsDir)/\(dir)/SKILL.md"
                    if fm.fileExists(atPath: skillPath),
                       let content = try? String(contentsOfFile: skillPath, encoding: .utf8) {
                        let desc = extractSkillDescription(from: content)
                        projectSkills.append((name: dir, description: desc, path: skillPath))
                    }
                }
            }
        }

        // Load dev-mode skill content (full SKILL.md, not just description)
        var devMode: String?
        let devModeSkillPath = "\(skillsDir)/dev-mode/SKILL.md"
        if fm.fileExists(atPath: devModeSkillPath),
           let content = try? String(contentsOfFile: devModeSkillPath, encoding: .utf8) {
            var body = content
            if body.hasPrefix("---") {
                let lines = body.components(separatedBy: "\n")
                if let endIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }) {
                    body = lines[(endIdx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            devMode = body
        } else {
            let projectDevModePath = "\(workspace)/.claude/skills/dev-mode/SKILL.md"
            if !workspace.isEmpty, fm.fileExists(atPath: projectDevModePath),
               let content = try? String(contentsOfFile: projectDevModePath, encoding: .utf8) {
                var body = content
                if body.hasPrefix("---") {
                    let lines = body.components(separatedBy: "\n")
                    if let endIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }) {
                        body = lines[(endIdx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                devMode = body
            }
        }

        return ClaudeConfigResult(
            claudeMdContent: globalMdContent,
            claudeMdPath: globalMdPath,
            skills: skills,
            projectClaudeMdContent: projMdContent,
            projectClaudeMdPath: projMdPath,
            projectSkills: projectSkills,
            devModeContext: devMode
        )
    }

    /// Discover ~/.claude/CLAUDE.md, skills from ~/.claude/skills/, and project-level equivalents
    func discoverClaudeConfig() async {
        let workspace = aiChatWorkingDirectory
        let result = await Task.detached(priority: .utility) {
            Self.loadClaudeConfigFromDisk(workspace: workspace)
        }.value

        // Assign results back on main actor
        claudeMdContent = result.claudeMdContent
        claudeMdPath = result.claudeMdPath
        discoveredSkills = result.skills
        projectClaudeMdContent = result.projectClaudeMdContent
        projectClaudeMdPath = result.projectClaudeMdPath
        projectDiscoveredSkills = result.projectSkills
        devModeContext = result.devModeContext

        log("ChatProvider: discovered global CLAUDE.md=\(claudeMdContent != nil), global skills=\(discoveredSkills.count), project CLAUDE.md=\(projectClaudeMdContent != nil), project skills=\(projectDiscoveredSkills.count), dev_mode_skill=\(devModeContext != nil)")
    }

    /// Discover project CLAUDE.md and skills for a specific workspace path (used by detached windows).
    /// Returns project config result for the given directory.
    struct ProjectConfig: Sendable {
        let claudeMdContent: String?
        let claudeMdPath: String?
        let skills: [(name: String, description: String, path: String)]
    }

    nonisolated static func discoverProjectConfig(workspace: String) async -> ProjectConfig {
        let result = await Task.detached(priority: .utility) {
            loadClaudeConfigFromDisk(workspace: workspace)
        }.value
        return ProjectConfig(
            claudeMdContent: result.projectClaudeMdContent,
            claudeMdPath: result.projectClaudeMdPath,
            skills: result.projectSkills
        )
    }

    /// Extract description from YAML frontmatter in SKILL.md
    nonisolated static func extractSkillDescription(from content: String) -> String {
        guard content.hasPrefix("---") else {
            // No frontmatter — use first non-empty line as description
            let lines = content.components(separatedBy: "\n")
            return lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let lines = content.components(separatedBy: "\n")
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("---") { break }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("description:") {
                var value = String(line.trimmingCharacters(in: .whitespaces).dropFirst("description:".count))
                value = value.trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes if present
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return ""
    }

    /// Get the set of enabled skill names (all skills minus explicitly disabled ones)
    func getEnabledSkillNames() -> Set<String> {
        let allSkillNames = Set(discoveredSkills.map { $0.name } + projectDiscoveredSkills.map { $0.name })
        let disabled = getDisabledSkillNames()
        return allSkillNames.subtracting(disabled)
    }

    /// Get the set of explicitly disabled skill names from UserDefaults
    func getDisabledSkillNames() -> Set<String> {
        guard let data = disabledSkillsJSON.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return [] // Default: nothing disabled = all enabled
        }
        return Set(names)
    }

    /// Save the set of disabled skill names to UserDefaults
    func setDisabledSkillNames(_ names: Set<String>) {
        if let data = try? JSONEncoder().encode(Array(names)),
           let json = String(data: data, encoding: .utf8) {
            disabledSkillsJSON = json
        }
    }

    /// Switch to the default chat (messages without session_id, syncs with Flutter app)
    /// Load messages for the default chat (no session filter - compatible with Flutter)
    /// Retries up to 3 times on failure.
    func loadDefaultChatMessages() async {
        isLoading = true
        errorMessage = nil
        hasMoreMessages = false

        let maxAttempts = 3
        let delays: [UInt64] = [1_000_000_000, 2_000_000_000] // 1s, 2s
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let persistedMessages = try await APIClient.shared.getMessages(
                    appId: selectedAppId,
                    limit: messagesPageSize
                )
                messages = persistedMessages.map(ChatMessage.init(from:))
                    .sorted(by: { $0.createdAt < $1.createdAt })
                hasMoreMessages = persistedMessages.count == messagesPageSize
                sessionsLoadError = nil
                log("ChatProvider loaded \(messages.count) default chat messages, hasMore: \(hasMoreMessages)")
                isLoading = false
                return
            } catch {
                lastError = error
                logError("Failed to load default chat messages (attempt \(attempt)/\(maxAttempts))", error: error)
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: delays[attempt - 1])
                }
            }
        }

        messages = []
        sessionsLoadError = lastError?.localizedDescription ?? "Unknown error"
        isLoading = false
    }

    // MARK: - Cross-Platform Message Polling

    /// Poll for new messages from other platforms (e.g. mobile).
    /// Merges new messages into the existing array without disrupting the UI.
    private func pollForNewMessages() async {
        // Skip if user is signed out (tokens are cleared)
        guard AuthState.shared.isSignedIn else { return }
        // Skip if we're actively sending. Note: isSending is released *before* the AI
        // message is saved to the backend (to unblock the next query). This means the
        // poll can run while saveMessage() is still in-flight — see the race note below.
        guard !isSending, !isLoading else { return }
        // Skip if messages haven't been loaded yet (initial load not done)
        guard !messages.isEmpty || sessionsLoadError != nil else { return }
        // Skip if there's an active streaming message
        guard !messages.contains(where: { $0.isStreaming }) else { return }

        do {
            let persistedMessages = try await APIClient.shared.getMessages(
                appId: selectedAppId,
                limit: messagesPageSize
            )

            // Build a lookup of existing IDs for fast O(1) checks.
            let existingIds = Set(messages.map(\.id))

            var genuinelyNewMessages: [ChatMessage] = []

            for dbMsg in persistedMessages {
                // Fast path: already in memory by server ID — skip.
                if existingIds.contains(dbMsg.id) { continue }

                // Race-condition guard: isSending is released before the backend save
                // completes (intentionally, to unblock the next query). If this poll
                // fires between "isSending = false" and "messages[i].id = response.id",
                // the backend message lands here with a server ID that doesn't match
                // the local UUID still sitting in messages[]. Without this check we'd
                // append a duplicate.
                //
                // Detection: find an in-memory message that (a) hasn't been synced yet
                // (isSynced=false → still has a local UUID) and (b) has the same text.
                // If found, this is the same message — just update its ID in-place
                // instead of appending a copy.
                let dbSender: ChatSender = dbMsg.sender == "human" ? .user : .ai
                let dbPrefix = String(dbMsg.text.prefix(200))
                if let localIndex = messages.firstIndex(where: {
                    !$0.isSynced && $0.sender == dbSender && String($0.text.prefix(200)) == dbPrefix
                }) {
                    // Merge: adopt the server ID so future polls find it by ID.
                    messages[localIndex].id = dbMsg.id
                    messages[localIndex].isSynced = true
                    log("ChatProvider poll: merged backend ID \(dbMsg.id) into local message (was unsynced)")
                    continue
                }

                // Genuinely new message from another platform (phone, web, etc.)
                genuinelyNewMessages.append(ChatMessage(from: dbMsg))
            }

            if !genuinelyNewMessages.isEmpty {
                log("ChatProvider poll: found \(genuinelyNewMessages.count) new message(s) from other platforms")
                messages.append(contentsOf: genuinelyNewMessages)
                messages.sort(by: { $0.createdAt < $1.createdAt })
            }
        } catch {
            // Silent failure — polling errors shouldn't disrupt the user
            logError("ChatProvider poll failed", error: error)
        }
    }

    // MARK: - Stop / Follow-Up

    /// Queue of messages waiting to be sent after the current query finishes.
    /// Replaces the old single pendingFollowUpText. Checked at the end of `sendMessage`.
    private var pendingMessages: [(text: String, sessionKey: String?, userMessageAdded: Bool)] = []
    /// Read-only accessor for pending message texts (used by UI to sync deletions).
    var pendingMessageTexts: [String] { pendingMessages.map(\.text) }
    /// Session key of the currently running sendMessage call, so follow-ups can be chained on the same session.
    private(set) var activeSessionKey: String?


    /// Stop the ACP bridge and all its child processes (MCP servers).
    /// Called during app termination to prevent orphaned processes.
    func stopBridge() {
        Task { await acpBridge.stop() }
    }

    /// Stop the running agent, keeping partial response
    func stopAgent() {
        guard isSending else { return }
        isStopping = true
        pendingCountAtStop = pendingMessages.count
        log("ChatProvider: user stopped agent, sending interrupt (pendingCountAtStop=\(pendingCountAtStop))")
        Task {
            await acpBridge.interrupt()
        }
        // Result flows back normally through the bridge with partial text
    }

    /// Stop the running agent for a specific session only. Other concurrent sessions continue.
    func stopAgent(sessionKey: String) {
        guard sendingSessionKeys.contains(sessionKey) else { return }
        log("ChatProvider: user stopped agent for session=\(sessionKey)")
        Task {
            await acpBridge.interrupt(sessionKey: sessionKey)
        }
    }

    /// Returns true if a query is currently in flight for the given session key.
    func isSending(sessionKey: String) -> Bool {
        return sendingSessionKeys.contains(sessionKey)
    }

    /// Re-send the message that was interrupted by browser extension setup.
    func retryPendingMessage() {
        guard let text = pendingRetryMessage else { return }
        pendingRetryMessage = nil
        log("ChatProvider: Retrying pending message after browser extension setup")
        Task { await sendMessage(text) }
    }

    /// Stop the ACP bridge so it picks up the new Playwright extension token on next start.
    /// Does NOT restart — leaves `acpBridgeStarted = false` so the next `sendMessage` call
    /// goes through `ensureBridgeStarted()` which does a full warmup with session resume.
    /// This preserves conversation history across the browser extension setup flow.
    func restartBridgeForNewToken() async {
        guard acpBridgeStarted else { return }
        log("ChatProvider: Stopping bridge to pick up new Playwright token (will restart with session resume on next query)")
        await acpBridge.stop()
        acpBridgeStarted = false
    }

    /// Stop the ACP bridge so it picks up the new custom API endpoint on next start.
    func restartBridgeForEndpointChange() async {
        guard acpBridgeStarted else { return }
        let endpoint = UserDefaults.standard.string(forKey: "customApiEndpoint") ?? ""
        log("ChatProvider: Stopping bridge to apply custom endpoint change (endpoint=\(endpoint.isEmpty ? "default" : endpoint), will restart on next query)")
        await acpBridge.stop()
        acpBridgeStarted = false
    }

    /// Stop the ACP bridge so it picks up the new voice response setting on next start.
    func restartBridgeForVoiceResponse() async {
        guard acpBridgeStarted else { return }
        let enabled = voiceResponseEnabled
        log("ChatProvider: Stopping bridge to apply voice response change (enabled=\(enabled), will restart on next query)")
        await acpBridge.stop()
        acpBridgeStarted = false
    }

    /// Enqueue a message to be sent after the current query finishes.
    /// Does NOT interrupt the current query — it will be picked up automatically.
    /// Pass the caller's `sessionKey` so the message runs on the correct session
    /// (not the currently-active one, which may belong to a different window).
    func enqueueMessage(_ text: String, sessionKey: String? = nil) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        pendingMessages.append((text: trimmedText, sessionKey: sessionKey ?? activeSessionKey, userMessageAdded: false))
        log("ChatProvider: message enqueued (\(pendingMessages.count) pending), sessionKey=\(sessionKey ?? activeSessionKey ?? "nil")")
    }

    /// Interrupt the current query and send a message immediately.
    /// If the AI is idle, sends the message directly without interrupting.
    func interruptAndSend(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Remove any existing enqueued copy to avoid sending the same message twice
        // (e.g. user enqueues a follow-up, then taps "Send Now" on the queued item)
        if let existingIdx = pendingMessages.firstIndex(where: { $0.text == trimmedText }) {
            pendingMessages.remove(at: existingIdx)
        }

        // If idle, send directly as a follow-up
        if !isSending {
            log("ChatProvider: send-now (idle), sending directly")
            NotificationCenter.default.post(name: .chatProviderDidDequeue, object: nil, userInfo: ["text": trimmedText, "sessionKey": activeSessionKey ?? ""])
            await sendMessage(trimmedText, isFollowUp: false, sessionKey: activeSessionKey)
            return
        }

        // Add as user message in UI
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            text: trimmedText,
            sender: .user
        )
        messages.append(userMessage)

        // Persist to backend
        let capturedAppId = overrideAppId ?? selectedAppId
        let localId = userMessage.id
        Task { [weak self] in
            do {
                let response = try await APIClient.shared.saveMessage(
                    text: trimmedText,
                    sender: "human",
                    appId: capturedAppId,
                    sessionId: nil
                )
                await MainActor.run {
                    if let index = self?.messages.firstIndex(where: { $0.id == localId }) {
                        self?.messages[index].id = response.id
                        self?.messages[index].isSynced = true
                    }
                }
                log("Saved follow-up message to backend: \(response.id)")
            } catch {
                logError("Failed to persist follow-up message", error: error)
            }
        }

        // Insert at front of queue and interrupt — userMessageAdded=true because we added it above
        pendingMessages.insert((text: trimmedText, sessionKey: activeSessionKey, userMessageAdded: true), at: 0)
        await acpBridge.interrupt()
        log("ChatProvider: interrupt+send, \(pendingMessages.count) pending")
    }

    /// Remove a pending message by matching text (used when UI deletes from queue).
    func removePendingMessage(at index: Int) {
        guard index >= 0, index < pendingMessages.count else { return }
        pendingMessages.remove(at: index)
    }

    /// Reorder pending messages (used when UI reorders queue).
    func reorderPendingMessages(from source: IndexSet, to destination: Int) {
        pendingMessages.move(fromOffsets: source, toOffset: destination)
    }

    /// Clear all pending messages.
    func clearPendingMessages() {
        pendingMessages.removeAll()
        log("ChatProvider: pending queue cleared")
    }

    /// Clear pending messages for a specific session only.
    func clearPendingMessages(forSession sessionKey: String) {
        let before = pendingMessages.count
        pendingMessages.removeAll { $0.sessionKey == sessionKey }
        let removed = before - pendingMessages.count
        if removed > 0 {
            log("ChatProvider: cleared \(removed) pending messages for session \(sessionKey)")
        }
    }

    // MARK: - Send Message

    /// Send a message and get AI response via Claude Agent SDK bridge
    /// Persists both user and AI messages to backend
    /// - Parameters:
    ///   - text: The message text
    ///   - model: Optional model override for this query (e.g. "claude-sonnet-4-6" for floating bar)
    func sendMessage(_ text: String, model: String? = nil, isFollowUp: Bool = false, systemPromptSuffix: String? = nil, systemPromptPrefix: String? = nil, sessionKey: String? = nil, resume: String? = nil, cwd: String? = nil, attachments: [[String: String]]? = nil) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Per-session guard: allow concurrent queries for different session keys
        // (e.g. different pop-out windows), but block the same session from
        // double-sending. Set state immediately (before any await) to close the
        // race window where multiple calls could pass this guard concurrently.
        let effectiveKey = sessionKey ?? activeSessionKey ?? "__default__"
        guard !sendingSessionKeys.contains(effectiveKey) else {
            log("ChatProvider: sendMessage called while session=\(effectiveKey) already sending, ignoring")
            AnalyticsManager.shared.chatMessageDropped(
                messageLength: trimmedText.count,
                reason: "concurrent_send"
            )
            let breadcrumb = Breadcrumb(level: .warning, category: "chat")
            breadcrumb.message = "sendMessage dropped: session \(effectiveKey) already sending (\(trimmedText.prefix(50))...)"
            SentrySDK.addBreadcrumb(breadcrumb)
            return
        }
        sendingSessionKeys.insert(effectiveKey)
        isSending = true

        // Notify observers (e.g. floating bar) that a new query is starting
        queryStartedCount += 1

        // Track the active session key so follow-ups can be chained on the same session
        activeSessionKey = sessionKey

        // Auto-resume floating chat session after app restart
        var resume = resume
        if sessionKey == "floating", resume == nil, let pendingResume = pendingFloatingResume {
            resume = pendingResume
            pendingFloatingResume = nil
            log("ChatProvider: Using saved floating session ID for resume: \(pendingResume)")
        }
        // Auto-resume detached chat sessions
        if let key = sessionKey, key.hasPrefix("detached-"), resume == nil {
            if let savedId = detachedSessionResumeId(for: key) {
                resume = savedId
                log("ChatProvider: Using saved detached session ID for resume: \(savedId)")
            }
        }
        // Auto-resume main chat session after ACP restart (e.g. OAuth re-login)
        if (sessionKey == nil || sessionKey == "main"), resume == nil {
            if let savedId = UserDefaults.standard.string(forKey: mainSessionIdKey), !savedId.isEmpty {
                resume = savedId
                log("ChatProvider: Using saved main session ID for resume: \(savedId)")
            }
        }

        // Pre-query guard: check if builtin cost cap is reached
        if bridgeMode == "builtin" && builtinCumulativeCostUsd >= Self.builtinCostCapUsd {
            log("ChatProvider: Builtin cost cap reached ($\(String(format: "%.2f", builtinCumulativeCostUsd))/$\(String(format: "%.0f", Self.builtinCostCapUsd))) — switching to personal mode")
            showCreditExhaustedAlert = true
            await switchBridgeMode(to: "personal")
            // Don't return — let the query proceed on the personal account
        }

        // Ensure bridge is running
        guard await ensureBridgeStarted() else {
            errorMessage = "AI not available"
            sendingSessionKeys.remove(effectiveKey)
            isSending = !sendingSessionKeys.isEmpty
            return
        }

        // Pre-query paywall: block the message if no active subscription and free limit exceeded.
        // Builtin mode uses the bundled Anthropic key and is always allowed.
        SubscriptionService.shared.incrementMessageCount()
        if bridgeMode != "builtin"
            && !SubscriptionService.shared.isActive
            && SubscriptionService.shared.dailyMessageCount > SubscriptionService.shared.freeMessagesPerDay {
            await SubscriptionService.shared.refreshStatus()
            if SubscriptionService.shared.shouldShowPaywall() {
                showPaywall = true
                PaywallWindowController.shared.show(chatProvider: self)
                sendingSessionKeys.remove(effectiveKey)
                isSending = !sendingSessionKeys.isEmpty
                return
            }
        }

        errorMessage = nil
        pendingRetryMessage = trimmedText

        // Track user message sent
        AnalyticsManager.shared.chatMessageSent(
            messageLength: trimmedText.count,
            hasContext: systemPromptSuffix != nil || systemPromptPrefix != nil,
            source: sessionKey ?? "default"
        )

        // Save user message to backend and add to UI.
        // (skip for follow-ups — sendFollowUp already did both)
        //
        // The save is fire-and-forget (unstructured Task) so it doesn't block
        // the ACP query from starting. This is safe because isSending=true for
        // the entire duration of the ACP query, so the poll timer is suppressed
        // the whole time — by the time isSending is released the user message
        // save has almost always already completed and its ID has been synced.
        let userMessageId = UUID().uuidString
        let capturedAppId = overrideAppId ?? selectedAppId
        if !isFollowUp {
            Task { [weak self] in
                do {
                    let response = try await APIClient.shared.saveMessage(
                        text: trimmedText,
                        sender: "human",
                        appId: capturedAppId,
                        sessionId: nil
                    )
                    // Adopt the server ID (local UUID → server ID) and mark synced.
                    // isSynced=true enables rating buttons on the message bubble.
                    await MainActor.run {
                        if let index = self?.messages.firstIndex(where: { $0.id == userMessageId }) {
                            self?.messages[index].id = response.id
                            self?.messages[index].isSynced = true
                        }
                    }
                    log("Saved user message to backend: \(response.id)")
                } catch {
                    logError("Failed to persist user message", error: error)
                    // Non-critical - continue with chat
                }
            }

            let userAttachments: [ChatAttachment] = (attachments ?? []).compactMap { dict in
                guard let path = dict["path"], let name = dict["name"], let mime = dict["mimeType"] else { return nil }
                return ChatAttachment(path: path, name: name, mimeType: mime)
            }
            let userMessage = ChatMessage(
                id: userMessageId,
                text: trimmedText,
                sender: .user,
                sessionKey: sessionKey,
                attachments: userAttachments
            )
            messages.append(userMessage)

            // Persist onboarding messages locally for restart recovery
            if isOnboarding {
                let msg = userMessage
                Task { await OnboardingChatPersistence.saveMessage(msg) }
            } else if sessionKey == "floating" {
                let msg = userMessage
                let sid = floatingChatSessionId
                Task { await ChatMessageStore.saveMessage(msg, context: "__floating__", sessionId: sid) }
                // User sent a message in the new chat — clear the "new chat" flag
                // so this conversation restores if the app is killed mid-conversation
                UserDefaults.standard.removeObject(forKey: Self.floatingChatClearedKey)
            } else if let key = sessionKey, key.hasPrefix("detached-") {
                let msg = userMessage
                let sid = UserDefaults.standard.string(forKey: "acpSessionId_\(key)_\(bridgeMode)")
                Task { await ChatMessageStore.saveMessage(msg, context: "__\(key)__", sessionId: sid) }
            }
        }

        // Create a placeholder AI message shown immediately in the UI while
        // streaming. It starts with a local UUID (isSynced=false, no rating buttons).
        // Lifecycle: local UUID → streaming text appended token by token →
        // isStreaming=false → isSending=false → backend save → ID replaced with
        // server ID, isSynced=true (rating buttons appear).
        let aiMessageId = UUID().uuidString
        let aiMessage = ChatMessage(
            id: aiMessageId,
            text: "",
            sender: .ai,
            isStreaming: true,
            sessionKey: sessionKey
        )
        messages.append(aiMessage)

        // Analytics: track timing and tool usage
        let queryStartTime = Date()
        var firstTokenTime: Date?
        var toolNames: [String] = []
        var toolStartTimes: [String: Date] = [:]
        var toolResults: [String: String] = [:]  // Track last result per tool for success/failure
        var activeBrowserToolCount = 0
        var retryAfterModelFallback = false
        var hadError = false

        do {
            // Use the system prompt built at warmup. The ACP bridge applies it only
            // at session/new; for the normal reused-session path it is ignored.
            // Passing it here ensures it is applied if the session was invalidated
            // (e.g. cwd change) and a new session/new is triggered mid-conversation.
            var systemPrompt: String
            if isOnboarding, let prefix = systemPromptPrefix, !prefix.isEmpty {
                // Onboarding uses its own prompt exclusively — the main chat prompt
                // contains rules like "don't ask follow-up questions" that conflict
                // with the onboarding deep-dive step.
                systemPrompt = prefix
            } else {
                systemPrompt = cachedMainSystemPrompt
                if let prefix = systemPromptPrefix, !prefix.isEmpty {
                    systemPrompt = prefix + "\n\n" + systemPrompt
                }
            }
            if let suffix = systemPromptSuffix, !suffix.isEmpty {
                systemPrompt += "\n\n" + suffix
            }

            // Query the active bridge with streaming
            // Callbacks for ACP bridge
            let textDeltaHandler: ACPBridge.TextDeltaHandler = { [weak self] delta in
                Task { @MainActor [weak self] in
                    if firstTokenTime == nil {
                        firstTokenTime = Date()
                        let ttftMs = Int(Date().timeIntervalSince(queryStartTime) * 1000)
                        log("Chat TTFT: \(ttftMs)ms (session=\(sessionKey ?? "main"))")
                    }
                    self?.appendToMessage(id: aiMessageId, text: delta)
                    // Forward to phone
                    self?.webRelay.sendToPhone(["type": "text_delta", "text": delta])
                }
            }
            let toolCallHandler: ACPBridge.ToolCallHandler = { [weak self] callId, name, input in
                let toolCall = ToolCall(name: name, arguments: input, thoughtSignature: nil)
                let result = await ChatToolExecutor.execute(toolCall)
                log("Fazm tool \(name) executed for callId=\(callId)")
                await MainActor.run { toolResults[name] = result }
                return result
            }
            let toolActivityHandler: ACPBridge.ToolActivityHandler = { [weak self] name, status, toolUseId, input in
                Task { @MainActor [weak self] in
                    // Forward to phone
                    self?.webRelay.sendToPhone(["type": "tool_activity", "name": name, "status": status])
                    self?.addToolActivity(
                        messageId: aiMessageId,
                        toolName: name,
                        status: status == "started" ? .running : .completed,
                        toolUseId: toolUseId,
                        input: input
                    )
                    if status == "started" {
                        toolNames.append(name)
                        toolStartTimes[name] = Date()
                        if name.hasPrefix("mcp__playwright__") {
                            let token = UserDefaults.standard.string(forKey: "playwrightExtensionToken") ?? ""
                            if token.isEmpty {
                                log("ChatProvider: Browser tool \(name) called without extension token — aborting query and prompting setup")
                                self?.stoppedForBrowserSetup = true
                                self?.needsBrowserExtensionSetup = true
                                self?.stopAgent()
                                // Bring the app to the foreground so the setup sheet is visible
                                // (the failed browser attempt may have opened Chrome, stealing focus)
                                NSApp.activate(ignoringOtherApps: true)
                                for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                                    window.makeKeyAndOrderFront(nil)
                                }
                            }
                            // Show the floating bar so the user has an always-on-top UI
                            // when Chrome takes focus (important on small screens)
                            if !FloatingControlBarManager.shared.isVisible {
                                log("ChatProvider: Browser tool active — showing floating bar so it stays above Chrome")
                                FloatingControlBarManager.shared.showTemporarily()
                            }
                            // Suppress click-outside dismiss while browser tools run
                            activeBrowserToolCount += 1
                            FloatingControlBarManager.shared.setSuppressClickOutsideDismiss(true)
                        }
                    } else if status == "completed", let startTime = toolStartTimes.removeValue(forKey: name) {
                        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
                        let result = toolResults.removeValue(forKey: name)
                        let isError = result?.hasPrefix("Error:") == true || result?.hasPrefix("error:") == true || result?.hasPrefix("ERROR:") == true
                        AnalyticsManager.shared.chatToolCallCompleted(
                            toolName: name,
                            durationMs: durationMs,
                            success: !isError,
                            error: isError ? result : nil
                        )
                        if (name.contains("browser") || name.contains("playwright")) {
                            activeBrowserToolCount = max(0, activeBrowserToolCount - 1)
                            if activeBrowserToolCount == 0 {
                                FloatingControlBarManager.shared.setSuppressClickOutsideDismiss(false)
                            }
                            // Track first successful browser tool use after extension setup
                            if !UserDefaults.standard.bool(forKey: "browserToolFirstUseTracked") {
                                UserDefaults.standard.set(true, forKey: "browserToolFirstUseTracked")
                                AnalyticsManager.shared.browserToolFirstUse(
                                    toolName: name,
                                    success: !isError,
                                    error: isError ? result : nil
                                )
                            }
                        }
                        // Track completed onboarding steps for restart recovery
                        if self?.isOnboarding == true {
                            if name.contains("WebSearch") || name.contains("web_search") {
                                OnboardingChatPersistence.markStepCompleted("web_search")
                            } else if name == "scan_files" {
                                OnboardingChatPersistence.markStepCompleted("file_scan")
                            } else if name == "set_user_preferences" {
                                OnboardingChatPersistence.markStepCompleted("user_preferences")
                            } else if name == "save_knowledge_graph" {
                                OnboardingChatPersistence.markStepCompleted("knowledge_graph")
                            }
                        }
                    }
                }
            }
            let thinkingDeltaHandler: ACPBridge.ThinkingDeltaHandler = { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.appendThinking(messageId: aiMessageId, text: text)
                }
            }
            let toolResultDisplayHandler: ACPBridge.ToolResultDisplayHandler = { [weak self] toolUseId, name, output in
                Task { @MainActor [weak self] in
                    self?.addToolResult(messageId: aiMessageId, toolUseId: toolUseId, name: name, output: output)
                    // Detect browser extension disconnect mid-task
                    // Only prompt setup if token is missing (first-time); if token exists, let the agent handle the error naturally
                    let isBrowserTool = name.contains("browser") || name.contains("playwright")
                    let isDisconnected = output.contains("Extension connection timeout")
                        || output.contains("extension is not connected")
                    let hasToken = !(UserDefaults.standard.string(forKey: "playwrightExtensionToken") ?? "").isEmpty
                    if isBrowserTool && isDisconnected && !hasToken && self?.stoppedForBrowserSetup != true {
                        log("ChatProvider: Browser extension not set up (\(name)) — prompting setup")
                        self?.errorMessage = "The browser extension disconnected. Reconnecting — your task will resume automatically once it's back."
                        self?.stoppedForBrowserSetup = true
                        self?.needsBrowserExtensionSetup = true
                        self?.stopAgent()
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
            }
            let textBlockBoundaryHandler: ACPBridge.TextBlockBoundaryHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleTextBlockBoundary(messageId: aiMessageId)
                }
            }

            let effectiveCwd = cwd ?? workingDirectory
            log("Chat query started (session=\(sessionKey ?? "main"), mode=\(bridgeMode), model=\(model ?? modelOverride ?? "default"), cwd=\(effectiveCwd ?? "nil"))")
            let queryResult = try await acpBridge.query(
                prompt: trimmedText,
                systemPrompt: systemPrompt,
                sessionKey: isOnboarding ? "onboarding" : (sessionKey ?? "main"),
                cwd: effectiveCwd,
                mode: chatMode.rawValue,
                model: model ?? modelOverride,
                resume: resume,
                attachments: attachments,
                onTextDelta: textDeltaHandler,
                onToolCall: toolCallHandler,
                onToolActivity: toolActivityHandler,
                onThinkingDelta: thinkingDeltaHandler,
                onTextBlockBoundary: textBlockBoundaryHandler,
                onToolResultDisplay: toolResultDisplayHandler,
                onAuthRequired: { [weak self] methods, authUrl in
                    Task { @MainActor [weak self] in
                        self?.claudeAuthMethods = methods
                        self?.claudeAuthUrl = authUrl
                        self?.isClaudeAuthRequired = true
                    }
                },
                onAuthSuccess: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.oauthAutoReopenTask?.cancel()
                        self?.isClaudeAuthRequired = false
                        self?.checkClaudeConnectionStatus()
                    }
                },
                onStatusEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch event {
                        case .compacting(let active):
                            self.isCompacting = active
                            self.compactingSessionKey = active ? sessionKey : nil
                            if active {
                                log("ChatProvider: Context compaction started (session=\(sessionKey ?? "nil"))")
                            } else {
                                log("ChatProvider: Context compaction finished (session=\(sessionKey ?? "nil"))")
                            }
                        case .compactBoundary(let trigger, let preTokens):
                            log("ChatProvider: Compact boundary — trigger=\(trigger), preTokens=\(preTokens)")
                        case .taskStarted(let taskId, let description):
                            self.addToolActivity(
                                messageId: aiMessageId,
                                toolName: "Subtask",
                                status: .running,
                                toolUseId: taskId,
                                input: ["description": description]
                            )
                        case .taskNotification(let taskId, let status, _):
                            self.addToolActivity(
                                messageId: aiMessageId,
                                toolName: "Subtask",
                                status: status == "completed" ? .completed : .completed,
                                toolUseId: taskId,
                                input: nil
                            )
                        case .toolProgress(let toolUseId, let toolName, let elapsed):
                            self.logToolProgress(toolUseId: toolUseId, toolName: toolName, elapsed: elapsed)
                        case .toolUseSummary(let summary):
                            log("ChatProvider: Tool summary — \(summary.prefix(100))")
                        case .rateLimit(let status, let resetsAt, let rateLimitType, let utilization):
                            self.handleRateLimitEvent(status: status, resetsAt: resetsAt, rateLimitType: rateLimitType, utilization: utilization)
                        }
                    }
                }
            )

            // Flush any remaining buffered streaming text before finalizing
            streamingFlushWorkItem?.cancel()
            streamingFlushWorkItem = nil
            flushStreamingBuffer()

            // Determine the final text to display and save
            let messageText: String
            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                // Message still in memory — update it in-place
                messageText = messages[index].text.isEmpty ? queryResult.text : messages[index].text
                messages[index].text = messageText
                messages[index].isStreaming = false
                completeRemainingToolCalls(messageId: aiMessageId)

                // Forward final result to phone
                webRelay.sendToPhone(["type": "result", "text": messageText])

                // Persist AI message locally before yielding. The yield below lets
                // the Combine $messages sink run, which may call clearTransferredMessages()
                // and empty the messages array. Save the message reference now while it's
                // still in memory.
                if let freshIndex = messages.firstIndex(where: { $0.id == aiMessageId }), !messageText.isEmpty {
                    let msg = messages[freshIndex]
                    if isOnboarding {
                        Task { await OnboardingChatPersistence.saveMessage(msg) }
                    } else if sessionKey == "floating" {
                        let sid = floatingChatSessionId
                        Task { await ChatMessageStore.saveMessage(msg, context: "__floating__", sessionId: sid) }
                    } else if let key = sessionKey, key.hasPrefix("detached-") {
                        let sid = queryResult.sessionId.isEmpty ? nil : queryResult.sessionId
                        Task { await ChatMessageStore.saveMessage(msg, context: "__\(key)__", sessionId: sid) }
                    }
                }

                // Yield the main actor so the Combine $messages sink (scheduled
                // via .receive(on: .main)) fires now, updating the UI to remove
                // the typing indicator immediately rather than waiting for the
                // backend save network call to complete.
                await Task.yield()
            } else {
                // Message no longer in memory (user switched away from this session).
                messageText = queryResult.text
                log("Chat response arrived after session switch")
            }

            // Release the sending lock as soon as the AI response is visible in the
            // UI. Backend persistence is slow (can timeout at 30s+) and should not
            // block the user from making new queries to Claude.
            //
            // IMPORTANT: releasing isSending here opens a race window with the poll
            // timer. The poll can now fetch backend messages while saveMessage() is
            // still in-flight. The AI message still has a local UUID at this point
            // (isSynced=false). pollForNewMessages() handles this by merging the
            // backend copy into the local message rather than appending a duplicate.
            sendingSessionKeys.remove(effectiveKey)
            isSending = !sendingSessionKeys.isEmpty
            isStopping = false

            await applyPendingBridgeRestart()
            await applyPendingBridgeModeSwitch()
            if stoppedForBrowserSetup {
                // Keep pendingRetryMessage so retryPendingQuery() can re-send it
                stoppedForBrowserSetup = false
            } else {
                pendingRetryMessage = nil  // Successful completion — no retry needed
            }

            // Save AI response to backend. aiMessageId is captured above so we can
            // locate the right message even if the user has started a new query by
            // the time this completes.
            //
            // After save: update the in-memory message's ID from local UUID to the
            // server-assigned ID, and mark isSynced=true. This is the normal path
            // (no race). The poll's merge logic handles the case where the poll fires
            // before this update runs.
            let textToSave = queryResult.text.isEmpty ? messageText : queryResult.text
            if !textToSave.isEmpty {
                do {
                    let toolMetadata = serializeToolCallMetadata(messageId: aiMessageId)
                    let response = try await APIClient.shared.saveMessage(
                        text: textToSave,
                        sender: "ai",
                        appId: capturedAppId,
                        sessionId: nil,
                        metadata: toolMetadata
                    )
                    // Adopt the server ID so future polls find this message by ID
                    // (existingIds check in pollForNewMessages). isSynced=true enables
                    // thumbs-up/down rating UI.
                    if let syncIndex = messages.firstIndex(where: { $0.id == aiMessageId }) {
                        messages[syncIndex].id = response.id
                        messages[syncIndex].isSynced = true
                    }
                    log("Saved and synced AI response: \(response.id) (tool_calls=\(toolMetadata != nil ? "yes" : "none"))")
                } catch {
                    logError("Failed to persist AI response", error: error)
                }
            }

            let totalMs = Int(Date().timeIntervalSince(queryStartTime) * 1000)
            let ttftMs = firstTokenTime.map { Int($0.timeIntervalSince(queryStartTime) * 1000) }
            log("Chat response complete (total=\(totalMs)ms, ttft=\(ttftMs.map { "\($0)ms" } ?? "none"), tools=\(toolNames.count), session=\(sessionKey ?? "main"), mode=\(bridgeMode))")

            // Persist the ACP session ID so we can resume after app restart
            if !queryResult.sessionId.isEmpty {
                if isOnboarding {
                    OnboardingChatPersistence.saveSessionId(queryResult.sessionId)
                }
                if sessionKey == "floating" {
                    UserDefaults.standard.set(queryResult.sessionId, forKey: floatingSessionIdKey)
                } else if let key = sessionKey, key.hasPrefix("detached-") {
                    let detachedIdKey = "acpSessionId_\(key)_\(bridgeMode)"
                    UserDefaults.standard.set(queryResult.sessionId, forKey: detachedIdKey)
                } else if sessionKey == nil || sessionKey == "main" {
                    UserDefaults.standard.set(queryResult.sessionId, forKey: mainSessionIdKey)
                }
            }




            // Analytics: track query completion
            let durationMs = Int(Date().timeIntervalSince(queryStartTime) * 1000)
            // Use the final messageText (already resolved above from either the messages array
            // or queryResult.text fallback) rather than re-looking up from messages which may
            // have been evicted. Also check queryResult.text as a second source of truth.
            let responseLength = max(messageText.count, queryResult.text.count)
            if responseLength == 0 {
                log("ChatProvider: WARNING — response_length=0 on successful query (outputTokens=\(queryResult.outputTokens), messageText.count=\(messageText.count), queryResult.text.count=\(queryResult.text.count))")
                let breadcrumb = Breadcrumb(level: .warning, category: "chat")
                breadcrumb.message = "response_length=0 on success (outputTokens=\(queryResult.outputTokens), mode=\(bridgeMode))"
                SentrySDK.addBreadcrumb(breadcrumb)
            }
            AnalyticsManager.shared.chatAgentQueryCompleted(
                durationMs: durationMs,
                toolCallCount: toolNames.count,
                toolNames: toolNames,
                costUsd: queryResult.costUsd,
                messageLength: responseLength,
                bridgeMode: bridgeMode,
                inputTokens: queryResult.inputTokens,
                outputTokens: queryResult.outputTokens,
                cacheReadTokens: queryResult.cacheReadTokens,
                cacheWriteTokens: queryResult.cacheWriteTokens,
                queryText: trimmedText,
                ttftMs: firstTokenTime.map { Int($0.timeIntervalSince(queryStartTime) * 1000) },
                responseText: messageText.isEmpty ? queryResult.text : messageText
            )

            // Track conversation depth (total messages in this session)
            AnalyticsManager.shared.chatConversationDepth(
                messageCount: messages.count,
                sessionId: nil
            )

            // Track floating bar response metrics separately
            if sessionKey == "floating" {
                AnalyticsManager.shared.floatingBarResponseReceived(
                    durationMs: durationMs,
                    responseLength: responseLength,
                    toolCount: toolNames.count
                )
            }

            let isBuiltinMode = bridgeMode == "builtin"
            let accountType = isBuiltinMode ? "builtin" : "personal"
            let r = queryResult
            Task.detached(priority: .background) {
                await APIClient.shared.recordLlmUsage(
                    inputTokens: r.inputTokens,
                    outputTokens: r.outputTokens,
                    cacheReadTokens: r.cacheReadTokens,
                    cacheWriteTokens: r.cacheWriteTokens,
                    totalTokens: r.inputTokens + r.outputTokens + r.cacheReadTokens + r.cacheWriteTokens,
                    costUsd: r.costUsd,
                    account: accountType
                )
            }
            sessionTokensUsed += queryResult.inputTokens + queryResult.outputTokens

            // Post-query: accumulate cost and check cap (builtin mode only)
            if isBuiltinMode {
                builtinCumulativeCostUsd += queryResult.costUsd
                if builtinCumulativeCostUsd >= Self.builtinCostCapUsd {
                    log("ChatProvider: Builtin cost cap reached after query ($\(String(format: "%.2f", builtinCumulativeCostUsd))) — switching to personal mode")
                    showCreditExhaustedAlert = true
                    AnalyticsManager.shared.creditExhausted(previousMode: bridgeMode)
                    await switchBridgeMode(to: "personal")
                }
            }

            // Fire-and-forget: check if user's message mentions goal progress
            let chatText = trimmedText
            Task.detached(priority: .background) {
                await GoalsAIService.shared.extractProgressFromAllGoals(text: chatText)
            }
        } catch {
            hadError = true

            // On timeout, cancel the stuck ACP session so it's not left dangling
            if let bridgeError = error as? BridgeError, case .timeout = bridgeError {
                log("ChatProvider: ACP query timed out, sending interrupt to cancel stuck session=\(effectiveKey)")
                if effectiveKey != "__default__" {
                    await acpBridge.interrupt(sessionKey: effectiveKey)
                } else {
                    await acpBridge.interrupt()
                }
                // Purge queued messages for the timed-out session — they are stale
                let timedOutKey = activeSessionKey
                let removedCount = pendingMessages.filter { $0.sessionKey == timedOutKey }.count
                pendingMessages.removeAll { $0.sessionKey == timedOutKey }
                if removedCount > 0 {
                    log("ChatProvider: purged \(removedCount) stale queued message(s) for session \(timedOutKey ?? "floating") after timeout")
                }
            }

            // Flush any remaining buffered streaming text before handling the error
            streamingFlushWorkItem?.cancel()
            streamingFlushWorkItem = nil
            flushStreamingBuffer()

            // Keep the AI message in the array (even if empty) so Combine subscribers
            // and handlePostQuery can find it. Removing it broke detached window error
            // handling because the $messages subscription guard (count > before) would fail.
            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                messages[index].isStreaming = false
                completeRemainingToolCalls(messageId: aiMessageId)
                await Task.yield()  // Let UI update immediately

                let partialText = messages[index].text
                if !partialText.isEmpty {
                    log("Bridge error after partial response — keeping \(partialText.count) chars of streamed text")
                    let partialToolMetadata = self.serializeToolCallMetadata(messageId: aiMessageId)
                    Task { [weak self] in
                        do {
                            let response = try await APIClient.shared.saveMessage(
                                text: partialText,
                                sender: "ai",
                                appId: capturedAppId,
                                sessionId: nil,
                                metadata: partialToolMetadata
                            )
                            await MainActor.run {
                                if let syncIndex = self?.messages.firstIndex(where: { $0.id == aiMessageId }) {
                                    self?.messages[syncIndex].id = response.id
                                    self?.messages[syncIndex].isSynced = true
                                }
                            }
                            log("Saved partial AI response to backend: \(response.id)")
                        } catch {
                            logError("Failed to persist partial AI response", error: error)
                        }
                    }
                }
            }

            let errorDurationMs = Int(Date().timeIntervalSince(queryStartTime) * 1000)
            let hadTokens = firstTokenTime != nil
            logError("Failed to get AI response (after \(errorDurationMs)ms, hadTokens=\(hadTokens), mode=\(bridgeMode))", error: error)
            AnalyticsManager.shared.chatAgentError(error: error.localizedDescription)

            // Show error to user (unless they intentionally stopped)
            if let bridgeError = error as? BridgeError, case .stopped = bridgeError {
                // User stopped — no error to show
            } else if let bridgeError = error as? BridgeError, case .creditExhausted(let rawMessage) = bridgeError {
                // Credits or rate limit exhausted — no retry possible, clear pending message
                // so handlePostQuery doesn't suppress the error thinking a retry is pending
                pendingRetryMessage = nil
                log("ChatProvider: credit/rate limit exhausted in \(bridgeMode) mode: \(rawMessage)")
                let isRateLimit = rawMessage.range(of: #"resets\s+\S"#, options: .regularExpression) != nil
                if bridgeMode == "builtin" && !isRateLimit {
                    // Actual credit exhaustion — auto-switch to personal mode
                    AnalyticsManager.shared.creditExhausted(previousMode: bridgeMode)
                    await switchBridgeMode(to: "personal")
                    showCreditExhaustedAlert = true
                    errorMessage = bridgeError.errorDescription
                } else if bridgeMode == "builtin" && isRateLimit {
                    // Temporary rate limit on builtin account — do NOT switch modes,
                    // user still has free trial budget remaining
                    errorMessage = bridgeError.errorDescription
                } else {
                    // Personal mode — user hit their own Claude rate limit.
                    errorMessage = bridgeError.errorDescription
                }
            } else if let bridgeError = error as? BridgeError,
                      case .agentError(let msg) = bridgeError,
                      Self.isTermsAcceptanceRequired(msg) {
                // Anthropic updated their T&S and the user hasn't accepted yet.
                // Show the actionable message directly — do NOT trigger re-auth flow.
                pendingRetryMessage = nil
                log("ChatProvider: terms acceptance required in \(bridgeMode) mode: \(msg)")
                errorMessage = bridgeError.errorDescription
            } else if bridgeMode == "builtin",
                      let bridgeError = error as? BridgeError,
                      case .agentError(let msg) = bridgeError,
                      Self.isAuthRelatedError(msg) {
                // Builtin API key auth failed — switch to personal mode and prompt sign-in
                log("ChatProvider: auth-related error in builtin mode, switching to personal: \(msg)")
                await switchBridgeMode(to: "personal")
                isClaudeAuthRequired = true
                errorMessage = nil
            } else if bridgeMode == "personal",
                      let bridgeError = error as? BridgeError,
                      case .agentError(let msg) = bridgeError,
                      Self.isAuthRelatedError(msg) {
                // Personal OAuth failed — re-trigger sign-in instead of "Something went wrong"
                log("ChatProvider: auth-related error in personal mode, re-triggering sign-in: \(msg)")
                isClaudeAuthRequired = true
                // Keep pendingRetryMessage so the query retries after auth
                errorMessage = nil
            } else if bridgeMode == "personal",
                      let bridgeError = error as? BridgeError,
                      case .agentError(let msg) = bridgeError,
                      Self.isModelAccessError(msg) {
                // Personal account can't access the model (e.g. CLI creds without claude-sonnet-4-6).
                // Fall back to builtin mode and auto-retry the query.
                log("ChatProvider: model access error in personal mode, falling back to builtin: \(msg)")
                pendingBridgeModeSwitch = "builtin"
                retryAfterModelFallback = true
                // pendingRetryMessage is already set from sendMessage() — keep it for auto-retry
                errorMessage = nil
            } else {
                pendingRetryMessage = nil
                errorMessage = error.localizedDescription
            }
        }

        let wasStopped = isStopping
        sendingSessionKeys.remove(effectiveKey)
        isSending = !sendingSessionKeys.isEmpty
        isStopping = false
        await applyPendingBridgeRestart()
        await applyPendingBridgeModeSwitch()

        // Auto-retry the failed query after a model access fallback (personal → builtin)
        if retryAfterModelFallback, let retryText = pendingRetryMessage {
            pendingRetryMessage = nil
            log("ChatProvider: auto-retrying query after model access fallback to builtin")
            await sendMessage(retryText)
            return
        }

        // If messages are queued, chain the next one as a follow-up query.
        // Skip chaining if the user explicitly stopped (queue stays visible for manual use)
        // or if an error occurred (stale messages should not replay).
        // However, if new messages were enqueued AFTER the user clicked Stop
        // (during the race window while the interrupt was being processed),
        // those should still be drained so the chat doesn't hang.
        if !hadError, !pendingMessages.isEmpty {
            // Only dequeue messages targeted at the session that just completed.
            // Other sessions' queued messages wait for their own session to be free,
            // enabling concurrent queries across pop-out windows.
            let matches: (Int) -> Bool = { [effectiveKey] idx in
                let key = self.pendingMessages[idx].sessionKey ?? "__default__"
                return key == effectiveKey
            }
            if wasStopped {
                let newMessageCount = pendingMessages.count - pendingCountAtStop
                if newMessageCount > 0 {
                    pendingMessages.removeFirst(pendingCountAtStop)
                    if let idx = pendingMessages.indices.first(where: matches) {
                        let next = pendingMessages.remove(at: idx)
                        log("ChatProvider: draining post-stop message for session=\(effectiveKey) (\(pendingMessages.count) remaining)")
                        NotificationCenter.default.post(name: .chatProviderDidDequeue, object: nil, userInfo: ["text": next.text, "sessionKey": next.sessionKey ?? ""])
                        await sendMessage(next.text, isFollowUp: next.userMessageAdded, sessionKey: next.sessionKey)
                    }
                }
            } else {
                if let idx = pendingMessages.indices.first(where: matches) {
                    let next = pendingMessages.remove(at: idx)
                    log("ChatProvider: chaining queued message for session=\(effectiveKey) (\(pendingMessages.count) remaining)")
                    NotificationCenter.default.post(name: .chatProviderDidDequeue, object: nil, userInfo: ["text": next.text, "sessionKey": next.sessionKey ?? ""])
                    await sendMessage(next.text, isFollowUp: next.userMessageAdded, sessionKey: next.sessionKey)
                }
            }
        }
        pendingCountAtStop = 0
    }

    /// Update message text (replaces entire text)
    private func updateMessage(id: String, text: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
        }
    }

    /// Append text to a streaming message via a buffer that flushes at ~100ms intervals.
    /// This reduces SwiftUI re-renders from once-per-token to ~10 times/second.
    private func appendToMessage(id: String, text: String) {
        streamingBufferMessageId = id
        streamingTextBuffer += text

        // Schedule a flush if one isn't already pending
        if streamingFlushWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushStreamingBuffer()
            }
            streamingFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + streamingFlushInterval, execute: workItem)
        }
    }

    /// Handle a text block boundary from the bridge. Flushes any buffered text
    /// so it lands in its own content block, then marks the next flush to create
    /// a new block rather than appending to the previous one.
    private func handleTextBlockBoundary(messageId: String) {
        if streamingBufferMessageId == messageId && !streamingTextBuffer.isEmpty {
            flushStreamingBuffer()
        }
        forceNewTextBlock = true
    }

    /// Flush accumulated text and thinking deltas to the published messages array.
    private func flushStreamingBuffer() {
        streamingFlushWorkItem = nil

        guard let id = streamingBufferMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            streamingTextBuffer = ""
            streamingThinkingBuffer = ""
            return
        }

        // Flush text buffer
        if !streamingTextBuffer.isEmpty {
            let buffered = streamingTextBuffer
            streamingTextBuffer = ""

            if !forceNewTextBlock,
               let lastBlockIndex = messages[index].contentBlocks.indices.last,
               case .text(let blockId, let existing) = messages[index].contentBlocks[lastBlockIndex] {
                messages[index].contentBlocks[lastBlockIndex] = .text(id: blockId, text: existing + buffered)
                messages[index].text += buffered
            } else {
                // Deduplicate: when the model repeats the same text after an
                // internal tool call (e.g. ToolSearch for deferred tool loading),
                // the second text block is identical to the last one. Skip it to
                // avoid showing the same message twice in the UI.
                let trimmed = buffered.trimmingCharacters(in: .whitespacesAndNewlines)
                let isDuplicate: Bool = {
                    // Find the last text block (may not be the very last block if tool calls are in between)
                    for block in messages[index].contentBlocks.reversed() {
                        if case .text(_, let existing) = block {
                            return existing.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
                        }
                    }
                    return false
                }()

                if isDuplicate {
                    // Skip the duplicate text block entirely
                } else {
                    messages[index].contentBlocks.append(.text(id: UUID().uuidString, text: buffered))
                    // Add separator to plain text when starting a new text block
                    // so copy-paste and fallback rendering have proper paragraph breaks
                    if !messages[index].text.isEmpty {
                        messages[index].text += "\n\n"
                    }
                    messages[index].text += buffered
                }
            }
            forceNewTextBlock = false
        }

        // Flush thinking buffer
        if !streamingThinkingBuffer.isEmpty {
            let buffered = streamingThinkingBuffer
            streamingThinkingBuffer = ""

            if let lastBlockIndex = messages[index].contentBlocks.indices.last,
               case .thinking(let thinkId, let existing) = messages[index].contentBlocks[lastBlockIndex] {
                messages[index].contentBlocks[lastBlockIndex] = .thinking(id: thinkId, text: existing + buffered)
            } else {
                messages[index].contentBlocks.append(.thinking(id: UUID().uuidString, text: buffered))
            }
        }
    }

    /// Add a tool call indicator to a streaming message
    /// Add a discovery card as a new standalone AI message so it doesn't attach to unrelated messages
    func appendDiscoveryCard(title: String, summary: String, fullText: String) {
        let cardBlock = ChatContentBlock.discoveryCard(id: UUID().uuidString, title: title, summary: summary, fullText: fullText)
        let message = ChatMessage(
            text: "",
            sender: .ai,
            contentBlocks: [cardBlock]
        )
        messages.append(message)
    }

    private func addToolActivity(messageId: String, toolName: String, status: ToolCallStatus, toolUseId: String? = nil, input: [String: Any]? = nil) {
        // Flush any buffered text/thinking BEFORE inserting the tool activity block.
        // Without this, text from before the tool call (e.g. "work!") and text from
        // after (e.g. "What are you working on?") get concatenated in the buffer
        // and rendered as one jammed block ("work!What are you working on?").
        if streamingBufferMessageId == messageId &&
            (!streamingTextBuffer.isEmpty || !streamingThinkingBuffer.isEmpty) {
            flushStreamingBuffer()
        }
        // Ensure text after the tool call starts a new content block, even if
        // the text_block_boundary message hasn't arrived yet.
        forceNewTextBlock = true

        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        let toolInput = input.flatMap { ChatContentBlock.toolInputSummary(for: toolName, input: $0) }

        if status == .running {
            // If we have a toolUseId and input, try to update an existing running block (input arrived after start)
            if let toolUseId = toolUseId, toolInput != nil {
                for i in stride(from: messages[index].contentBlocks.count - 1, through: 0, by: -1) {
                    if case .toolCall(let id, let name, let st, let existingTuid, _, let output) = messages[index].contentBlocks[i],
                       (existingTuid == toolUseId || (existingTuid == nil && name == toolName && st == .running)) {
                        messages[index].contentBlocks[i] = .toolCall(
                            id: id, name: name, status: st,
                            toolUseId: toolUseId, input: toolInput, output: output
                        )
                        return
                    }
                }
            }
            // No existing block to update — create a new one
            messages[index].contentBlocks.append(
                .toolCall(id: UUID().uuidString, name: toolName, status: .running,
                          toolUseId: toolUseId, input: toolInput)
            )
        } else {
            // Mark as completed — find by toolUseId first, fall back to name
            for i in stride(from: messages[index].contentBlocks.count - 1, through: 0, by: -1) {
                if case .toolCall(let id, let name, .running, let existingTuid, let existingInput, let output) = messages[index].contentBlocks[i] {
                    let matches = (toolUseId != nil && existingTuid == toolUseId) || (toolUseId == nil && name == toolName)
                    if matches {
                        messages[index].contentBlocks[i] = .toolCall(
                            id: id, name: name, status: .completed,
                            toolUseId: toolUseId ?? existingTuid,
                            input: toolInput ?? existingInput,
                            output: output
                        )
                        break
                    }
                }
            }
        }
    }

    /// Add tool result output to an existing tool call block
    private func addToolResult(messageId: String, toolUseId: String, name: String, output: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        for i in messages[index].contentBlocks.indices {
            if case .toolCall(let id, let blockName, let status, let tuid, let input, _) = messages[index].contentBlocks[i],
               (tuid == toolUseId || (tuid == nil && blockName == name)) {
                messages[index].contentBlocks[i] = .toolCall(
                    id: id, name: blockName, status: status,
                    toolUseId: toolUseId, input: input, output: output
                )
                return
            }
        }
    }

    // MARK: - Observer Cards

    /// Poll observer_activity table for pending cards, auto-accept them, and inject into the current chat.
    /// Cards are auto-accepted immediately — the user can deny/rollback if needed.
    private func pollChatObserverCards() {
        log("ChatProvider: pollChatObserverCards() called")
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
                log("ChatProvider: pollChatObserverCards — no database queue")
                return
            }
            do {
                let rows = try await dbQueue.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT id, type, content, status, createdAt
                        FROM observer_activity
                        WHERE status = 'pending'
                        ORDER BY createdAt ASC
                    """)
                }

                log("ChatProvider: pollChatObserverCards — found \(rows.count) pending cards")

                // Build all card blocks, then inject as a single stacked exchange
                var blocks: [ChatContentBlock] = []

                for row in rows {
                    let activityId: Int64 = row["id"]
                    let type: String = row["type"]
                    let contentJson: String = row["content"]

                    // Parse the content JSON for display text and buttons
                    var displayText = contentJson
                    var buttons: [ObserverCardButton] = []

                    if let jsonData = contentJson.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        displayText = (parsed["body"] as? String) ?? (parsed["message"] as? String) ?? (parsed["summary"] as? String) ?? contentJson
                        if let buttonDefs = parsed["buttons"] as? [[String: String]] {
                            buttons = buttonDefs.compactMap { def in
                                guard let label = def["label"], let action = def["action"] else { return nil }
                                return ObserverCardButton(id: "\(activityId)-\(action)", label: label, action: action)
                            }
                        }
                    }

                    // Only show Deny button — cards are auto-accepted
                    buttons = [
                        ObserverCardButton(id: "\(activityId)-dismiss", label: "Deny", action: "dismiss"),
                    ]

                    blocks.append(.observerCard(
                        id: "observer-\(activityId)",
                        activityId: activityId,
                        type: type,
                        content: displayText,
                        buttons: buttons,
                        actedAction: "approve"
                    ))

                    // Auto-accept: mark as acted with approve immediately
                    try await dbQueue.write { db in
                        try db.execute(sql: """
                            UPDATE observer_activity SET status = 'acted', userResponse = 'approve', actedAt = datetime('now')
                            WHERE id = ?
                        """, arguments: [activityId])
                    }

                    // Execute pending operations immediately (auto-accept)
                    await executeApprovedChatObserverOperations(activityId: activityId)

                    log("ChatProvider: Chat observer card auto-accepted — id=\(activityId) type=\(type)")
                    PostHogManager.shared.track("observer_card_shown", properties: [
                        "activity_id": activityId,
                        "card_type": type,
                        "content": displayText,
                        "auto_accepted": true,
                    ])
                    PostHogManager.shared.track("observer_card_action", properties: [
                        "activity_id": activityId,
                        "action": "approve",
                        "card_type": type,
                        "is_rollback": false,
                        "auto_accepted": true,
                        "content": displayText,
                    ])
                }

                guard !blocks.isEmpty else { return }

                // Inject all cards as a single grouped exchange
                await MainActor.run {
                    var chatObserverMsg = ChatMessage(text: "", sender: .ai)
                    chatObserverMsg.contentBlocks = blocks

                    if let barState = FloatingControlBarManager.shared.barState {
                        let exchange = FloatingChatExchange(question: "", aiMessage: chatObserverMsg)
                        if barState.currentAIMessage != nil || barState.isAILoading {
                            barState.pendingChatObserverExchanges.append(exchange)
                        } else {
                            barState.chatHistory.append(exchange)
                        }
                        if !barState.showingAIConversation {
                            barState.showingAIConversation = true
                            barState.showingAIResponse = true
                            barState.isAILoading = false
                        }
                    } else if !self.messages.isEmpty {
                        self.messages.append(chatObserverMsg)
                    }
                }
            } catch {
                log("ChatProvider: Failed to poll chat observer cards: \(error)")
            }
        }
    }

    /// Handle user action on a chat observer card (deny/rollback — cards are auto-accepted)
    func handleChatObserverCardAction(activityId: Int64, action: String) {
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
            do {
                // Cards are auto-accepted, so dismiss always means rollback
                let previousResponse: String? = try await dbQueue.read { db in
                    try String.fetchOne(db, sql: "SELECT userResponse FROM observer_activity WHERE id = ?", arguments: [activityId])
                }
                let isRollback = action == "dismiss" && previousResponse == "approve"

                let status = action == "approve" ? "acted" : "dismissed"
                try await dbQueue.write { db in
                    try db.execute(sql: """
                        UPDATE observer_activity SET status = ?, userResponse = ?, actedAt = datetime('now')
                        WHERE id = ?
                    """, arguments: [status, action, activityId])
                }
                log("ChatProvider: Chat observer card action — id=\(activityId) action=\(action)\(isRollback ? " (rollback)" : "")")

                // Track the user's response
                let cardRow: Row? = try await dbQueue.read { db in
                    try Row.fetchOne(db, sql: "SELECT type, content FROM observer_activity WHERE id = ?", arguments: [activityId])
                }
                let cardType: String = cardRow?["type"] ?? "unknown"
                let cardContent: String = cardRow?["content"] ?? ""
                var cardDisplayText = cardContent
                if let jsonData = cardContent.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    cardDisplayText = (parsed["body"] as? String) ?? (parsed["message"] as? String) ?? (parsed["summary"] as? String) ?? cardContent
                }
                PostHogManager.shared.track("observer_card_action", properties: [
                    "activity_id": activityId,
                    "action": action,
                    "card_type": cardType,
                    "is_rollback": isRollback,
                    "content": cardDisplayText,
                ])

                if isRollback {
                    // Roll back previously auto-accepted operations
                    await rollbackChatObserverOperations(activityId: activityId)
                }
            } catch {
                log("ChatProvider: Failed to update chat observer card: \(error)")
            }
        }
    }

    /// Execute pending operations from an auto-accepted chat observer card (writes, KG saves, skill drafts)
    private func executeApprovedChatObserverOperations(activityId: Int64) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            let row = try await dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT type, content FROM observer_activity WHERE id = ?", arguments: [activityId])
            }
            guard let contentJson: String = row?["content"],
                  let type: String = row?["type"],
                  let jsonData = contentJson.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                log("ChatProvider: Chat observer approve — no content for id=\(activityId)")
                return
            }

            if type == "skill_draft" {
                await createSkillFromChatObserverDraft(activityId: activityId)
                return
            }

            // Execute pending operations (SQL writes)
            if let operations = parsed["pending_operations"] as? [[String: Any]] {
                for op in operations {
                    guard let tool = op["tool"] as? String,
                          let opArgs = op["args"] as? [String: Any] else { continue }

                    if tool == "execute_sql", let query = opArgs["query"] as? String {
                        log("ChatProvider: Executing auto-accepted SQL: \(query.prefix(200))")
                        try await dbQueue.write { db in
                            try db.execute(sql: query)
                        }
                    }
                }
                log("ChatProvider: Executed \(operations.count) auto-accepted chat observer operations for id=\(activityId)")
            }
        } catch {
            log("ChatProvider: Failed to execute chat observer operations: \(error)")
        }
    }

    /// Create a skill file from an auto-accepted chat observer draft
    private func createSkillFromChatObserverDraft(activityId: Int64) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            let row = try await dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT content FROM observer_activity WHERE id = ?", arguments: [activityId])
            }
            guard let contentJson: String = row?["content"],
                  let jsonData = contentJson.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let draftSkill = parsed["draft_skill"] as? [String: Any],
                  let skillName = draftSkill["name"] as? String,
                  let skillContent = draftSkill["content"] as? String else {
                log("ChatProvider: Chat observer draft missing skill data for id=\(activityId)")
                return
            }

            // Write the skill file to ~/.claude/skills/{name}/SKILL.md
            let skillDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/skills/\(skillName)")
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillFile = skillDir.appendingPathComponent("SKILL.md")
            try skillContent.write(to: skillFile, atomically: true, encoding: .utf8)

            log("ChatProvider: Chat observer created skill at \(skillFile.path)")
        } catch {
            log("ChatProvider: Failed to create skill from chat observer draft: \(error)")
        }
    }

    /// Roll back previously auto-accepted chat observer operations (user clicked deny)
    private func rollbackChatObserverOperations(activityId: Int64) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            let row = try await dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT type, content FROM observer_activity WHERE id = ?", arguments: [activityId])
            }
            guard let contentJson: String = row?["content"],
                  let type: String = row?["type"],
                  let jsonData = contentJson.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                log("ChatProvider: Chat observer rollback — no content for id=\(activityId)")
                return
            }

            // Roll back skill drafts: delete the created skill file
            if type == "skill_draft" {
                if let draftSkill = parsed["draft_skill"] as? [String: Any],
                   let skillName = draftSkill["name"] as? String {
                    let skillDir = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".claude/skills/\(skillName)")
                    let skillFile = skillDir.appendingPathComponent("SKILL.md")
                    try? FileManager.default.removeItem(at: skillFile)
                    // Remove the directory if it's now empty
                    let contents = try? FileManager.default.contentsOfDirectory(atPath: skillDir.path)
                    if contents?.isEmpty == true {
                        try? FileManager.default.removeItem(at: skillDir)
                    }
                    log("ChatProvider: Rolled back chat observer skill draft — deleted \(skillFile.path)")
                }
                return
            }

            // Roll back pending SQL operations if rollback_operations are provided
            if let rollbackOps = parsed["rollback_operations"] as? [[String: Any]] {
                for op in rollbackOps {
                    if let tool = op["tool"] as? String, tool == "execute_sql",
                       let args = op["args"] as? [String: Any],
                       let query = args["query"] as? String {
                        log("ChatProvider: Executing chat observer rollback SQL: \(query.prefix(200))")
                        try await dbQueue.write { db in
                            try db.execute(sql: query)
                        }
                    }
                }
            }

            log("ChatProvider: Rolled back chat observer operations for id=\(activityId)")
        } catch {
            log("ChatProvider: Failed to rollback chat observer operations: \(error)")
        }
    }

    /// Log tool progress (elapsed time) — future: could update UI with timer display
    private func logToolProgress(toolUseId: String, toolName: String, elapsed: Double) {
        log("ChatProvider: Tool progress — \(toolName) (\(toolUseId)) elapsed \(String(format: "%.1f", elapsed))s")
    }

    /// Append thinking text to the streaming message via the shared buffer.
    private func appendThinking(messageId: String, text: String) {
        streamingBufferMessageId = messageId
        streamingThinkingBuffer += text

        // Schedule a flush if one isn't already pending
        if streamingFlushWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushStreamingBuffer()
            }
            streamingFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + streamingFlushInterval, execute: workItem)
        }
    }

    /// Mark any remaining `.running` tool call blocks as `.completed` in a message.
    /// Called when a query finishes (success or interrupt) so spinners don't spin forever.
    private func completeRemainingToolCalls(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        for i in messages[index].contentBlocks.indices {
            if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = messages[index].contentBlocks[i] {
                messages[index].contentBlocks[i] = .toolCall(
                    id: id, name: name, status: .completed,
                    toolUseId: toolUseId, input: input, output: output
                )
            }
        }
    }

    /// Serialize tool calls from a message's contentBlocks into a JSON metadata string.
    /// Returns nil if there are no tool calls.
    private func serializeToolCallMetadata(messageId: String) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return nil }

        var toolCalls: [[String: Any]] = []
        for block in messages[index].contentBlocks {
            if case .toolCall(_, let name, _, let toolUseId, let input, let output) = block {
                var call: [String: Any] = ["name": name]
                if let toolUseId = toolUseId { call["tool_use_id"] = toolUseId }
                if let input = input {
                    call["input_summary"] = input.summary
                    if let details = input.details { call["input"] = details }
                }
                if let output = output {
                    // Truncate large outputs to keep metadata reasonable
                    call["output"] = output.count > 500 ? String(output.prefix(500)) + "… (truncated)" : output
                }
                toolCalls.append(call)
            }
        }

        guard !toolCalls.isEmpty else { return nil }

        let metadata: [String: Any] = ["tool_calls": toolCalls]
        guard let data = try? JSONSerialization.data(withJSONObject: metadata),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - Message Rating

    /// Rate a message (thumbs up/down)
    /// - Parameters:
    ///   - messageId: The message ID to rate
    ///   - rating: 1 for thumbs up, -1 for thumbs down, nil to clear rating
    func rateMessage(_ messageId: String, rating: Int?) async {
        // Update local state immediately for responsive UI
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].rating = rating
        }

        // Persist to backend
        do {
            try await APIClient.shared.rateMessage(messageId: messageId, rating: rating)
            log("Rated message \(messageId) with rating: \(String(describing: rating))")

            // Track analytics
            if let rating = rating {
                AnalyticsManager.shared.messageRated(rating: rating)
            }
        } catch {
            logError("Failed to rate message", error: error)
            // Revert local state on failure
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].rating = nil
            }
        }
    }

    // MARK: - Clear Chat

    /// Clear chat messages
    func clearChat() async {
        isClearing = true
        defer { isClearing = false }

        messages = []
        log("Cleared default chat messages")
        Task {
            do {
                _ = try await APIClient.shared.deleteMessages(appId: selectedAppId)
            } catch {
                logError("Failed to clear default chat messages", error: error)
            }
        }

        log("Chat cleared")
        AnalyticsManager.shared.chatCleared()
    }

    // MARK: - App Selection

    /// Select a chat app and load its messages
    func selectApp(_ appId: String?) async {
        guard selectedAppId != appId else { return }
        selectedAppId = appId
        messages = []
        errorMessage = nil
        await loadDefaultChatMessages()
    }

}
