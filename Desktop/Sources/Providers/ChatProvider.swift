import SwiftUI
import Combine
import GRDB

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
}


// MARK: - Content Block Model

/// Structured tool input for inline display
struct ToolCallInput {
    /// Short summary for inline display (e.g., file path, command)
    let summary: String
    /// Full JSON details for expanded view
    let details: String?
}

/// Button for observer cards
struct ObserverCardButton: Identifiable {
    let id: String
    let label: String
    let action: String  // "approve", "dismiss", "edit"
}

/// A block of content within an AI message (text or tool call indicator)
enum ChatContentBlock: Identifiable {
    case text(id: String, text: String)
    case toolCall(id: String, name: String, status: ToolCallStatus,
                  toolUseId: String? = nil,
                  input: ToolCallInput? = nil,
                  output: String? = nil)
    case thinking(id: String, text: String)
    /// Collapsible card showing a summary with expandable full text (used for AI profile/discovery)
    case discoveryCard(id: String, title: String, summary: String, fullText: String)
    /// Observer session card — button-only inline element for user interaction
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
            summary = input["file_path"] as? String
        case "Write", "Edit":
            summary = input["file_path"] as? String
        case "Bash":
            if let cmd = input["command"] as? String {
                summary = cmd.count > 80 ? String(cmd.prefix(80)) + "…" : cmd
            } else {
                summary = nil
            }
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String
            summary = path != nil ? "\(pattern) in \(path!)" : pattern
        case "Glob":
            summary = input["pattern"] as? String
        case "WebSearch":
            summary = input["query"] as? String
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
            // Try common key names
            summary = (input["file_path"] ?? input["path"] ?? input["query"] ?? input["command"]) as? String
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
}

enum ToolCallStatus {
    case running
    case completed
}

// MARK: - Chat Message Model

/// A single chat message
struct ChatMessage: Identifiable {
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

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(), sender: ChatSender, isStreaming: Bool = false, rating: Int? = nil, isSynced: Bool = false, citations: [Citation] = [], contentBlocks: [ChatContentBlock] = []) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sender = sender
        self.isStreaming = isStreaming
        self.rating = rating
        self.isSynced = isSynced
        self.citations = citations
        self.contentBlocks = contentBlocks
    }
}

enum ChatSender {
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
    @Published var isStopping = false
    @Published var isClearing = false

    /// When a mode switch is requested while a query is in-flight (`isSending`),
    /// the target mode is stored here and applied after the query completes.
    private var pendingBridgeModeSwitch: String?
    @Published var errorMessage: String?
    @Published var showCreditExhaustedAlert = false
    /// True while the agent is compacting conversation context
    @Published var isCompacting = false

    /// Set to true during onboarding so the ACP session ID is persisted for restart recovery.
    var isOnboarding = false

    // MARK: - Floating Chat Session Persistence

    /// Per-mode UserDefaults key so sessions from one mode aren't mistakenly
    /// resumed by a different mode (builtin API key vs personal OAuth).
    private var floatingSessionIdKey: String { "floatingACPSessionId_\(bridgeMode)" }
    /// Maximum number of messages to restore from local DB on startup
    private static let floatingRestoreLimit = 50

    /// Whether we've already restored floating chat messages this session
    private var floatingChatRestored = false
    /// Saved ACP session ID for resuming the floating chat after restart
    private var pendingFloatingResume: String?
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
    /// Set by TaskChatCoordinator to point at the user's project directory.
    var workingDirectory: String?

    /// Override app ID for message routing (e.g. "task-chat" to isolate task messages).
    /// When set, messages are saved with this app_id so the backend routes them
    /// to the correct session instead of the default chat.
    var overrideAppId: String?

    /// Override the Claude model for this provider's queries.
    /// When set, the bridge uses this model instead of the default (Opus).
    /// e.g. "claude-sonnet-4-6" for faster floating bar responses.
    var modelOverride: String?

    /// Bridge mode: "personal" (user's Claude OAuth), "builtin" (Vertex AI built-in account)
    @AppStorage("bridgeMode") var bridgeMode: String = "builtin"

    // MARK: - Bridge (prefers user's Claude session, falls back to Vertex or bundled key)
    private lazy var acpBridge: ACPBridge = {
        return createBridge()
    }()
    private var acpBridgeStarted = false
    private var vertexTokenManager: VertexTokenManager?

