import Foundation

/// Thread-safe box for a continuation that can be resumed synchronously from any context
/// (including `withTaskCancellationHandler`'s `onCancel` which runs on an arbitrary thread).
/// This avoids the race where `Task { await actor.method() }` in onCancel never executes
/// because the actor is being deallocated during autorelease pool drain.
private final class ContinuationBox<T, E: Error>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, E>?
  private var generation: UInt64 = 0

  /// Store a continuation with its generation token.
  func store(_ c: CheckedContinuation<T, E>, generation g: UInt64) {
    lock.lock()
    continuation = c
    generation = g
    lock.unlock()
  }

  /// Resume and clear the continuation if it matches the expected generation.
  /// Returns true if it was resumed.
  @discardableResult
  func resume(throwing error: E, ifGeneration expected: UInt64) -> Bool {
    lock.lock()
    guard generation == expected, let c = continuation else {
      lock.unlock()
      return false
    }
    continuation = nil
    lock.unlock()
    c.resume(throwing: error)
    return true
  }

  /// Resume and clear the continuation unconditionally (for deinit / stop).
  /// Returns true if there was a pending continuation.
  @discardableResult
  func resumeAny(throwing error: E) -> Bool {
    lock.lock()
    guard let c = continuation else {
      lock.unlock()
      return false
    }
    continuation = nil
    lock.unlock()
    c.resume(throwing: error)
    return true
  }

  /// Resume with a value if a continuation is pending. Returns true if resumed.
  @discardableResult
  func resume(returning value: T) -> Bool {
    lock.lock()
    guard let c = continuation else {
      lock.unlock()
      return false
    }
    continuation = nil
    lock.unlock()
    c.resume(returning: value)
    return true
  }

  /// Check if a continuation is currently pending.
  var isPending: Bool {
    lock.lock()
    let pending = continuation != nil
    lock.unlock()
    return pending
  }

  /// Check if pending and matches generation.
  func isPending(generation expected: UInt64) -> Bool {
    lock.lock()
    let match = continuation != nil && generation == expected
    lock.unlock()
    return match
  }

  /// Clear without resuming (only for when generation has already moved on).
  func clear(ifGeneration expected: UInt64) {
    lock.lock()
    if generation == expected {
      continuation = nil
    }
    lock.unlock()
  }
}

/// Manages a long-lived Node.js subprocess running the ACP (Agent Client Protocol) bridge.
/// Supports two modes: bundled Anthropic API key or user's personal OAuth.
/// Communication uses JSON lines over stdin/stdout pipes.
actor ACPBridge {

  // MARK: - Types

  /// Result from a query
  struct QueryResult {
    let text: String
    let costUsd: Double
    let sessionId: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
  }

  /// Callback for streaming text deltas
  typealias TextDeltaHandler = @Sendable (String) -> Void

  /// Callback for Fazm tool calls that need Swift execution
  typealias ToolCallHandler = @Sendable (String, String, [String: Any]) async -> String

  /// Callback for tool activity events (name, status, toolUseId?, input?)
  typealias ToolActivityHandler = @Sendable (String, String, String?, [String: Any]?) -> Void

  /// Callback for thinking text deltas
  typealias ThinkingDeltaHandler = @Sendable (String) -> Void

  /// Callback for text block boundary (new content block from API)
  typealias TextBlockBoundaryHandler = @Sendable () -> Void

  /// Callback for tool result display (toolUseId, name, output)
  typealias ToolResultDisplayHandler = @Sendable (String, String, String) -> Void

  /// Callback for auth required events (methods array, optional auth URL)
  typealias AuthRequiredHandler = @Sendable ([[String: Any]], String?) -> Void

  /// Callback for auth success
  typealias AuthSuccessHandler = @Sendable () -> Void

  /// Callback for auth timeout (reason string)
  typealias AuthTimeoutHandler = @Sendable (String) -> Void

  /// Callback for auth failed (reason string, HTTP status code)
  typealias AuthFailedHandler = @Sendable (String, Int?) -> Void

  /// Status events forwarded from the ACP SDK (compaction, tasks, tool progress)
  enum StatusEvent: Sendable {
    /// Agent is compacting context (true) or finished compacting (false)
    case compacting(Bool)
    /// Compaction boundary with token count before compaction
    case compactBoundary(trigger: String, preTokens: Int)
    /// Sub-task/agent started
    case taskStarted(taskId: String, description: String)
    /// Sub-task/agent completed/failed/stopped
    case taskNotification(taskId: String, status: String, summary: String)
    /// Tool execution progress (elapsed time)
    case toolProgress(toolUseId: String, toolName: String, elapsedTimeSeconds: Double)
    /// Collapsed summary of multiple tool calls
    case toolUseSummary(summary: String)
    /// Rate limit info from Claude API (utilization warnings & rejections)
    case rateLimit(status: String, resetsAt: Double?, rateLimitType: String?, utilization: Double?)
    /// Session/resume failed upstream — bridge created a fresh session in its place.
    /// `contextRestored` is true when the bridge was able to replay local history.
    case sessionExpired(oldSessionId: String, newSessionId: String, contextRestored: Bool, restoredMessageCount: Int, reason: String)
    /// Tool-timeout watchdog auto-canceled the in-flight ACP session. Surfaces
    /// the cancellation as a structured event so the UI can show a system card
    /// (instead of an opaque silence after the tool's `tool_result_display` error).
    case toolHangCanceled(toolName: String, toolUseId: String, durationSeconds: Double, reason: String)
    /// New ACP session was created (`isResume == false`) or resumed (`isResume == true`).
    /// Fires BEFORE the first prompt notification, so the client can persist the
    /// sessionId immediately. Without this, errors mid-stream (rate limit, credit
    /// exhausted, network) lose the conversation because sessionId was only saved on
    /// the success path. See ChatProvider.onStatusEvent for the persistence wiring.
    case sessionStarted(sessionId: String, sessionKey: String?, isResume: Bool)
  }

  /// Callback for status events (compaction, tasks, tool progress)
  typealias StatusEventHandler = @Sendable (StatusEvent) -> Void

  /// Inbound message types (Bridge → Swift, read from stdout)
  private enum InboundMessage {
    case `init`(sessionId: String)
    case textDelta(text: String)
    case thinkingDelta(text: String)
    case textBlockBoundary
    case toolUse(callId: String, name: String, input: [String: Any])
    case toolActivity(name: String, status: String, toolUseId: String?, input: [String: Any]?)
    case toolResultDisplay(toolUseId: String, name: String, output: String)
    case result(
      text: String, sessionId: String, costUsd: Double?, inputTokens: Int, outputTokens: Int,
      cacheReadTokens: Int, cacheWriteTokens: Int)
    case error(message: String)
    case authRequired(methods: [[String: Any]], authUrl: String?)
    case authSuccess
    case authTimeout(reason: String)
    case authFailed(reason: String, httpStatus: Int?)
    case creditExhausted(message: String)
    /// Built-in (bundled API key) mode failed authentication. Bridge is signaling
    /// that the key may have been rotated or revoked. ChatProvider should refetch
    /// from `/v1/keys`, restart the bridge, and silently retry — NOT trigger OAuth.
    case builtinKeyInvalid(message: String)
    case statusChange(status: String?)
    case compactBoundary(trigger: String, preTokens: Int)
    case taskStarted(taskId: String, description: String)
    case taskNotification(taskId: String, status: String, summary: String)
    case toolProgress(toolUseId: String, toolName: String, elapsedTimeSeconds: Double)
    case toolUseSummary(summary: String)
    case rateLimit(status: String, resetsAt: Double?, rateLimitType: String?, utilization: Double?, overageStatus: String?, overageDisabledReason: String?)
    case apiRetry(httpStatus: Int?, errorType: String, attempt: Int, maxRetries: Int)
    case observerPoll
    case observerStatus(running: Bool)
    case modelsAvailable(models: [[String: Any]])
    case mcpServersAvailable(servers: [[String: Any]])
    case sessionExpired(oldSessionId: String, newSessionId: String, contextRestored: Bool, restoredMessageCount: Int, reason: String, sessionKey: String?)
    case toolHangCanceled(toolName: String, toolUseId: String, durationSeconds: Double, reason: String, sessionKey: String?)
    case sessionStarted(sessionId: String, sessionKey: String?, isResume: Bool)
    /// Emitted by the bridge once `preWarmSession` resolves (success or failure).
    /// Pairs with `bridge_warmup_started` (fired in Swift right before `ensureBridgeStarted()`)
    /// so we can compute the cold-start window in PostHog and confirm/refute the
    /// warmup-race hypothesis (user types before warmup is done → pre_response failure).
    case warmupComplete(durationMs: Double, sessionKeys: [String], ok: Bool, error: String?)
    case codexProbeResult(ok: Bool, agent: String?, authMethods: [String], currentModelId: String?, availableModels: [[String: Any]], authMode: String, error: String?)
    case codexLoginUrl(url: String)
    case codexLoginComplete
    case codexLoginError(error: String)
  }

  // MARK: - Configuration

  /// How the bridge authenticates with Claude
  enum BridgeMode {
    /// User's own Claude account via OAuth (strip API key)
    case personalOAuth
    /// Bundled Anthropic API key (direct API, fastest)
    case bundledKey(apiKey: String)

    var isPersonalOAuth: Bool {
      if case .personalOAuth = self { return true }
      return false
    }
  }

  let mode: BridgeMode

  /// Persistent auth handler called whenever auth_required arrives (even outside query)
  var onAuthRequiredGlobal: AuthRequiredHandler?
  /// Persistent auth success handler called whenever auth_success arrives (even outside query)
  var onAuthSuccessGlobal: AuthSuccessHandler?
  /// Persistent auth timeout handler called whenever auth_timeout arrives (even outside query)
  var onAuthTimeoutGlobal: AuthTimeoutHandler?
  /// Persistent auth failed handler called when token exchange is rejected (e.g. 403)
  var onAuthFailedGlobal: AuthFailedHandler?
  /// Called when the chat observer session completes a batch and new cards may be available
  var onChatObserverPoll: (() -> Void)?
  /// Called when the chat observer starts or stops processing a batch
  var onChatObserverStatusChange: ((_ running: Bool) -> Void)?
  /// Called when the ACP SDK reports available models (after session/new)
  var onModelsAvailable: ((_ models: [(modelId: String, name: String, description: String?)]) -> Void)?
  /// Called when the bridge reports codex_probe_result (Codex backend reachability + auth state)
  var onCodexProbeResult: ((_ ok: Bool, _ agent: String?, _ authMethods: [String], _ currentModelId: String?, _ availableModels: [[String: Any]], _ authMode: String, _ error: String?) -> Void)?
  /// Called when the bridge starts the Codex OAuth flow and needs the browser opened
  var onCodexLoginUrl: ((_ url: String) -> Void)?
  /// Called when Codex OAuth flow completes and auth.json has been written
  var onCodexLoginComplete: (() -> Void)?
  /// Called when Codex OAuth flow fails
  var onCodexLoginError: ((_ error: String) -> Void)?
  /// Global tool call handler for background sessions (chat observer) — processes tool_use even when no query is active
  var onBackgroundToolCall: ToolCallHandler?

  func setChatObserverPollHandler(_ handler: @escaping @Sendable () -> Void) {
    self.onChatObserverPoll = handler
  }

  func setChatObserverStatusHandler(_ handler: @escaping @Sendable (_ running: Bool) -> Void) {
    self.onChatObserverStatusChange = handler
  }

  func setModelsAvailableHandler(_ handler: @escaping @Sendable (_ models: [(modelId: String, name: String, description: String?)]) -> Void) {
    self.onModelsAvailable = handler
  }

  func setCodexProbeResultHandler(_ handler: @escaping @Sendable (_ ok: Bool, _ agent: String?, _ authMethods: [String], _ currentModelId: String?, _ availableModels: [[String: Any]], _ authMode: String, _ error: String?) -> Void) {
    self.onCodexProbeResult = handler
  }

  func setCodexLoginHandlers(
    onUrl: @escaping @Sendable (_ url: String) -> Void,
    onComplete: @escaping @Sendable () -> Void,
    onError: @escaping @Sendable (_ error: String) -> Void
  ) {
    self.onCodexLoginUrl = onUrl
    self.onCodexLoginComplete = onComplete
    self.onCodexLoginError = onError
  }

  func setBackgroundToolCallHandler(_ handler: @escaping ToolCallHandler) {
    self.onBackgroundToolCall = handler
  }

  func setGlobalAuthHandlers(
    onAuthRequired: AuthRequiredHandler?,
    onAuthSuccess: AuthSuccessHandler?,
    onAuthTimeout: AuthTimeoutHandler? = nil,
    onAuthFailed: AuthFailedHandler? = nil
  ) {
    self.onAuthRequiredGlobal = onAuthRequired
    self.onAuthSuccessGlobal = onAuthSuccess
    self.onAuthTimeoutGlobal = onAuthTimeout
    self.onAuthFailedGlobal = onAuthFailed
  }

  init(mode: BridgeMode = .personalOAuth) {
    self.mode = mode
  }

  // MARK: - State

  private var process: Process?
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var isRunning = false
  private var readTask: Task<Void, Never>?
  /// Incremented each time start() is called; stale termination handlers check this
  private var processGeneration: UInt64 = 0

  /// Pending messages from the bridge (legacy, for messages without sessionKey)
  private var pendingMessages: [InboundMessage] = []
  /// Lock-protected continuation box: can be resumed synchronously from onCancel without actor hop.
  /// Legacy: used for messages without sessionKey or when no per-session box exists.
  private let continuationBox = ContinuationBox<InboundMessage, Error>()
  private var messageGeneration: UInt64 = 0

  /// Per-session continuation boxes for concurrent query support
  private var sessionContinuations: [String: ContinuationBox<InboundMessage, Error>] = [:]
  /// Per-session pending message queues
  private var sessionPendingMessages: [String: [InboundMessage]] = [:]
  /// Per-session message generations (for timeout tracking)
  private var sessionMessageGenerations: [String: UInt64] = [:]
  /// Per-session interrupt flags
  private var sessionInterrupted: [String: Bool] = [:]
  /// Per-session ACP tool counts (for timeout deferral)
  private var sessionAcpToolsRunning: [String: Int] = [:]
  /// Reverse map: ACP sessionId → sessionKey. Populated from session_started
  /// and session_expired events. Used as a routing fallback in deliverMessage
  /// when an inbound message (typically a cancellation `result`) arrives
  /// without a sessionKey field — usually because the bridge unregistered the
  /// session before emitting the catch-block result. Without this fallback the
  /// per-pop-out continuation never resumes and the loading spinner spins for
  /// the full inactivity timeout (currently 600s, up to 6× deferred while tools run).
  private var sessionIdToKey: [String: String] = [:]

  /// Set when stderr indicates OOM so handleTermination can throw the right error
  private var lastExitWasOOM = false
  /// Set when interrupt() is called so query() can skip remaining tool calls (legacy, for non-session queries)
  private var isInterrupted = false
  /// Counts ACP tools currently running (incremented on "Tool started", decremented on "Tool completed").
  /// Used by waitForMessage to avoid timing out while ACP tools are actively executing. (legacy)
  private var acpToolsRunning: Int = 0
  /// Timestamp of the most recent Tool started/completed event from ACP stderr.
  /// The deferral logic in waitForMessage uses a sliding activity window (toolActivityWindow)
  /// in addition to the instantaneous count, so a brief gap between two tool calls
  /// (count momentarily 0) doesn't trip a premature timeout.
  private var lastToolActivityAt: Date?
  /// How recently a tool start/complete must have happened to keep deferring the timeout.
  /// 60s is comfortably longer than the typical inter-tool gap but well short of the 600s
  /// inactivity timeout, so genuine stalls still terminate.
  private let toolActivityWindow: TimeInterval = 60

  /// Whether the bridge subprocess is alive and ready
  var isAlive: Bool { isRunning }

  deinit {
    // Resume any pending continuation to prevent "SWIFT TASK CONTINUATION MISUSE" crash.
    // The lock-protected box is safe to access from deinit (no actor hop needed).
    continuationBox.resumeAny(throwing: BridgeError.stopped)
    for (_, box) in sessionContinuations {
      box.resumeAny(throwing: BridgeError.stopped)
    }
  }

  // MARK: - Lifecycle

  /// Start the Node.js ACP bridge process
  func start() async throws {
    guard !isRunning else { return }

    // Clean up any leftover state from a previous crashed process
    readTask?.cancel()
    readTask = nil
    process = nil
    closePipes()
    pendingMessages.removeAll()
    continuationBox.resumeAny(throwing: BridgeError.stopped)
    lastExitWasOOM = false

    // Sweep any orphaned bridge / ACP / codex-acp processes left over from prior
    // app runs that crashed without graceful shutdown. Each orphan can hold ~600MB
    // of `claude` CLI + MCP servers, so this is critical hygiene before launching
    // a new bridge. Belt-and-suspenders alongside the in-bridge PPID watchdog.
    Self.sweepOrphanedBridges()

    let nodePath = findNodeBinary()
    guard let nodePath else {
      throw BridgeError.nodeNotFound
    }

    let bridgePath = findBridgeScript()
    guard let bridgePath else {
      throw BridgeError.bridgeScriptNotFound
    }

    let nodeExists = FileManager.default.isExecutableFile(atPath: nodePath)
    let bridgeExists = FileManager.default.fileExists(atPath: bridgePath)
    let bridgeDir = (bridgePath as NSString).deletingLastPathComponent
    let pkgJsonPath = ((bridgeDir as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent("package.json")
    let pkgJsonExists = FileManager.default.fileExists(atPath: pkgJsonPath)
    log(
      "ACPBridge: starting with node=\(nodePath) (exists=\(nodeExists)), bridge=\(bridgePath) (exists=\(bridgeExists)), package.json=\(pkgJsonExists)"
    )

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: nodePath)
    proc.arguments = ["--max-old-space-size=256", "--max-semi-space-size=16", bridgePath]

    // Pin the bridge's working directory to the user's home, not whatever cwd
    // LaunchServices handed us (often /private/var/folders/... when launched from
    // Finder or LaunchAgent). Without this, `process.cwd()` inside the Node bridge
    // becomes a temp dir, which then leaks through as the chat workspace whenever
    // the Swift side sends a nil/empty cwd (new chat, no inherited workspace).
    proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

    // Build environment based on auth mode
    var env = ProcessInfo.processInfo.environment
    env["NODE_NO_WARNINGS"] = "1"
    switch mode {
    case .personalOAuth:
      env.removeValue(forKey: "ANTHROPIC_API_KEY")
    case .bundledKey(let apiKey):
      env["ANTHROPIC_API_KEY"] = apiKey
    }

    // Ensure the directory containing node is in PATH
    let nodeDir = (nodePath as NSString).deletingLastPathComponent
    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
    if !existingPath.contains(nodeDir) {
      env["PATH"] = "\(nodeDir):\(existingPath)"
    }

    // Voice Response (TTS) toggle
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "voiceResponseEnabled") {
      env["FAZM_VOICE_RESPONSE"] = "true"
    }

    // Playwright MCP extension mode
    let useExtension =
      defaults.object(forKey: "playwrightUseExtension") == nil
      || defaults.bool(forKey: "playwrightUseExtension")
    if useExtension {
      env["PLAYWRIGHT_USE_EXTENSION"] = "true"
      if let token = defaults.string(forKey: "playwrightExtensionToken"), !token.isEmpty {
        env["PLAYWRIGHT_MCP_EXTENSION_TOKEN"] = token
      }
    }

    // Custom API endpoint (allows proxying through Copilot, corporate gateways, etc.)
    if let customEndpoint = defaults.string(forKey: "customApiEndpoint"), !customEndpoint.isEmpty {
      env["ANTHROPIC_BASE_URL"] = customEndpoint
    }

    // Tool timeout override (user-configurable in Settings > Advanced)
    let toolTimeout = defaults.integer(forKey: "toolTimeoutSeconds")
    if toolTimeout > 0 {
      env["FAZM_TOOL_TIMEOUT_SECONDS"] = String(toolTimeout)
    }

    // Pass app bundle path so acp-bridge can find bundled binaries/resources
    // (Node may run from /tmp due to NodeBinaryHelper, so process.execPath is unreliable)
    if let resourcePath = Bundle.main.resourcePath {
      env["FAZM_RESOURCES_PATH"] = resourcePath
    }

    proc.environment = env

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()

    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = stderr

    self.stdinPipe = stdin
    self.stdoutPipe = stdout
    self.stderrPipe = stderr
    self.process = proc

    // Read stderr for logging and OOM detection
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tool timeouts are real anomalies — capture in Sentry as errors, not just breadcrumbs
        if text.contains("Tool TIMEOUT") {
          logError("ACPBridge stderr: \(trimmed)")
        } else {
          log("ACPBridge stderr: \(trimmed)")
        }
        // Track ACP tool activity so waitForMessage doesn't time out
        // while tools are actively running inside ACP (Terminal, text_editor, etc.)
        if text.contains("Tool started") {
          Task { await self?.adjustAcpToolCount(delta: 1) }
        } else if text.contains("Tool completed") {
          Task { await self?.adjustAcpToolCount(delta: -1) }
        }
        if text.contains("FatalProcessOutOfMemory")
          || text.contains("JavaScript heap out of memory")
          || text.contains("Failed to reserve virtual memory")
          || text.contains("out of memory")
        {
          Task { await self?.markOOM() }
        }
      }
    }

    // Bump generation so stale termination handlers from previous processes are ignored
    processGeneration &+= 1
    let expectedGeneration = processGeneration

    proc.terminationHandler = { [weak self] terminatedProc in
      let code = terminatedProc.terminationStatus
      let reason = terminatedProc.terminationReason
      Task { [weak self] in
        await self?.handleTermination(
          exitCode: code, reason: reason, generation: expectedGeneration)
      }
    }

    try proc.run()
    isRunning = true
    log("ACPBridge: bridge process started (pid=\(proc.processIdentifier))")

    // Start reading stdout
    startReadingStdout()

    // Wait for the initial "init" message indicating bridge is ready
    let initMsg = try await waitForMessage(timeout: 30.0)
    if case .`init`(let sessionId) = initMsg {
      log("ACPBridge: bridge ready (sessionId=\(sessionId))")
    }
  }

  /// Restart the bridge process (stop then start)
  func restart() async throws {
    stop()
    try await start()
  }

  /// Stop the bridge process and all its child processes (MCP servers, etc.)
  func stop() {
    log("ACPBridge: stopping")
    readTask?.cancel()
    readTask = nil

    sendLine(
      """
      {"type":"stop"}
      """)
    try? stdinPipe?.fileHandleForWriting.close()

    // Kill all descendant processes recursively. The bridge spawns ACP which spawns
    // MCP servers (playwright, google-workspace, macos-use, whatsapp).
    // The ACP subprocess creates its own process group, so kill(-pid) only reaches
    // direct children — grandchildren (MCP servers) survive and become orphans.
    // We must walk the full process tree and kill every descendant.
    if let proc = process, proc.isRunning {
      let pid = proc.processIdentifier
      log("ACPBridge: killing process tree (pid=\(pid))")
      Self.killProcessTree(pid)
      proc.terminate()
    }
    process = nil
    closePipes()
    isRunning = false

    continuationBox.resumeAny(throwing: BridgeError.stopped)
  }

  /// Recursively kill a process and all its descendants (children, grandchildren, etc.)
  /// using `pgrep -P` to walk the process tree. This ensures MCP servers spawned by
  /// intermediate processes (which may create their own process groups) are cleaned up.
  static func killProcessTree(_ pid: Int32) {
    // Collect all descendant PIDs depth-first before sending any signals,
    // so we don't miss children that get re-parented to PID 1.
    var allPids: [Int32] = []

    func collectDescendants(of parentPid: Int32) {
      let pipe = Pipe()
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
      proc.arguments = ["-P", "\(parentPid)"]
      proc.standardOutput = pipe
      proc.standardError = FileHandle.nullDevice
      try? proc.run()
      proc.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      for line in output.split(separator: "\n") {
        if let childPid = Int32(line.trimmingCharacters(in: .whitespaces)) {
          collectDescendants(of: childPid)
          allPids.append(childPid)
        }
      }
    }

    collectDescendants(of: pid)

    // Kill descendants bottom-up (children last, grandchildren first)
    for descendantPid in allPids {
      kill(descendantPid, SIGTERM)
    }
    // Kill the root process itself
    kill(pid, SIGTERM)
  }

  /// Find and kill orphaned ACP-related processes from previous app runs.
  /// When the Swift app crashes / is force-killed, the bridge subprocess (and its
  /// patched-acp-entry / claude / MCP descendants) get re-parented to launchd
  /// (PPID=1) and survive forever. Each orphan holds ~600MB. We sweep them here
  /// before spawning a new bridge so they don't accumulate across user sessions.
  ///
  /// The in-bridge PPID watchdog handles the "next 5s after crash" case; this
  /// handles the "user just opened the app after a prior crash" case.
  static func sweepOrphanedBridges() {
    // Match the script names of every process in our ACP subtree:
    //   - dist/index.js          → the bridge itself (Node)
    //   - patched-acp-entry.mjs  → ACP server (spawned by bridge with detached:true)
    //   - codex-acp              → third-party ACP server (Zed)
    // We deliberately do NOT match every Node process; only ones whose argv contains
    // an acp-bridge path or codex-acp binary path.
    let needles = [
      "acp-bridge/dist/index.js",
      "acp-bridge/dist/patched-acp-entry.mjs",
      "patched-acp-entry.mjs",
      "codex-acp-darwin",
      "/codex-acp",
    ]

    // Snapshot all processes with PID, PPID, and full command line.
    // CRITICAL: read pipe BEFORE waitUntilExit. ps -axo against the whole system
    // emits >16KB which overflows the default pipe buffer; if we wait first, ps
    // blocks writing, we block waiting, and the actor's start() deadlocks
    // (observed Apr 30 2026 — caused 200%+ CPU and stuck bridge launch).
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-axo", "pid=,ppid=,command="]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch {
      log("ACPBridge: sweep — failed to run ps: \(error)")
      return
    }
    // Drain the pipe as ps writes (this also waits for EOF when ps exits).
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else { return }

    let myPid = Int32(ProcessInfo.processInfo.processIdentifier)
    var orphanPids: [Int32] = []

    for rawLine in output.split(separator: "\n") {
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      // ps format: "<pid> <ppid> <command>"
      let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count == 3,
            let pid = Int32(parts[0]),
            let ppid = Int32(parts[1])
      else { continue }
      let cmd = String(parts[2])

      // Skip ourselves and our descendants — only target actual orphans.
      // PPID==1 means the original parent (a previous Fazm.app instance) is gone.
      // We also catch PPID==<dead-bridge-pid> by intersecting with needle match.
      guard ppid == 1 else { continue }
      guard pid != myPid else { continue }

      let matched = needles.contains { cmd.contains($0) }
      if matched {
        orphanPids.append(pid)
      }
    }

    if orphanPids.isEmpty {
      log("ACPBridge: sweep — no orphaned bridge processes found")
      return
    }

    log("ACPBridge: sweep — found \(orphanPids.count) orphaned process(es): \(orphanPids)")

    // Collect every descendant of every orphan first (so we can SIGKILL them all
    // in one pass at the end if SIGTERM isn't enough).
    var allTargets: [Int32] = []
    for orphanPid in orphanPids {
      // Kill the entire subtree (the orphan plus any children it spawned —
      // claude CLI, playwright-mcp, whatsapp-mcp, macos-use, google-workspace).
      killProcessTree(orphanPid)
      allTargets.append(orphanPid)
    }

    // SIGTERM-resistant orphans: the patched-acp-entry process and the underlying
    // claude CLI register their own SIGTERM handlers that try to "gracefully shut
    // down" by flushing IPC. When orphaned to launchd they have no functional
    // parent to flush to, so they hang forever instead of exiting. Wait briefly,
    // then SIGKILL anything still alive (observed Apr 30 2026 — 14 of 20 swept
    // orphans survived SIGTERM and only died on SIGKILL).
    Thread.sleep(forTimeInterval: 1.0)
    var stillAlive: [Int32] = []
    for pid in allTargets where kill(pid, 0) == 0 {
      stillAlive.append(pid)
      kill(pid, SIGKILL)
    }
    if !stillAlive.isEmpty {
      log("ACPBridge: sweep — SIGKILL escalated for \(stillAlive.count) stubborn orphan(s): \(stillAlive)")
    }
  }

  // MARK: - Authentication

  /// Tell the bridge which auth method the user chose
  func authenticate(methodId: String) {
    guard isRunning else { return }
    let msg: [String: Any] = [
      "type": "authenticate",
      "methodId": methodId,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: msg),
      let jsonString = String(data: data, encoding: .utf8)
    {
      sendLine(jsonString)
    }
  }

  // MARK: - Session Transfer & Reset

  /// Re-key a session in the bridge's in-memory map so the next query under
  /// the new key finds it immediately (no resume round-trip needed).
  func transferSession(fromKey: String, toKey: String) {
    guard isRunning else { return }
    let msg: [String: Any] = ["type": "transferSession", "fromKey": fromKey, "toKey": toKey]
    if let data = try? JSONSerialization.data(withJSONObject: msg),
      let str = String(data: data, encoding: .utf8)
    {
      sendLine(str)
    }
  }

  /// Invalidate a session so the next query creates a fresh one (no history).
  func resetSession(key: String) {
    guard isRunning else { return }
    let msg: [String: Any] = ["type": "resetSession", "sessionKey": key]
    if let data = try? JSONSerialization.data(withJSONObject: msg),
      let str = String(data: data, encoding: .utf8)
    {
      sendLine(str)
    }
  }

  // MARK: - Session Pre-warming

  /// Tell the bridge to pre-create ACP sessions in the background.
  /// This saves ~4s on the first query by doing session/new ahead of time.
  /// Pass multiple models to pre-warm sessions for both Opus and Sonnet in parallel.
  struct WarmupSessionConfig {
    let key: String
    let model: String
    let systemPrompt: String?
    let resume: String?
    init(key: String, model: String, systemPrompt: String? = nil, resume: String? = nil) {
      self.key = key
      self.model = model
      self.systemPrompt = systemPrompt
      self.resume = resume
    }
  }

  func warmupSession(cwd: String? = nil, sessions: [WarmupSessionConfig]) {
    guard isRunning else { return }
    var dict: [String: Any] = ["type": "warmup"]
    if let cwd = cwd { dict["cwd"] = cwd }
    dict["sessions"] = sessions.map { s -> [String: Any] in
      var entry: [String: Any] = ["key": s.key, "model": s.model]
      if let sp = s.systemPrompt { entry["systemPrompt"] = sp }
      if let r = s.resume { entry["resume"] = r }
      return entry
    }
    if let data = try? JSONSerialization.data(withJSONObject: dict),
      let str = String(data: data, encoding: .utf8)
    {
      sendLine(str)
    }
  }

  // MARK: - Query

  /// Send a query to the ACP agent and stream results back.
  ///
  /// SESSION LIFECYCLE (Desktop app — not the VM/agent-cloud flow):
  /// Sessions are pre-warmed at startup via warmupSession(). The bridge reuses
  /// the same session for every subsequent query, so `systemPrompt` is ignored
  /// for the normal path. It is only applied if the session was invalidated
  /// (e.g. cwd change) and the bridge creates a new session/new internally.
  /// Pass cachedMainSystemPrompt here — never rebuild the full system prompt
  /// per-query, and never inject conversation history into it (the ACP SDK
  /// maintains conversation history natively within the session).
  ///
  /// TOKEN COUNTS: The cacheReadTokens/cacheWriteTokens returned by the bridge
  /// reflect the TOTAL across all internal tool-use rounds within this single
  /// session/prompt call. The ACP SDK handles tool use internally — there is no
  /// separate "sub-agent" spawning visible at this level.
  func query(
    prompt: String,
    systemPrompt: String,
    sessionKey: String? = nil,
    cwd: String? = nil,
    mode: String? = nil,
    model: String? = nil,
    resume: String? = nil,
    attachments: [[String: String]]? = nil,
    /// Recent local conversation history (oldest first). Only consulted when a
    /// `session/resume` attempt fails on the bridge side; bridge then prepends
    /// a recovery preamble to the prompt so context isn't silently lost. Pass
    /// only when `resume` is set, to keep the common path cheap.
    priorContext: [(role: String, text: String)]? = nil,
    onTextDelta: @escaping TextDeltaHandler,
    onToolCall: @escaping ToolCallHandler,
    onToolActivity: @escaping ToolActivityHandler,
    onThinkingDelta: @escaping ThinkingDeltaHandler = { _ in },
    onTextBlockBoundary: @escaping TextBlockBoundaryHandler = {},
    onToolResultDisplay: @escaping ToolResultDisplayHandler = { _, _, _ in },
    onAuthRequired: @escaping AuthRequiredHandler = { _, _ in },
    onAuthSuccess: @escaping AuthSuccessHandler = {},
    onStatusEvent: @escaping StatusEventHandler = { _ in }
  ) async throws -> QueryResult {
    guard isRunning else {
      throw BridgeError.notRunning
    }

    var queryDict: [String: Any] = [
      "type": "query",
      "id": UUID().uuidString,
      "prompt": prompt,
      "systemPrompt": systemPrompt,
    ]
    if let sessionKey = sessionKey {
      queryDict["sessionKey"] = sessionKey
    }
    if let cwd = cwd {
      queryDict["cwd"] = cwd
    }
    if let mode = mode {
      queryDict["mode"] = mode
    }
    if let model = model {
      queryDict["model"] = model
    }
    if let resume = resume {
      queryDict["resume"] = resume
    }
    if let attachments = attachments, !attachments.isEmpty {
      queryDict["attachments"] = attachments
    }
    // Only ship priorContext when we're actually attempting a resume — the bridge
    // ignores it on the happy path, so sending it without `resume` would be wasted
    // bytes (and risks token cost on edge paths).
    if let priorContext = priorContext, !priorContext.isEmpty, resume != nil {
      queryDict["priorContext"] = priorContext.map { ["role": $0.role, "text": $0.text] }
    }
    let jsonData = try JSONSerialization.data(withJSONObject: queryDict)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
      throw BridgeError.encodingError
    }

    // Reset per-query interrupt flag
    if let sk = sessionKey {
      sessionInterrupted[sk] = false
      sessionAcpToolsRunning[sk] = 0
      // Clear any stale messages for this session from a previous interrupted query
      if let queue = sessionPendingMessages[sk], !queue.isEmpty {
        log("ACPBridge: clearing \(queue.count) stale pending messages for session=\(sk)")
        sessionPendingMessages[sk] = nil
      }
    } else {
      isInterrupted = false
      acpToolsRunning = 0
      lastToolActivityAt = nil
      if !pendingMessages.isEmpty {
        log("ACPBridge: clearing \(pendingMessages.count) stale pending messages before new query")
        pendingMessages.removeAll()
      }
    }
    sendLine(jsonString)

    // Clean up per-session state when this query returns (success or error).
    // Use a local closure so it also runs if this Task is cancelled.
    defer {
      if let sk = sessionKey {
        sessionContinuations.removeValue(forKey: sk)
        sessionPendingMessages.removeValue(forKey: sk)
        sessionMessageGenerations.removeValue(forKey: sk)
        sessionInterrupted.removeValue(forKey: sk)
        sessionAcpToolsRunning.removeValue(forKey: sk)
      }
    }

    // Inactivity timeout: if no message arrives from the bridge for 10 minutes,
    // consider the query stuck. The bridge has its own per-tool watchdog
    // (TOOL_TIMEOUT_DEFAULT_MS = 5min for non-MCP, 2min for MCP) which fires
    // first and synthesizes a failure to unblock the agent loop. The deferral
    // logic in waitForMessage extends this further while ACP tools are still
    // actively running (up to 6× = 1 hour total budget for legitimate long work
    // like deep research, large refactors, multi-step Task sub-agents).
    // Previously 180s caused legitimate long-running queries to be killed;
    // see logs/fazm.log timeouts on 2026-04-30 (Task sub-agent kind=think
    // hangs were the dominant offender).
    let inactivityTimeout: TimeInterval = 600
    var messageCount = 0
    var lastMessageTime = Date()
    while true {
      let message = try await (sessionKey != nil
        ? waitForMessage(sessionKey: sessionKey!, timeout: inactivityTimeout)
        : waitForMessage(timeout: inactivityTimeout))
      messageCount += 1
      let gapMs = Int(Date().timeIntervalSince(lastMessageTime) * 1000)
      lastMessageTime = Date()
      if messageCount <= 3 || gapMs > 10000 || messageCount % 50 == 0 {
        log("ACPBridge: msg #\(messageCount) type=\(String(describing: message).prefix(40)) gap=\(gapMs)ms")
      }

      switch message {
      case .`init`:
        log("ACPBridge: new session started")

      case .textDelta(let text):
        onTextDelta(text)

      case .toolUse(let callId, let name, let input):
        // Per-session interrupt flag takes precedence; fall back to legacy global
        let interrupted = sessionKey.flatMap { sessionInterrupted[$0] } ?? isInterrupted
        if interrupted {
          log("ACPBridge: skipping tool call \(name) (interrupted)")
          continue
        }
        let result = await onToolCall(callId, name, input)
        let resultDict: [String: Any] = [
          "type": "tool_result",
          "callId": callId,
          "result": result,
        ]
        let resultData = try JSONSerialization.data(withJSONObject: resultDict)
        if let resultString = String(data: resultData, encoding: .utf8) {
          sendLine(resultString)
        }

        let interruptedAfter = sessionKey.flatMap { sessionInterrupted[$0] } ?? isInterrupted
        if interruptedAfter {
          log("ACPBridge: interrupted during tool call, draining for result")
          // Drain per-session queue if available, else legacy
          var drainQueue: [InboundMessage] = {
            if let sk = sessionKey, let q = sessionPendingMessages[sk] {
              sessionPendingMessages[sk] = nil
              return q
            }
            let q = pendingMessages
            pendingMessages.removeAll()
            return q
          }()
          while !drainQueue.isEmpty {
            let pending = drainQueue.removeFirst()
            switch pending {
            case .result(
              let text, let sessionId, let costUsd, let inputTokens, let outputTokens,
              let cacheReadTokens, let cacheWriteTokens):
              return QueryResult(
                text: text, costUsd: costUsd ?? 0, sessionId: sessionId, inputTokens: inputTokens,
                outputTokens: outputTokens, cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens)
            case .error(let message):
              log("ACPBridge: agent error (raw): \(message)")
              throw BridgeError.agentError(message)
            case .builtinKeyInvalid(let message):
              log("ACPBridge: builtin key invalid (drain): \(message)")
              throw BridgeError.builtinKeyInvalid(message)
            default:
              continue
            }
          }
          while true {
            let msg = try await (sessionKey != nil
              ? waitForMessage(sessionKey: sessionKey!)
              : waitForMessage())
            switch msg {
            case .result(
              let text, let sessionId, let costUsd, let inputTokens, let outputTokens,
              let cacheReadTokens, let cacheWriteTokens):
              return QueryResult(
                text: text, costUsd: costUsd ?? 0, sessionId: sessionId, inputTokens: inputTokens,
                outputTokens: outputTokens, cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens)
            case .error(let message):
              log("ACPBridge: agent error (raw): \(message)")
              throw BridgeError.agentError(message)
            case .builtinKeyInvalid(let message):
              log("ACPBridge: builtin key invalid: \(message)")
              throw BridgeError.builtinKeyInvalid(message)
            default:
              continue
            }
          }
        }

      case .thinkingDelta(let text):
        onThinkingDelta(text)

      case .textBlockBoundary:
        onTextBlockBoundary()

      case .toolActivity(let name, let status, let toolUseId, let input):
        onToolActivity(name, status, toolUseId, input)

      case .toolResultDisplay(let toolUseId, let name, let output):
        onToolResultDisplay(toolUseId, name, output)

      case .result(
        let text, let sessionId, let costUsd, let inputTokens, let outputTokens,
        let cacheReadTokens, let cacheWriteTokens):
        return QueryResult(
          text: text, costUsd: costUsd ?? 0, sessionId: sessionId, inputTokens: inputTokens,
          outputTokens: outputTokens, cacheReadTokens: cacheReadTokens,
          cacheWriteTokens: cacheWriteTokens)

      case .error(let message):
        log("ACPBridge: agent error (raw): \(message)")
        throw BridgeError.agentError(message)

      case .authRequired(let methods, let authUrl):
        onAuthRequired(methods, authUrl)

      case .authSuccess:
        onAuthSuccess()

      case .authTimeout:
        // Handled via global handler in deliverMessage(); ignore inside query loop
        break

      case .authFailed:
        // Handled via global handler in deliverMessage(); ignore inside query loop
        break

      case .creditExhausted(let message):
        log("ACPBridge: credit exhausted: \(message)")
        throw BridgeError.creditExhausted(message)

      case .builtinKeyInvalid(let message):
        log("ACPBridge: builtin key invalid: \(message)")
        throw BridgeError.builtinKeyInvalid(message)

      case .statusChange(let status):
        onStatusEvent(status == "compacting" ? .compacting(true) : .compacting(false))

      case .compactBoundary(let trigger, let preTokens):
        onStatusEvent(.compactBoundary(trigger: trigger, preTokens: preTokens))

      case .taskStarted(let taskId, let description):
        onStatusEvent(.taskStarted(taskId: taskId, description: description))

      case .taskNotification(let taskId, let status, let summary):
        onStatusEvent(.taskNotification(taskId: taskId, status: status, summary: summary))

      case .toolProgress(let toolUseId, let toolName, let elapsed):
        onStatusEvent(.toolProgress(toolUseId: toolUseId, toolName: toolName, elapsedTimeSeconds: elapsed))

      case .toolUseSummary(let summary):
        onStatusEvent(.toolUseSummary(summary: summary))

      case .rateLimit(let status, let resetsAt, let rateLimitType, let utilization, _, _):
        onStatusEvent(.rateLimit(status: status, resetsAt: resetsAt, rateLimitType: rateLimitType, utilization: utilization))
        // Do NOT throw on rate_limit rejected. The bridge monitoring layer fires this as a
        // pre-check against Claude.ai's web usage, but the underlying API session may still
        // complete successfully (the session continues and may call speak_response, etc.).
        // Throwing here would exit the streaming loop prematurely, losing the response and
        // incorrectly showing the "upgrade plan" label. Let the bridge run to completion;
        // a real API-level failure will produce its own error through the normal error path.
        if status == "rejected" {
          let resetDesc = resetsAt.map { ts -> String in
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.timeZone = .current
            return formatter.string(from: Date(timeIntervalSince1970: ts))
          } ?? "soon"
          let typeLabel = rateLimitType ?? "usage limit"
          log("ACPBridge: rate limit \(typeLabel) rejected (resets \(resetDesc)) — continuing session, not throwing")
        }

      case .apiRetry(let httpStatus, let errorType, let attempt, let maxRetries):
        // Log API retry events for diagnostics; the bridge handles retry logic
        log("ACPBridge: API retry \(attempt)/\(maxRetries), httpStatus=\(httpStatus.map(String.init) ?? "nil"), error=\(errorType)")

      case .observerPoll:
        // Handled immediately in deliverMessage(); should never reach here
        break

      case .observerStatus(_):
        // Handled immediately in deliverMessage(); should never reach here
        break

      case .modelsAvailable(_):
        // Handled immediately in deliverMessage(); should never reach here
        break

      case .mcpServersAvailable(_):
        // Handled immediately in deliverMessage(); should never reach here
        break

      case .codexProbeResult:
        // Handled immediately in deliverMessage(); should never reach here
        break

      case .codexLoginUrl, .codexLoginComplete, .codexLoginError:
        // Handled immediately in deliverMessage(); should never reach here
        break

      case .sessionExpired(let oldSessionId, let newSessionId, let contextRestored, let restoredMessageCount, let reason, _):
        log("ACPBridge: session_expired old=\(oldSessionId) new=\(newSessionId) restored=\(contextRestored) count=\(restoredMessageCount)")
        onStatusEvent(.sessionExpired(oldSessionId: oldSessionId, newSessionId: newSessionId, contextRestored: contextRestored, restoredMessageCount: restoredMessageCount, reason: reason))

      case .toolHangCanceled(let toolName, let toolUseId, let durationSeconds, let reason, _):
        log("ACPBridge: tool_hang_canceled tool=\(toolName) duration=\(durationSeconds)s reason=\(reason)")
        onStatusEvent(.toolHangCanceled(toolName: toolName, toolUseId: toolUseId, durationSeconds: durationSeconds, reason: reason))

      case .sessionStarted(let sid, let evtKey, let isResume):
        log("ACPBridge: session_started \(isResume ? "(resumed)" : "(new)") sessionId=\(sid) key=\(evtKey ?? "nil")")
        onStatusEvent(.sessionStarted(sessionId: sid, sessionKey: evtKey, isResume: isResume))
      }
    }
  }

  // MARK: - Streaming Input Controls

  /// Interrupt the running agent, keeping partial response.
  func interrupt() {
    guard isRunning else { return }
    isInterrupted = true
    // Also mark every active per-session query as interrupted (legacy: interrupt all)
    for key in sessionContinuations.keys {
      sessionInterrupted[key] = true
    }
    sendLine("{\"type\":\"interrupt\"}")
  }

  /// Interrupt a specific session only. Other concurrent sessions continue running.
  func interrupt(sessionKey: String) {
    guard isRunning else { return }
    sessionInterrupted[sessionKey] = true
    let dict: [String: Any] = ["type": "interrupt", "sessionKey": sessionKey]
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let json = String(data: data, encoding: .utf8) {
      sendLine(json)
    }
  }

  /// Cancel any active OAuth flow so the next attempt starts fresh.
  func cancelAuth() {
    guard isRunning else { return }
    sendLine("{\"type\":\"cancel_auth\"}")
  }

  /// Phase 3.2 — ask the bridge to lazy-spawn codex-acp and report its
  /// reachability + auth state + available models. The result arrives via
  /// `onCodexProbeResult`. No-op if the bridge isn't running.
  func sendCodexProbe() {
    guard isRunning else { return }
    sendLine("{\"type\":\"codex_init_probe\"}")
  }

  /// Start the Codex (ChatGPT) OAuth login flow. The bridge will emit
  /// `codex_login_url` with the browser URL, then `codex_login_complete`
  /// or `codex_login_error` when done.
  func sendCodexLogin() {
    guard isRunning else { return }
    sendLine("{\"type\":\"codex_login\"}")
  }

  /// Cancel an in-progress Codex OAuth login flow.
  func sendCodexLoginCancel() {
    guard isRunning else { return }
    sendLine("{\"type\":\"codex_login_cancel\"}")
  }

  /// Disconnect the Codex backend by deleting `~/.codex/auth.json` and
  /// shutting down any running codex-acp subprocess. The bridge re-probes
  /// afterwards, so authMode flips back to "none".
  func sendCodexLogout() {
    guard isRunning else { return }
    sendLine("{\"type\":\"codex_logout\"}")
  }

  // MARK: - Private

  private func sendLine(_ line: String) {
    guard let pipe = stdinPipe else { return }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = (trimmed + "\n").data(using: .utf8) {
      do {
        try pipe.fileHandleForWriting.write(contentsOf: data)
      } catch {
        logError("ACPBridge: Failed to write to stdin pipe", error: error)
      }
    }
  }

  private func startReadingStdout() {
    guard let stdout = stdoutPipe else { return }

    readTask = Task.detached { [weak self] in
      let handle = stdout.fileHandleForReading
      var buffer = Data()

      while !Task.isCancelled {
        let chunk = handle.availableData
        if chunk.isEmpty {
          break
        }
        buffer.append(chunk)

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = buffer[buffer.startIndex..<newlineIndex]
          buffer = Data(buffer[buffer.index(after: newlineIndex)...])

          guard let lineStr = String(data: lineData, encoding: .utf8),
            !lineStr.trimmingCharacters(in: .whitespaces).isEmpty
          else {
            continue
          }

          if let parsed = Self.parseMessage(lineStr) {
            await self?.deliverMessage(parsed.message, sessionKey: parsed.sessionKey)
          }
        }
      }
    }
  }

  private static func parseMessage(_ json: String) -> (message: InboundMessage, sessionKey: String?)? {
    guard let data = json.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let _ = dict["type"] as? String
    else {
      logError("ACPBridge: failed to parse message: \(json.prefix(200))")
      return nil
    }
    let sessionKey = dict["sessionKey"] as? String
    guard let inner = parseMessageInner(dict) else { return nil }
    return (inner, sessionKey)
  }

  private static func parseMessageInner(_ dict: [String: Any]) -> InboundMessage? {
    guard let type = dict["type"] as? String else { return nil }

    switch type {
    case "init":
      let sessionId = dict["sessionId"] as? String ?? ""
      return .`init`(sessionId: sessionId)

    case "text_delta":
      let text = dict["text"] as? String ?? ""
      return .textDelta(text: text)

    case "tool_use":
      let callId = dict["callId"] as? String ?? ""
      let name = dict["name"] as? String ?? ""
      let input = dict["input"] as? [String: Any] ?? [:]
      return .toolUse(callId: callId, name: name, input: input)

    case "thinking_delta":
      let text = dict["text"] as? String ?? ""
      return .thinkingDelta(text: text)

    case "text_block_boundary":
      return .textBlockBoundary

    case "tool_activity":
      let name = dict["name"] as? String ?? ""
      let status = dict["status"] as? String ?? "started"
      let toolUseId = dict["toolUseId"] as? String
      let input = dict["input"] as? [String: Any]
      return .toolActivity(name: name, status: status, toolUseId: toolUseId, input: input)

    case "tool_result_display":
      let toolUseId = dict["toolUseId"] as? String ?? ""
      let name = dict["name"] as? String ?? ""
      let output = dict["output"] as? String ?? ""
      return .toolResultDisplay(toolUseId: toolUseId, name: name, output: output)

    case "result":
      let text = dict["text"] as? String ?? ""
      let sessionId = dict["sessionId"] as? String ?? ""
      let costUsd = dict["costUsd"] as? Double
      let inputTokens = dict["inputTokens"] as? Int ?? 0
      let outputTokens = dict["outputTokens"] as? Int ?? 0
      let cacheReadTokens = dict["cacheReadTokens"] as? Int ?? 0
      let cacheWriteTokens = dict["cacheWriteTokens"] as? Int ?? 0
      return .result(
        text: text, sessionId: sessionId, costUsd: costUsd,
        inputTokens: inputTokens, outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)

    case "error":
      let message = dict["message"] as? String ?? "Unknown error"
      return .error(message: message)

    case "auth_required":
      let methods = dict["methods"] as? [[String: Any]] ?? []
      let authUrl = dict["authUrl"] as? String
      return .authRequired(methods: methods, authUrl: authUrl)

    case "auth_success":
      return .authSuccess

    case "auth_timeout":
      let reason = dict["reason"] as? String ?? "unknown"
      return .authTimeout(reason: reason)

    case "auth_failed":
      let reason = dict["reason"] as? String ?? "unknown"
      let httpStatus = dict["httpStatus"] as? Int
      return .authFailed(reason: reason, httpStatus: httpStatus)

    case "credit_exhausted":
      let message = dict["message"] as? String ?? "Credit balance exhausted"
      return .creditExhausted(message: message)

    case "builtin_key_invalid":
      let message = dict["message"] as? String ?? "Built-in API key invalid"
      return .builtinKeyInvalid(message: message)

    case "status_change":
      let status = dict["status"] as? String
      return .statusChange(status: status)

    case "compact_boundary":
      let trigger = dict["trigger"] as? String ?? "auto"
      let preTokens = dict["preTokens"] as? Int ?? 0
      return .compactBoundary(trigger: trigger, preTokens: preTokens)

    case "task_started":
      let taskId = dict["taskId"] as? String ?? ""
      let description = dict["description"] as? String ?? ""
      return .taskStarted(taskId: taskId, description: description)

    case "task_notification":
      let taskId = dict["taskId"] as? String ?? ""
      let status = dict["status"] as? String ?? ""
      let summary = dict["summary"] as? String ?? ""
      return .taskNotification(taskId: taskId, status: status, summary: summary)

    case "tool_progress":
      let toolUseId = dict["toolUseId"] as? String ?? ""
      let toolName = dict["toolName"] as? String ?? ""
      let elapsed = dict["elapsedTimeSeconds"] as? Double ?? 0
      return .toolProgress(toolUseId: toolUseId, toolName: toolName, elapsedTimeSeconds: elapsed)

    case "tool_use_summary":
      let summary = dict["summary"] as? String ?? ""
      return .toolUseSummary(summary: summary)

    case "rate_limit":
      let status = dict["status"] as? String ?? "unknown"
      let resetsAt = dict["resetsAt"] as? Double
      let rateLimitType = dict["rateLimitType"] as? String
      let utilization = dict["utilization"] as? Double
      let overageStatus = dict["overageStatus"] as? String
      let overageDisabledReason = dict["overageDisabledReason"] as? String
      return .rateLimit(status: status, resetsAt: resetsAt, rateLimitType: rateLimitType, utilization: utilization, overageStatus: overageStatus, overageDisabledReason: overageDisabledReason)

    case "api_retry":
      let httpStatus = dict["httpStatus"] as? Int
      let errorType = dict["errorType"] as? String ?? "unknown"
      let attempt = dict["attempt"] as? Int ?? 0
      let maxRetries = dict["maxRetries"] as? Int ?? 0
      return .apiRetry(httpStatus: httpStatus, errorType: errorType, attempt: attempt, maxRetries: maxRetries)

    case "observer_poll":
      return .observerPoll

    case "observer_status":
      let running = dict["running"] as? Bool ?? false
      return .observerStatus(running: running)

    case "models_available":
      let models = dict["models"] as? [[String: Any]] ?? []
      return .modelsAvailable(models: models)

    case "mcp_servers_available":
      let servers = dict["servers"] as? [[String: Any]] ?? []
      return .mcpServersAvailable(servers: servers)

    case "session_expired":
      let oldSessionId = dict["oldSessionId"] as? String ?? ""
      let newSessionId = dict["newSessionId"] as? String ?? ""
      let contextRestored = dict["contextRestored"] as? Bool ?? false
      let restoredMessageCount = dict["restoredMessageCount"] as? Int ?? 0
      let reason = dict["reason"] as? String ?? "Previous session expired."
      let sessionKey = dict["sessionKey"] as? String
      return .sessionExpired(oldSessionId: oldSessionId, newSessionId: newSessionId, contextRestored: contextRestored, restoredMessageCount: restoredMessageCount, reason: reason, sessionKey: sessionKey)

    case "tool_hang_canceled":
      let toolName = dict["toolName"] as? String ?? "(unknown)"
      let toolUseId = dict["toolUseId"] as? String ?? ""
      let durationSeconds = dict["durationSeconds"] as? Double ?? 0
      let reason = dict["reason"] as? String ?? "Tool timed out and the turn was canceled."
      let sessionKey = dict["sessionKey"] as? String
      return .toolHangCanceled(toolName: toolName, toolUseId: toolUseId, durationSeconds: durationSeconds, reason: reason, sessionKey: sessionKey)

    case "session_started":
      let sessionId = dict["sessionId"] as? String ?? ""
      let sessionKey = dict["sessionKey"] as? String
      let isResume = dict["isResume"] as? Bool ?? false
      return .sessionStarted(sessionId: sessionId, sessionKey: sessionKey, isResume: isResume)

    case "warmup_complete":
      let durationMs = dict["durationMs"] as? Double ?? 0
      let sessionKeys = dict["sessionKeys"] as? [String] ?? []
      let ok = dict["ok"] as? Bool ?? false
      let error = dict["error"] as? String
      return .warmupComplete(durationMs: durationMs, sessionKeys: sessionKeys, ok: ok, error: error)

    case "codex_probe_result":
      let ok = dict["ok"] as? Bool ?? false
      let agent = dict["agent"] as? String
      let authMethods = dict["authMethods"] as? [String] ?? []
      let currentModelId = dict["currentModelId"] as? String
      let availableModels = dict["availableModels"] as? [[String: Any]] ?? []
      let authMode = dict["authMode"] as? String ?? "none"
      let error = dict["error"] as? String
      return .codexProbeResult(ok: ok, agent: agent, authMethods: authMethods, currentModelId: currentModelId, availableModels: availableModels, authMode: authMode, error: error)

    case "codex_login_url":
      let url = dict["url"] as? String ?? ""
      return .codexLoginUrl(url: url)

    case "codex_login_complete":
      return .codexLoginComplete

    case "codex_login_error":
      let error = dict["error"] as? String ?? "Unknown error"
      return .codexLoginError(error: error)

    default:
      log("ACPBridge: unknown message type: \(type)")
      return nil
    }
  }

  private func deliverMessage(_ message: InboundMessage, sessionKey: String? = nil) {
    // Maintain sessionId → sessionKey reverse map from session lifecycle events.
    // This is the source of truth for the routing fallback below — without it
    // we cannot recover when an inbound message arrives without a sessionKey.
    switch message {
    case .sessionStarted(let sid, let evtKey, _):
      if let evtKey = evtKey {
        sessionIdToKey[sid] = evtKey
      }
    case .sessionExpired(let oldSid, let newSid, _, _, _, let evtKey):
      sessionIdToKey.removeValue(forKey: oldSid)
      if let evtKey = evtKey {
        sessionIdToKey[newSid] = evtKey
      }
    default:
      break
    }

    // Routing fallback: if the bridge dropped the sessionKey from this message
    // (typically a cancellation `result` emitted from a catch block after
    // unregisterSession ran), recover the key by sessionId. The map is kept
    // alive across unregister so this lookup still works.
    var effectiveSessionKey = sessionKey
    if effectiveSessionKey == nil {
      let sid: String? = {
        switch message {
        case .result(_, let s, _, _, _, _, _): return s.isEmpty ? nil : s
        default: return nil
        }
      }()
      if let sid = sid, let recovered = sessionIdToKey[sid] {
        log("ACPBridge: deliverMessage recovered sessionKey=\(recovered) from sessionId=\(sid) (bridge dropped sessionKey field)")
        effectiveSessionKey = recovered
      }
    }
    let sessionKey = effectiveSessionKey

    // Debug: log routing for text/thinking/tool messages
    switch message {
    case .textDelta(let text):
      log("ACPBridge: deliverMessage textDelta sessionKey=\(sessionKey ?? "nil") text='\(text.prefix(30))'")
    case .thinkingDelta(let text):
      if text.count > 20 { // skip tiny deltas to reduce noise
        log("ACPBridge: deliverMessage thinkingDelta sessionKey=\(sessionKey ?? "nil") text='\(text.prefix(30))'")
      }
    case .toolUse(_, let name, _):
      log("ACPBridge: deliverMessage toolUse sessionKey=\(sessionKey ?? "nil") name=\(name)")
    case .result(let text, let sid, _, _, _, _, _):
      log("ACPBridge: deliverMessage result sessionKey=\(sessionKey ?? "nil") sessionId=\(sid) text='\(text.prefix(40))'")
    default:
      break
    }
    // Handle auth messages via global handlers. Auth UI state (sheets, buttons)
    // must update regardless of whether a query is in-flight. For auth_required,
    // only fire the global handler when no query is active (the query loop handles
    // it via its own callback). For auth_success/timeout/failed, ALWAYS fire the
    // global handler so the UI updates immediately, AND still deliver to the query
    // loop (which may also need to react).
    switch message {
    case .authRequired(let methods, let authUrl):
      if !continuationBox.isPending, let handler = onAuthRequiredGlobal {
        // No active query waiting — fire the global handler immediately
        handler(methods, authUrl)
        return
      }
    case .authSuccess:
      // Always fire global handler so UI clears auth sheets/buttons immediately,
      // even if a query is in-flight. The message is still delivered to the query loop below.
      onAuthSuccessGlobal?()
      if !continuationBox.isPending {
        return  // No query waiting — nothing more to deliver
      }
    case .authTimeout(let reason):
      // Always fire global handler so UI shows timeout state
      onAuthTimeoutGlobal?(reason)
      if !continuationBox.isPending {
        return
      }
    case .authFailed(let reason, let httpStatus):
      // Always fire global handler so UI shows failure state
      onAuthFailedGlobal?(reason, httpStatus)
      if !continuationBox.isPending {
        return
      }
    case .observerPoll:
      // Always handle immediately — chat observer runs independently of any active query
      log("ACPBridge: received chat observer poll, handler=\(onChatObserverPoll != nil)")
      onChatObserverPoll?()
      return
    case .observerStatus(let running):
      log("ACPBridge: chat observer status running=\(running)")
      onChatObserverStatusChange?(running)
      return
    case .modelsAvailable(let models):
      log("ACPBridge: received models_available with \(models.count) models")
      let parsed = models.compactMap { dict -> (modelId: String, name: String, description: String?)? in
        guard let modelId = dict["modelId"] as? String,
              let name = dict["name"] as? String else { return nil }
        let description = dict["description"] as? String
        return (modelId: modelId, name: name, description: description)
      }
      if !parsed.isEmpty {
        onModelsAvailable?(parsed)
      }
      return
    case .mcpServersAvailable(let servers):
      log("ACPBridge: received mcp_servers_available with \(servers.count) servers")
      let parsed = servers.compactMap { dict -> MCPServerManager.ActiveServer? in
        guard let name = dict["name"] as? String,
              let command = dict["command"] as? String else { return nil }
        let builtin = dict["builtin"] as? Bool ?? false
        return MCPServerManager.ActiveServer(name: name, command: command, builtin: builtin)
      }
      MCPServerManager.shared.updateActiveServers(parsed)
      return
    case .codexProbeResult(let ok, let agent, let authMethods, let currentModelId, let availableModels, let authMode, let error):
      log("ACPBridge: received codex_probe_result ok=\(ok) authMode=\(authMode) models=\(availableModels.count) error=\(error ?? "-")")
      onCodexProbeResult?(ok, agent, authMethods, currentModelId, availableModels, authMode, error)
      return
    case .codexLoginUrl(let url):
      log("ACPBridge: received codex_login_url")
      onCodexLoginUrl?(url)
      return
    case .codexLoginComplete:
      log("ACPBridge: received codex_login_complete")
      onCodexLoginComplete?()
      return
    case .codexLoginError(let error):
      log("ACPBridge: received codex_login_error: \(error)")
      onCodexLoginError?(error)
      return
    case .toolUse(let callId, let name, let input):
      // If a per-session query is waiting for this tool call, let it fall through
      // to the per-session routing below so the query loop handles it.
      let hasSessionWaiter = sessionKey.flatMap { sessionContinuations[$0] } != nil
          || sessionKey.flatMap { sessionPendingMessages[$0] } != nil
      if !hasSessionWaiter {
        // No per-session query waiting; use background handler (chat observer, etc.)
        if !continuationBox.isPending, let handler = onBackgroundToolCall {
          Task {
            let result = await handler(callId, name, input)
            let resultDict: [String: Any] = [
              "type": "tool_result",
              "callId": callId,
              "result": result,
            ]
            if let resultData = try? JSONSerialization.data(withJSONObject: resultDict),
               let resultString = String(data: resultData, encoding: .utf8) {
              self.sendLine(resultString)
            }
          }
          return
        }
      }
    default:
      break
    }

    // Route by sessionKey if available; otherwise fall back to legacy single queue.
    if let key = sessionKey, let box = sessionContinuations[key] {
      if !box.resume(returning: message) {
        var queue = sessionPendingMessages[key] ?? []
        queue.append(message)
        sessionPendingMessages[key] = queue
      }
      return
    }
    // If a sessionKey is present but no box exists yet, queue per-session so the
    // waiter picks it up when it registers.
    if let key = sessionKey {
      var queue = sessionPendingMessages[key] ?? []
      queue.append(message)
      sessionPendingMessages[key] = queue
      return
    }
    // No sessionKey — legacy path (auth, observer, bridge init)
    if !continuationBox.resume(returning: message) {
      pendingMessages.append(message)
    }
  }

  /// Wait for a message on a specific session's queue. Concurrent-safe.
  private func waitForMessage(sessionKey: String, timeout: TimeInterval? = nil) async throws -> InboundMessage {
    // Drain any queued pending messages first
    if var queue = sessionPendingMessages[sessionKey], !queue.isEmpty {
      let msg = queue.removeFirst()
      sessionPendingMessages[sessionKey] = queue.isEmpty ? nil : queue
      return msg
    }
    guard isRunning else {
      throw BridgeError.stopped
    }

    let box = sessionContinuations[sessionKey] ?? {
      let b = ContinuationBox<InboundMessage, Error>()
      sessionContinuations[sessionKey] = b
      return b
    }()
    let gen = (sessionMessageGenerations[sessionKey] ?? 0) &+ 1
    sessionMessageGenerations[sessionKey] = gen

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        box.store(continuation, generation: gen)
        if let timeout = timeout {
          Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Defer timeout while ACP tool activity is ongoing.
            // We treat "tools running RIGHT NOW" OR "tool start/complete in the
            // last toolActivityWindow seconds (60s)" as ongoing activity. The
            // sliding window closes the gap-between-tools race: when one tool
            // ends a fraction of a second before the next starts, the
            // instantaneous count momentarily drops to 0, and a strict count>0
            // check would fire a premature timeout.
            // Up to 6 deferrals × 600s base = 1 hour budget when tools keep
            // running. This gives long-running operations (deep research,
            // multi-step Task sub-agents, large refactors) room to complete
            // without the conversation being killed.
            var deferrals = 0
            let maxDeferrals = 6
            while box.isPending(generation: gen), deferrals < maxDeferrals {
              let toolsRunning = await self?.getSessionAcpToolsRunning(sessionKey) ?? 0
              let recentActivity = await self?.hasRecentToolActivity() ?? false
              guard toolsRunning > 0 || recentActivity else { break }
              deferrals += 1
              log("ACPBridge: waitForMessage[\(sessionKey)] timeout deferred (\(deferrals)/\(maxDeferrals)) running=\(toolsRunning) recentActivity=\(recentActivity)")
              try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            if box.resume(throwing: BridgeError.timeout, ifGeneration: gen) {
              log("ACPBridge: waitForMessage[\(sessionKey)] timeout fired after \(timeout)s")
            }
          }
        }
      }
    } onCancel: {
      box.resume(throwing: CancellationError(), ifGeneration: gen)
    }
  }

  private func getSessionAcpToolsRunning(_ sessionKey: String) -> Int {
    // Per-session tracking isn't instrumented from stderr yet; fall back to
    // the global count which still usefully defers timeouts when ANY tool is running.
    return sessionAcpToolsRunning[sessionKey] ?? acpToolsRunning
  }

  private func waitForMessage(timeout: TimeInterval? = nil) async throws -> InboundMessage {
    if !pendingMessages.isEmpty {
      return pendingMessages.removeFirst()
    }

    // If the bridge is no longer running (e.g., stop() was called during a tool call),
    // throw immediately rather than creating a continuation that would never be resumed.
    guard isRunning else {
      throw BridgeError.stopped
    }

    messageGeneration &+= 1
    let expectedGeneration = messageGeneration

    let box = self.continuationBox
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        box.store(continuation, generation: expectedGeneration)

        if let timeout = timeout {
          Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Before timing out, check if ACP tools are still running via stderr.
            // ACP's own tools (Terminal, text_editor) don't send bridge messages,
            // so waitForMessage would time out even though work is progressing.
            // Defer up to 6 times (matching the per-session waitForMessage variant,
            // total ~1 hour at 600s base) while tools are actively running OR
            // a tool start/complete fired within the last toolActivityWindow (60s).
            // The activity window closes the gap-between-tools race where one
            // tool ends just before the next starts and the instantaneous count
            // momentarily reads 0.
            var deferrals = 0
            let maxDeferrals = 6
            while box.isPending(generation: expectedGeneration),
                  (self.acpToolsRunning > 0 || self.hasRecentToolActivity()),
                  deferrals < maxDeferrals {
              deferrals += 1
              log("ACPBridge: waitForMessage timeout deferred (\(deferrals)/\(maxDeferrals)) — running=\(self.acpToolsRunning), recentActivity=\(self.hasRecentToolActivity())")
              try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            }
            if box.resume(throwing: BridgeError.timeout, ifGeneration: expectedGeneration) {
              log("ACPBridge: waitForMessage timeout fired after \(timeout)s — no message received, bridge may be stuck")
            }
          }
        }
      }
    } onCancel: {
      // Resume the continuation synchronously when the calling Task is cancelled.
      // This runs on an arbitrary thread, NOT on the actor. Using the lock-protected
      // ContinuationBox avoids the race where `Task { await self... }` never executes
      // because the actor is being deallocated during autorelease pool drain.
      box.resume(throwing: CancellationError(), ifGeneration: expectedGeneration)
    }
  }

  private func markOOM() {
    lastExitWasOOM = true
  }

  private func adjustAcpToolCount(delta: Int) {
    acpToolsRunning = max(0, acpToolsRunning + delta)
    lastToolActivityAt = Date()
  }

  private func hasRecentToolActivity() -> Bool {
    guard let last = lastToolActivityAt else { return false }
    return Date().timeIntervalSince(last) < toolActivityWindow
  }

  private func handleTermination(
    exitCode: Int32 = -1, reason: Process.TerminationReason = .exit, generation: UInt64? = nil
  ) {
    // Ignore stale termination from a previous process (fixes race where old handler closes new pipes)
    if let gen = generation, gen != processGeneration {
      log("ACPBridge: ignoring stale termination (gen=\(gen), current=\(processGeneration))")
      return
    }

    let reasonStr = reason == .uncaughtSignal ? "signal" : "exit"

    // Capture any remaining stderr before closing pipes (may reveal OOM)
    if let stderrHandle = stderrPipe?.fileHandleForReading {
      stderrHandle.readabilityHandler = nil  // Stop async handler
      let remaining = stderrHandle.availableData
      if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
        log("ACPBridge stderr (final): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        if text.contains("out of memory") || text.contains("Failed to reserve virtual memory") {
          lastExitWasOOM = true
        }
      }
    }

    // SIGABRT (134) and SIGTRAP (133/5) with uncaughtSignal are typical V8 OOM crashes
    let likelyOOM =
      lastExitWasOOM
      || (reason == .uncaughtSignal
        && (exitCode == 134 || exitCode == 133 || exitCode == 5 || exitCode == 6))
    let error: BridgeError = likelyOOM ? .outOfMemory : .processExited
    lastExitWasOOM = false

    log("ACPBridge: process terminated (code=\(exitCode), reason=\(reasonStr), error=\(error))")
    isRunning = false
    closePipes()
    continuationBox.resumeAny(throwing: error)
  }

  private func closePipes() {
    if let stdin = stdinPipe {
      try? stdin.fileHandleForWriting.close()
      try? stdin.fileHandleForReading.close()
    }
    if let stdout = stdoutPipe {
      stdout.fileHandleForReading.readabilityHandler = nil
      try? stdout.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
    }
    if let stderr = stderrPipe {
      stderr.fileHandleForReading.readabilityHandler = nil
      try? stderr.fileHandleForReading.close()
      try? stderr.fileHandleForWriting.close()
    }
    stdinPipe = nil
    stdoutPipe = nil
    stderrPipe = nil
  }

  // MARK: - Node.js Discovery

  private func findNodeBinary() -> String? {
    // 1. Check bundled node binary in app resources
    let bundledNode = Bundle.resourceBundle.path(forResource: "node", ofType: nil)
    if let bundledNode, FileManager.default.isExecutableFile(atPath: bundledNode) {
      // Copy to temp dir to avoid macOS 26 CSM killing JIT-entitled binaries inside sealed bundles
      return NodeBinaryHelper.externalNodePath(from: bundledNode)
    }

    // 2. Fall back to system-installed node
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node",
    ]
    for path in candidates {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // 3. Check NVM installations
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let nvmDir = (home as NSString).appendingPathComponent(".nvm/versions/node")
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
      let sorted = versions.sorted { v1, v2 in
        v1.compare(v2, options: .numeric) == .orderedDescending
      }
      for version in sorted {
        let nodePath = (nvmDir as NSString).appendingPathComponent("\(version)/bin/node")
        if FileManager.default.isExecutableFile(atPath: nodePath) {
          return nodePath
        }
      }
    }

    // 4. Try `which node`
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["node"]
    let pipe = Pipe()
    whichProcess.standardOutput = pipe
    try? whichProcess.run()
    whichProcess.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !path.isEmpty,
      FileManager.default.isExecutableFile(atPath: path)
    {
      return path
    }

    return nil
  }

  // MARK: - Playwright Connection Test

  /// Test that the Playwright Chrome extension is connected and working.
  /// Sends a minimal query that triggers a browser_snapshot tool call.
  /// Returns true if the extension responds successfully.
  func testPlaywrightConnection() async throws -> Bool {
    guard isRunning else {
      throw BridgeError.notRunning
    }

    log("ACPBridge: Testing Playwright connection...")
    let result = try await query(
      prompt:
        "Call browser_snapshot to verify the extension is connected. Only call that one tool, then report success or failure.",
      systemPrompt:
        "You are a connection test agent. Call the browser_snapshot tool exactly once. If it succeeds, respond with exactly 'CONNECTED'. If it fails, respond with 'FAILED' followed by the error.",
      sessionKey: "connection-test",
      mode: "ask",
      onTextDelta: { _ in },
      onToolCall: { _, _, _ in "" },
      onToolActivity: { name, status, _, _ in
        log("ACPBridge: test tool activity: \(name) \(status)")
      },
      onThinkingDelta: { _ in },
      onToolResultDisplay: { _, name, output in
        log("ACPBridge: test tool result: \(name) -> \(output.prefix(200))")
      }
    )
    let connected = result.text.contains("CONNECTED")
    log("ACPBridge: Playwright test response: \(result.text.prefix(300)), connected=\(connected)")
    return connected
  }

  private func findBridgeScript() -> String? {
    // 1. Check in app bundle Resources
    if let bundlePath = Bundle.main.resourcePath {
      let bundledScript = (bundlePath as NSString).appendingPathComponent(
        "acp-bridge/dist/index.js")
      if FileManager.default.fileExists(atPath: bundledScript) {
        return bundledScript
      }
    }

    // 2. Check relative to executable (development mode)
    let executableURL = Bundle.main.executableURL
    if let execDir = executableURL?.deletingLastPathComponent() {
      let devPaths = [
        execDir.appendingPathComponent("../../../acp-bridge/dist/index.js").path,
        execDir.appendingPathComponent("../../../../acp-bridge/dist/index.js").path,
      ]
      for path in devPaths {
        let resolved = (path as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: resolved) {
          return resolved
        }
      }
    }

    // 3. Check relative to current working directory
    let cwdPath = FileManager.default.currentDirectoryPath
    let cwdScript = (cwdPath as NSString).appendingPathComponent("acp-bridge/dist/index.js")
    if FileManager.default.fileExists(atPath: cwdScript) {
      return cwdScript
    }

    return nil
  }
}