    /// Whether the ACP bridge requires authentication (shown as sheet in UI)
    @Published var isClaudeAuthRequired = false
    @Published var claudeAuthTimedOut = false
    /// Auth methods returned by ACP bridge
    @Published var claudeAuthMethods: [[String: Any]] = []
    /// OAuth URL to open in browser (sent by bridge when auth is needed)
    @Published var claudeAuthUrl: String?
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
            // Fallback: try Vertex if bundled key is unavailable
            if vertexTokenManager != nil {
                let tmpDir = NSTemporaryDirectory()
                let adcPath = (tmpDir as NSString).appendingPathComponent("fazm-vertex-adc.json")
                let projectId = { if let p = getenv("VERTEX_PROJECT_ID") { return String(cString: p) } else { return "fazm-prod" } }()
                let region = { if let r = getenv("VERTEX_REGION") { return String(cString: r) } else { return "us-east5" } }()
                log("ChatProvider: Falling back to Vertex mode (ADC=\(adcPath))")
                return ACPBridge(mode: .vertex(adcFilePath: adcPath, projectId: projectId, region: region))
            }
            log("ChatProvider: No bundled key or Vertex available, falling back to personal OAuth")
            return ACPBridge(mode: .personalOAuth)
        } else {
            // Personal mode: always use OAuth
            log("ChatProvider: Using personal OAuth mode")
            return ACPBridge(mode: .personalOAuth)
        }
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

        // Tear down or set up vertex token manager
        if newMode == "builtin" {
            let vtm = VertexTokenManager()
            vertexTokenManager = vtm
            do {
                let config = try await vtm.setup()
                await vtm.startRefreshLoop()
                log("ChatProvider: Vertex token manager set up (project=\(config.projectId), region=\(config.region))")
            } catch {
                logError("ChatProvider: Vertex setup failed, falling back to API key", error: error)
            }
        } else {
            if let vtm = vertexTokenManager {
                await vtm.stop()
                vertexTokenManager = nil
            }
        }

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
        }
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
                    }
                },
                onAuthSuccess: { [weak self] in
                    Task { @MainActor in
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
                }
            )
        }
    }

    // MARK: - Cross-Platform Message Polling
    /// Polls for new messages from other platforms (mobile) every 15 seconds.
    /// Similar to TasksStore's 30-second polling pattern.
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
    private var cachedMemories: [ServerMemory] = []
    private var memoriesLoaded = false
    private var cachedGoals: [Goal] = []
    private var goalsLoaded = false
    private var cachedTasks: [TaskActionItem] = []
    private var tasksLoaded = false
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
        checkClaudeConnectionStatus(autoSwitchToPersonal: true)

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

        // Kill ACP bridge subprocess on app quit to prevent orphaned Node.js processes.
        // This runs synchronously (stop() is sync) to ensure cleanup completes before exit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let bridge = self.acpBridge
            Task.detached { await bridge.stop() }
        }
    }

    private var terminationObserver: NSObjectProtocol?

    /// Pre-start the active bridge so the first query doesn't wait for process launch
    func warmupBridge() async {
        _ = await ensureBridgeStarted()
    }

    /// Test that the Playwright Chrome extension is connected and working.
    /// Stops the bridge and restarts via `ensureBridgeStarted()` which does a full
    /// warmup with session resume, preserving conversation history across the setup flow.
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
        return try await acpBridge.testPlaywrightConnection()
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
        guard !acpBridgeStarted else { return true }

        // Ensure API keys are fetched before checking availability
        await KeyService.shared.ensureKeys()

        // Always set up Vertex token manager — Hindsight Memory MCP needs ADC
        // credentials for Gemini Pro via Vertex AI, regardless of chat mode.
        if vertexTokenManager == nil {
            let vtm = VertexTokenManager()
            if await vtm.isConfigured {
                do {
                    let config = try await vtm.setup()
                    vertexTokenManager = vtm
                    await vtm.startRefreshLoop()
                    log("ChatProvider: Vertex token manager set up (project=\(config.projectId), region=\(config.region))")
                    // If builtin mode with no Anthropic key, recreate bridge to use Vertex for chat too
                    if bridgeMode == "builtin" && (KeyService.shared.anthropicAPIKey ?? "").isEmpty {
                        acpBridge = createBridge()
                    }
                } catch {
                    logError("ChatProvider: Vertex setup failed on bridge start", error: error)
                }
            } else {
                log("ChatProvider: Vertex env vars not configured")
            }
        }

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
                    }
                },
                onAuthSuccess: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.isClaudeAuthRequired = false
                        self?.claudeAuthTimedOut = false
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
                }
            )
            // Set up observer poll handler — when the observer finishes a batch,
            // poll observer_activity for new pending cards and inject them into the chat
            await acpBridge.setObserverPollHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.pollObserverCards()
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
            // Pre-warm ACP sessions with their respective system prompts.
            // This is the only place the system prompt is built and applied.
            let mainSystemPrompt = buildSystemPrompt(contextString: formatMemoriesSection())
            cachedMainSystemPrompt = mainSystemPrompt
            let floatingSystemPrompt = Self.floatingBarSystemPromptPrefixCurrent + "\n\n" + mainSystemPrompt
            let savedFloatingSessionId = UserDefaults.standard.string(forKey: floatingSessionIdKey)
            let observerUserName = AuthService.shared.displayName.isEmpty ? "the user" : AuthService.shared.givenName
            let observerSystemPrompt = ChatPromptBuilder.buildObserverSession(
                userName: observerUserName,
                databaseSchema: cachedDatabaseSchema
            )
            await acpBridge.warmupSession(cwd: workingDirectory, sessions: [
                .init(key: "main", model: "claude-opus-4-6", systemPrompt: mainSystemPrompt),
                .init(key: "floating", model: "claude-opus-4-6", systemPrompt: floatingSystemPrompt, resume: savedFloatingSessionId),
                .init(key: "observer", model: "claude-opus-4-6", systemPrompt: observerSystemPrompt)
            ])
            // Resume is now handled at warmup — clear pendingFloatingResume so query() doesn't try again
            pendingFloatingResume = nil
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
        if key == "floating" {
            UserDefaults.standard.removeObject(forKey: floatingSessionIdKey)
            pendingFloatingResume = nil
            messages = []
            pendingMessages.removeAll()
        }
    }

    /// Start Claude OAuth authentication
    /// Opens the OAuth URL (provided by the bridge) in Chrome (where the user's sessions live).
    /// The bridge handles the full OAuth flow: local callback server, token exchange,
    /// credential storage, and ACP subprocess restart.
    func startClaudeAuth() {
        if let urlString = claudeAuthUrl, URL(string: urlString) != nil {
            log("ChatProvider: Opening Claude OAuth URL in Chrome")
            BrowserExtensionSetup.openURLInChrome(urlString)
        } else {
            // No auth URL yet — restart the bridge to trigger a fresh OAuth flow.
            // This happens when isClaudeAuthRequired was set by error-handling paths
            // (credit exhaustion, auth errors) without an active OAuth flow.
            log("ChatProvider: No auth URL available, restarting bridge to trigger OAuth")
            Task {
                acpBridgeStarted = false
                await acpBridge.stop()
                _ = await ensureBridgeStarted()
                // After restart, the bridge will fire auth_required with a URL,
                // which sets claudeAuthUrl and isClaudeAuthRequired via the handler.
                // The auth sheet will re-appear with a working Connect button.
            }
        }
    }

    /// Cancel the active Claude OAuth flow so the next attempt starts fresh
    func cancelClaudeAuth() {
        log("ChatProvider: Cancelling Claude OAuth")
        isClaudeAuthRequired = false
        claudeAuthUrl = nil
        Task {
            await acpBridge.cancelAuth()
        }
    }

    /// Retry Claude OAuth after a timeout by restarting the ACP bridge
    func retryClaudeAuth() {
        log("ChatProvider: Retrying Claude OAuth")
        claudeAuthTimedOut = false
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

    // MARK: - Load Context (Memories)

    /// Loads user memories from local SQLite for use in prompts
    private func loadMemoriesIfNeeded() async {
        guard !memoriesLoaded else { return }

        do {
            cachedMemories = try await MemoryStorage.shared.getLocalMemories(limit: 50)
            memoriesLoaded = true
            log("ChatProvider loaded \(cachedMemories.count) memories from local DB")
        } catch {
            logError("Failed to load memories from local DB", error: error)
            // Continue without memories - non-critical
        }
    }

    /// Formats cached memories into a string for the prompt
    private func formatMemoriesSection() -> String {
        guard !cachedMemories.isEmpty else { return "" }

        let userName = AuthService.shared.displayName.isEmpty ? "the user" : AuthService.shared.givenName

        var lines: [String] = ["<user_facts>", "Facts about \(userName):"]
        for memory in cachedMemories.prefix(30) {  // Limit to 30 most relevant
            lines.append("- \(memory.content)")
        }
        lines.append("</user_facts>")

        return lines.joined(separator: "\n")
    }

    // MARK: - Load Goals

    /// Loads user goals from local SQLite for use in prompts
    private func loadGoalsIfNeeded() async {
        guard !goalsLoaded else { return }

        do {
            cachedGoals = try await GoalStorage.shared.getLocalGoals(activeOnly: false)
            goalsLoaded = true
            log("ChatProvider loaded \(cachedGoals.count) goals from local DB")
        } catch {
            logError("Failed to load goals for chat context", error: error)
        }
    }

    /// Formats goals into a prompt section
    private func formatGoalSection() -> String {
        let activeGoals = cachedGoals.filter { $0.isActive }
        guard !activeGoals.isEmpty else { return "" }

        var lines: [String] = ["\n<user_goals>"]
        for goal in activeGoals {
            var line = "- \(goal.title)"
            if let desc = goal.description, !desc.isEmpty {
                line += ": \(desc)"
            }
            if goal.goalType != .boolean {
                line += " (progress: \(Int(goal.currentValue))/\(Int(goal.targetValue))"
                if let unit = goal.unit, !unit.isEmpty { line += " \(unit)" }
                line += ")"
            }
            lines.append(line)
        }
        lines.append("</user_goals>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Load Tasks

    /// Fetches the latest 20 active tasks from local database for context
    private func loadTasksIfNeeded() async {
        guard !tasksLoaded else { return }

        do {
            cachedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 20,
                completed: false
            )
            tasksLoaded = true
            log("ChatProvider loaded \(cachedTasks.count) tasks for context")
        } catch {
            logError("Failed to load tasks for chat context", error: error)
            tasksLoaded = true
        }
    }

    /// Formats cached tasks into a prompt section
    private func formatTasksSection() -> String {
        guard !cachedTasks.isEmpty else { return "" }

        var lines: [String] = ["\n<user_tasks>", "Current tasks:"]
        for task in cachedTasks {
            var line = "- \(task.description)"
            if let priority = task.priority {
                line += " [priority: \(priority)]"
            }
            if let dueAt = task.dueAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                line += " [due: \(formatter.string(from: dueAt))]"
            }
            if let category = task.category {
                line += " [category: \(category)]"
            }
            lines.append(line)
        }
        lines.append("</user_tasks>")
        return lines.joined(separator: "\n")
    }

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

        // Use the context string from backend (includes memories + conversations)
        // Fall back to just memories if context is empty
        let contextSection = contextString.isEmpty ? formatMemoriesSection() : contextString

        // Build individual sections
        let goalSection = formatGoalSection()
        let tasksSection = formatTasksSection()
        let aiProfileSection = formatAIProfileSection()

        // Build base prompt with goals, AI profile, and dynamic schema
        var prompt = ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            memoriesSection: contextSection,
            goalSection: goalSection,
            tasksSection: tasksSection,
            aiProfileSection: aiProfileSection,
            databaseSchema: cachedDatabaseSchema
        )

        // Inject conversation history so the new ACP session has context from before app launch.
        // The ACP SDK maintains history natively after this via session/prompt — this only matters
        // at session creation time.
        let history = buildConversationHistory()
        if !history.isEmpty {
            prompt += "\n\n<conversation_history>\nBelow is the recent conversation history between you and the user. Use this to maintain continuity — the user can see these messages in the chat UI and expects you to be aware of them.\n\(history)\n</conversation_history>"
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
        // dev-mode is included in the list when devModeEnabled; full content loaded on demand via load_skill
        let enabledSkillNames = getEnabledSkillNames()
        if !enabledSkillNames.isEmpty {
            let allSkills = discoveredSkills + projectDiscoveredSkills
            let skillNames = allSkills
                .filter { enabledSkillNames.contains($0.name) && ($0.name != "dev-mode" || devModeEnabled) }
                .map { $0.name }
                .joined(separator: ", ")
            if !skillNames.isEmpty {
                prompt += "\n\n<available_skills>\nAvailable skills: \(skillNames)\nUse the load_skill tool to get full instructions for any skill before using it.\n</available_skills>"
            }
        }

        // Log prompt context summary
        let activeGoalCount = cachedGoals.filter { $0.isActive }.count
        let historyInjected = !history.isEmpty
        let historyMessages = messages.filter { !$0.text.isEmpty && !$0.isStreaming }
        let historyCount = min(historyMessages.count, 20)
        log("ChatProvider: prompt built — schema: \(!cachedDatabaseSchema.isEmpty ? "yes" : "no"), goals: \(activeGoalCount), tasks: \(cachedTasks.count), ai_profile: \(!cachedAIProfile.isEmpty ? "yes" : "no"), memories: \(cachedMemories.count), history: \(historyInjected ? "injected (\(historyCount) msgs)" : "none"), claude_md: \(claudeMdEnabled && claudeMdContent != nil ? "yes" : "no"), project_claude_md: \(projectClaudeMdEnabled && projectClaudeMdContent != nil ? "yes" : "no"), skills: \(enabledSkillNames.count), dev_mode_in_skills: \(devModeEnabled && devModeContext != nil ? "yes" : "no"), prompt_length: \(prompt.count) chars")

        // Log per-section character breakdown
        let baseTemplate = ChatPromptBuilder.buildDesktopChat(
            userName: userName, memoriesSection: "", goalSection: "", tasksSection: "", aiProfileSection: "", databaseSchema: "")
        let allSkillsForSize = (discoveredSkills + projectDiscoveredSkills)
            .filter { enabledSkillNames.contains($0.name) && ($0.name != "dev-mode" || devModeEnabled) }
            .map { $0.name }.joined(separator: ", ")
        let skillsSectionSize = allSkillsForSize.isEmpty ? 0 : allSkillsForSize.count + 80 // names + wrapper
        log("ChatProvider: prompt breakdown — " +
            "base_template:\(baseTemplate.count)c, " +
            "context:\(contextSection.count)c, " +
            "goals:\(goalSection.count)c, " +
            "tasks:\(tasksSection.count)c, " +
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
        let contextSection = formatMemoriesSection()
        let goalSection = formatGoalSection()
        let tasksSection = formatTasksSection()
        let aiProfileSection = formatAIProfileSection()

        var prompt = ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            memoriesSection: contextSection,
            goalSection: goalSection,
            tasksSection: tasksSection,
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
                prompt += "\n\n<available_skills>\nAvailable skills: \(skillNames)\nUse the load_skill tool to get full instructions for any skill before using it.\n</available_skills>"
            }
        }

        log("ChatProvider: task chat prompt built — prompt_length: \(prompt.count) chars")
        return prompt
    }

    /// Builds system prompt using cached memories only (for simple messages)
    private func buildSystemPromptSimple() -> String {
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName
        let memoriesSection = formatMemoriesSection()

        return ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            memoriesSection: memoriesSection
        )
    }


    /// Formats the last 10 non-empty messages in the current session as a conversation history string.
    /// Used to seed new ACP sessions with context from the existing chat UI history.
    private func buildConversationHistory() -> String {
        let recent = messages.filter { !$0.text.isEmpty }.suffix(10)
        return recent.map { msg in
            let role = msg.sender == .user ? "User" : "Assistant"
            return "\(role): \(msg.text)"
        }.joined(separator: "\n")
    }

    /// Restore floating chat messages and session from local DB.
    /// Called lazily on the first floating bar interaction.
    func restoreFloatingChatIfNeeded() async {
        guard !floatingChatRestored else { return }
        floatingChatRestored = true

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
        await loadMemoriesIfNeeded()
        await loadGoalsIfNeeded()
        await loadTasksIfNeeded()
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
    private var pendingMessages: [(text: String, sessionKey: String?)] = []
    /// Read-only accessor for pending message texts (used by UI to sync deletions).
    var pendingMessageTexts: [String] { pendingMessages.map(\.text) }
    /// Session key of the currently running sendMessage call, so follow-ups can be chained on the same session.
    private var activeSessionKey: String?

    /// Stop the running agent, keeping partial response
    func stopAgent() {
        guard isSending else { return }
        isStopping = true
        Task {
            await acpBridge.interrupt()
        }
        // Result flows back normally through the bridge with partial text
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

    /// Enqueue a message to be sent after the current query finishes.
    /// Does NOT interrupt the current query — it will be picked up automatically.
    func enqueueMessage(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        pendingMessages.append((text: trimmedText, sessionKey: activeSessionKey))
        log("ChatProvider: message enqueued (\(pendingMessages.count) pending)")
    }

    /// Interrupt the current query and send a message immediately.
    /// The message jumps to the front of the queue.
    func interruptAndSend(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, isSending else { return }

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

        // Insert at front of queue and interrupt
        pendingMessages.insert((text: trimmedText, sessionKey: activeSessionKey), at: 0)
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

    // MARK: - Send Message

    /// Send a message and get AI response via Claude Agent SDK bridge
    /// Persists both user and AI messages to backend
    /// - Parameters:
    ///   - text: The message text
    ///   - model: Optional model override for this query (e.g. "claude-sonnet-4-6" for floating bar)
    func sendMessage(_ text: String, model: String? = nil, isFollowUp: Bool = false, systemPromptSuffix: String? = nil, systemPromptPrefix: String? = nil, sessionKey: String? = nil, resume: String? = nil) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Guard against concurrent sendMessage calls.
        // The bridge uses a single message continuation, so concurrent queries
        // would cause responses to be consumed by the wrong caller.
        guard !isSending else {
            log("ChatProvider: sendMessage called while already sending, ignoring")
            return
        }

        // Track the active session key so follow-ups can be chained on the same session
        activeSessionKey = sessionKey

        // Auto-resume floating chat session after app restart
        var resume = resume
        if sessionKey == "floating", resume == nil, let pendingResume = pendingFloatingResume {
            resume = pendingResume
            pendingFloatingResume = nil
            log("ChatProvider: Using saved floating session ID for resume: \(pendingResume)")
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
            return
        }

        isSending = true
        errorMessage = nil
        pendingRetryMessage = trimmedText

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

            let userMessage = ChatMessage(
                id: userMessageId,
                text: trimmedText,
                sender: .user
            )
            messages.append(userMessage)

            // Persist onboarding messages locally for restart recovery
            if isOnboarding {
                let msg = userMessage
                Task { await OnboardingChatPersistence.saveMessage(msg) }
            } else if sessionKey == "floating" {
                let msg = userMessage
                Task { await ChatMessageStore.saveMessage(msg, context: "__floating__") }
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
            isStreaming: true
        )
        messages.append(aiMessage)

        // Analytics: track timing and tool usage
        let queryStartTime = Date()
        var firstTokenTime: Date?
        var toolNames: [String] = []
        var toolStartTimes: [String: Date] = [:]
        var toolResults: [String: String] = [:]  // Track last result per tool for success/failure
        var activeBrowserToolCount = 0

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
                }
            }
            let toolCallHandler: ACPBridge.ToolCallHandler = { callId, name, input in
                let toolCall = ToolCall(name: name, arguments: input, thoughtSignature: nil)
                let result = await ChatToolExecutor.execute(toolCall)
                log("Fazm tool \(name) executed for callId=\(callId)")
                await MainActor.run { toolResults[name] = result }
                return result
            }
            let toolActivityHandler: ACPBridge.ToolActivityHandler = { [weak self] name, status, toolUseId, input in
                Task { @MainActor [weak self] in
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
                        if (name.contains("browser") || name.contains("playwright")) && !name.contains("setup_browser_extension") {
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
                        let isError = result?.hasPrefix("Error:") == true || result?.hasPrefix("error:") == true
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
                    // Detect browser extension disconnect mid-task and surface it clearly
                    let isBrowserTool = name.contains("browser") || name.contains("playwright")
                    let isDisconnected = output.contains("Extension connection timeout")
                        || output.contains("extension is not connected")
                    if isBrowserTool && isDisconnected && self?.stoppedForBrowserSetup != true {
                        log("ChatProvider: Browser extension disconnected mid-task (\(name)) — stopping and prompting setup")
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

            log("Chat query started (session=\(sessionKey ?? "main"), mode=\(bridgeMode), model=\(model ?? modelOverride ?? "default"))")
            let queryResult = try await acpBridge.query(
                prompt: trimmedText,
                systemPrompt: systemPrompt,
                sessionKey: isOnboarding ? "onboarding" : (sessionKey ?? "main"),
                cwd: workingDirectory,
                mode: chatMode.rawValue,
                model: model ?? modelOverride,
                resume: resume,
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
                            if active {
                                log("ChatProvider: Context compaction started")
                            } else {
                                log("ChatProvider: Context compaction finished")
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

                // Persist AI message locally for onboarding restart recovery
                // Must happen before backend save which replaces the message ID
                if isOnboarding, !messageText.isEmpty {
                    let msg = messages[index]
                    Task { await OnboardingChatPersistence.saveMessage(msg) }
                } else if sessionKey == "floating", !messageText.isEmpty {
                    let msg = messages[index]
                    Task { await ChatMessageStore.saveMessage(msg, context: "__floating__") }
                }
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
            isSending = false
            isStopping = false
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
                }
            }




            // Analytics: track query completion
            let durationMs = Int(Date().timeIntervalSince(queryStartTime) * 1000)
            let responseLength = messages.first(where: { $0.id == aiMessageId })?.text.count ?? 0
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
                ttftMs: firstTokenTime.map { Int($0.timeIntervalSince(queryStartTime) * 1000) }
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
            // On timeout, cancel the stuck ACP session so it's not left dangling
            if let bridgeError = error as? BridgeError, case .timeout = bridgeError {
                log("ChatProvider: ACP query timed out, sending interrupt to cancel stuck session")
                await acpBridge.interrupt()
            }

            // Flush any remaining buffered streaming text before handling the error
            streamingFlushWorkItem?.cancel()
            streamingFlushWorkItem = nil
            flushStreamingBuffer()

            // Only remove the AI message if it's still empty (no streamed text yet).
            // If text was already streamed and visible, keep it and just stop streaming.
            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                if messages[index].text.isEmpty && messages[index].contentBlocks.isEmpty {
                    messages.remove(at: index)
                } else {
                    messages[index].isStreaming = false
                    completeRemainingToolCalls(messageId: aiMessageId)
                    log("Bridge error after partial response — keeping \(messages[index].text.count) chars of streamed text")
                    // Still try to persist the partial response
                    let partialText = messages[index].text
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
                // Credits or rate limit exhausted
                log("ChatProvider: credit/rate limit exhausted in \(bridgeMode) mode: \(rawMessage)")
                AnalyticsManager.shared.creditExhausted(previousMode: bridgeMode)
                if bridgeMode == "builtin" {
                    // Built-in credits exhausted — auto-switch to personal mode
                    await switchBridgeMode(to: "personal")
                    showCreditExhaustedAlert = true
                    errorMessage = bridgeError.errorDescription
                } else {
                    // Personal mode — user hit their own Claude rate limit.
                    // Show a clear reset-time message instead of the auth sheet.
                    errorMessage = bridgeError.errorDescription
                }
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
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isSending = false
        isStopping = false
        await applyPendingBridgeModeSwitch()

        // If messages are queued, chain the next one as a follow-up query
        if !pendingMessages.isEmpty {
            let next = pendingMessages.removeFirst()
            log("ChatProvider: chaining queued message (\(pendingMessages.count) remaining)")
            // Notify UI to dequeue (posted on main actor)
            NotificationCenter.default.post(name: .chatProviderDidDequeue, object: nil, userInfo: ["text": next.text])
            await sendMessage(next.text, isFollowUp: true, sessionKey: next.sessionKey)
        }
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
                messages[index].contentBlocks.append(.text(id: UUID().uuidString, text: buffered))
                // Add separator to plain text when starting a new text block
                // so copy-paste and fallback rendering have proper paragraph breaks
                if !messages[index].text.isEmpty {
                    messages[index].text += "\n\n"
                }
                messages[index].text += buffered
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

    /// Poll observer_activity table for pending cards and inject them into the current chat
    private func pollObserverCards() {
        log("ChatProvider: pollObserverCards() called")
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
                log("ChatProvider: pollObserverCards — no database queue")
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

                log("ChatProvider: pollObserverCards — found \(rows.count) pending cards")

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

                    // Default buttons if none specified
                    if buttons.isEmpty {
                        if type == "skill_draft" {
                            buttons = [
                                ObserverCardButton(id: "\(activityId)-approve", label: "Create skill", action: "approve"),
                                ObserverCardButton(id: "\(activityId)-dismiss", label: "Skip", action: "dismiss"),
                            ]
                        } else if type == "approval_request" {
                            buttons = [
                                ObserverCardButton(id: "\(activityId)-approve", label: "Approve", action: "approve"),
                                ObserverCardButton(id: "\(activityId)-dismiss", label: "Reject", action: "dismiss"),
                            ]
                        } else if type == "insight" || type == "card" || type == "summary" || type == "kg_update" || type == "pattern" {
                            buttons = [
                                ObserverCardButton(id: "\(activityId)-approve", label: "OK", action: "approve"),
                                ObserverCardButton(id: "\(activityId)-dismiss", label: "Deny", action: "dismiss"),
                            ]
                        }
                    }

                    // Inject card as a standalone observer message in chat history
                    // so it persists even when the current AI response changes
                    let block = ChatContentBlock.observerCard(
                        id: "observer-\(activityId)",
                        activityId: activityId,
                        type: type,
                        content: displayText,
                        buttons: buttons
                    )

                    await MainActor.run {
                        var observerMsg = ChatMessage(text: displayText, sender: .ai)
                        observerMsg.contentBlocks = [block]

                        if let barState = FloatingControlBarManager.shared.barState {
                            let exchange = FloatingChatExchange(question: "", aiMessage: observerMsg)
                            // If a query is actively streaming, queue the card so it renders
                            // below the current response instead of above it.
                            if barState.currentAIMessage != nil || barState.isAILoading {
                                barState.pendingObserverExchanges.append(exchange)
                            } else {
                                barState.chatHistory.append(exchange)
                            }
                            // Make sure conversation is visible
                            if !barState.showingAIConversation {
                                barState.showingAIConversation = true
                                barState.showingAIResponse = true
                                barState.isAILoading = false
                            }
                        } else if !self.messages.isEmpty {
                            // Main chat — append as a standalone message
                            self.messages.append(observerMsg)
                        }
                    }

                    // Mark as shown
                    try await dbQueue.write { db in
                        try db.execute(sql: "UPDATE observer_activity SET status = 'shown' WHERE id = ?", arguments: [activityId])
                    }

                    log("ChatProvider: Observer card shown — id=\(activityId) type=\(type)")
                    PostHogManager.shared.track("observer_card_shown", properties: [
                        "activity_id": activityId,
                        "card_type": type,
                        "content_preview": String(displayText.prefix(500)),
                    ])
                }
            } catch {
                log("ChatProvider: Failed to poll observer cards: \(error)")
            }
        }
    }

    /// Handle user action on an observer card (approve, dismiss, edit)
    func handleObserverCardAction(activityId: Int64, action: String) {
        Task {
            guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
            do {
                try await dbQueue.write { db in
                    try db.execute(sql: """
                        UPDATE observer_activity SET status = 'acted', userResponse = ?, actedAt = datetime('now')
                        WHERE id = ?
                    """, arguments: [action, activityId])
                }
                log("ChatProvider: Observer card action — id=\(activityId) action=\(action)")

                // Track the user's response to the observer card
                // Fetch the card type for richer analytics
                let cardType: String? = try await dbQueue.read { db in
                    try String.fetchOne(db, sql: "SELECT type FROM observer_activity WHERE id = ?", arguments: [activityId])
                }
                PostHogManager.shared.track("observer_card_action", properties: [
                    "activity_id": activityId,
                    "action": action,
                    "card_type": cardType ?? "unknown",
                ])

                // Execute pending operations on approval
                if action == "approve" {
                    await executeApprovedObserverOperations(activityId: activityId)
                }
            } catch {
                log("ChatProvider: Failed to update observer card: \(error)")
            }
        }
    }

    /// Execute pending operations from an approved observer card (writes, KG saves, skill drafts)
    private func executeApprovedObserverOperations(activityId: Int64) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            let row = try await dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT type, content FROM observer_activity WHERE id = ?", arguments: [activityId])
            }
            guard let contentJson: String = row?["content"],
                  let type: String = row?["type"],
                  let jsonData = contentJson.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                log("ChatProvider: Observer approve — no content for id=\(activityId)")
                return
            }

            if type == "skill_draft" {
                await createSkillFromObserverDraft(activityId: activityId)
                return
            }

            // Execute pending operations (SQL writes)
            if let operations = parsed["pending_operations"] as? [[String: Any]] {
                for op in operations {
                    guard let tool = op["tool"] as? String,
                          let opArgs = op["args"] as? [String: Any] else { continue }

                    if tool == "execute_sql", let query = opArgs["query"] as? String {
                        log("ChatProvider: Executing approved SQL: \(query.prefix(200))")
                        try await dbQueue.write { db in
                            try db.execute(sql: query)
                        }
                    }
                }
                log("ChatProvider: Executed \(operations.count) approved observer operations for id=\(activityId)")
            }
        } catch {
            log("ChatProvider: Failed to execute approved observer operations: \(error)")
        }
    }

    /// Create a skill file from an approved observer draft
    private func createSkillFromObserverDraft(activityId: Int64) async {
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
                log("ChatProvider: Observer draft missing skill data for id=\(activityId)")
                return
            }

            // Write the skill file to ~/.claude/skills/{name}/SKILL.md
            let skillDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/skills/\(skillName)")
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillFile = skillDir.appendingPathComponent("SKILL.md")
            try skillContent.write(to: skillFile, atomically: true, encoding: .utf8)

            log("ChatProvider: Observer created skill at \(skillFile.path)")
        } catch {
            log("ChatProvider: Failed to create skill from observer draft: \(error)")
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