// MARK: - Errors

enum BridgeError: LocalizedError {
  case nodeNotFound
  case bridgeScriptNotFound
  case notRunning
  case encodingError
  case timeout
  case processExited
  case outOfMemory
  case stopped
  case creditExhausted(String)
  case agentError(String)
  /// Built-in (bundled API key) mode failed authentication. ChatProvider catches
  /// this specifically and refetches the key from the backend instead of pushing
  /// the user into the personal-Claude OAuth flow.
  case builtinKeyInvalid(String)

  /// True when this is a credit or temporary rate-limit exhaustion the user should see.
  var isCreditOrRateLimitError: Bool {
    if case .creditExhausted = self { return true }
    return false
  }

  /// True when credit exhaustion is a temporary rate limit (has a resets-at timestamp).
  /// False means actual credits are gone and the user needs to take action.
  var isRateLimitExhaustion: Bool {
    guard case .creditExhausted(let msg) = self else { return false }
    return msg.range(of: #"resets\s+\S"#, options: .regularExpression) != nil
  }

  var errorDescription: String? {
    switch self {
    case .nodeNotFound:
      return "Node.js not found. Please reinstall the app."
    case .bridgeScriptNotFound:
      return "AI components missing. Please reinstall the app."
    case .notRunning:
      return "AI is not running. Try sending your message again."
    case .encodingError:
      return "Failed to encode message"
    case .timeout:
      return "AI took too long to respond. Try again."
    case .processExited:
      return "AI stopped unexpectedly. Try sending your message again."
    case .outOfMemory:
      return "Not enough memory for AI chat. Close some apps and try again."
    case .stopped:
      return "Response stopped."
    case .creditExhausted(let message):
      // Extract "resets X" clause from the error message if present (e.g. "resets 11pm (America/Santiago)")
      if let range = message.range(of: #"resets\s+\S.*"#, options: .regularExpression) {
        let resets = String(message[range])
        return "You've hit Claude's usage limit (\(resets)). Upgrade to Claude Pro at claude.ai for higher limits."
      }
      return "Built-in credits are exhausted. Please switch to your personal Claude account in Settings."
    case .builtinKeyInvalid:
      // Fallback wording. ChatProvider intercepts this case before localizedDescription
      // is shown — it tries to refetch the key and silently retry. The string here is
      // only displayed if the refetch+retry path is bypassed for some reason.
      return "We couldn't verify your account. Please try again in a few seconds."
    case .agentError(let msg):
      // Strip "Internal error: " prefix if present — ACP wraps the real message
      let cleaned = msg.hasPrefix("Internal error: ") ? String(msg.dropFirst("Internal error: ".count)) : msg

      // When the user has a Custom API Endpoint configured (LM Studio, Ollama, corporate proxy, etc.),
      // raw upstream errors like `API Error: 400 ... "No models loaded ... use the 'lms load' command"`
      // are confusing — users blame Fazm for an error that's coming from their local server.
      // Detect known custom-endpoint failures and surface an actionable message instead.
      let endpoint = UserDefaults.standard.string(forKey: "customApiEndpoint") ?? ""
      if !endpoint.isEmpty {
        let lower = cleaned.lowercased()
        if lower.contains("no models loaded") || lower.contains("lms load") {
          return "Your custom API endpoint (\(endpoint)) reported no model is loaded. Load a model in your local server (e.g. LM Studio → Developer → Load Model), or turn off Custom API Endpoint in Settings → Advanced → AI Chat to use Fazm's built-in Claude."
        }
        if lower.contains("api error") || lower.contains("connection refused") || lower.contains("econnrefused") {
          return "\(cleaned)\n\nThis came from your custom API endpoint (\(endpoint)). Turn off Custom API Endpoint in Settings → Advanced → AI Chat to use Fazm's built-in Claude."
        }
      }
      return cleaned
    }
  }
}
