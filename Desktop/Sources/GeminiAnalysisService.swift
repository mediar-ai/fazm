import Foundation
import GRDB
import PostHog
import SessionReplay

/// Accumulates session recording chunks and periodically sends them to the Gemini API
/// for multimodal video analysis to identify tasks an AI agent could help with.
/// The chunk buffer is persisted to disk so it survives app restarts.
actor GeminiAnalysisService {
    static let shared = GeminiAnalysisService()

    private let analysisPromptTemplate = """
        You are watching ~60 minutes of a user's screen recording. Each video clip captures the active window of whatever app the user was using at that moment. Your job is to identify the ONE most impactful thing an AI agent could do for them. This can be one of two kinds of tasks:

        1. **AUTOMATE** — work the user is doing manually that the AI could take off their plate (default, most common).
        2. **HEAL** — a visible Mac health/system problem the AI could investigate or fix (kernel panic dialogs, beachballs visible across multiple chunks, "your Mac restarted because of a problem", repeated permission popups, low-disk warnings, frozen apps, system error toasts, login keychain prompts on a loop, network failure dialogs, slow-app symptoms the user is clearly fighting).

        Default to AUTOMATE unless you see a *clear* health symptom in the video. Don't infer health issues from "the user looks frustrated" — only flag HEAL when the screen actually shows a system-level problem.

        IMPORTANT: Each recording chunk shows only the focused app window, not the full screen. The metadata below tells you which app and window title was active during each chunk.

        {APP_CONTEXT}

        {USER_CONTEXT}

        ## Tools

        You have tools available to investigate further before making your decision. USE THEM — especially when you see ambiguous activity. You can:
        - `query_database(sql)` — run SELECT queries against the user's local database to check chat history, past discovered tasks, user profile, and indexed files.
        - `read_dev_log(lines)` — read the app's dev log to see what Fazm's AI agent has been doing recently.
        - `get_active_sessions()` — check if Fazm's AI agent is currently processing any tasks right now.

        CRITICAL: If you see terminal, IDE, or browser activity that looks automated (fast typing, command sequences, file edits happening rapidly), call `read_dev_log` or `get_active_sessions` FIRST to check whether Fazm's AI agent is already doing that work. Do NOT suggest automating something that is already being automated by the agent. This is the most common false positive — avoid it.

        MANDATORY — before making any decision, you MUST run these two queries:
        1. Check previously discovered tasks: `SELECT type, category, content, status, createdAt FROM observer_activity WHERE type IN ('gemini_analysis', 'system_signal') ORDER BY createdAt DESC LIMIT 10`
        2. Check recent chat messages: `SELECT sender, messageText, createdAt FROM chat_messages ORDER BY createdAt DESC LIMIT 10`

        If the observer_activity query returns tasks that are similar to what you'd suggest (same app, same type of work, same general activity), return NO_TASK. Users find it annoying to be shown the same suggestion repeatedly. A task is "similar" if it involves the same application AND the same category of work — even if the specific details differ. For example, if a previous task was about "refactoring route files in VS Code" and you'd suggest "updating middleware files in VS Code", those are similar (same app, same category: code editing). Err on the side of NO_TASK when in doubt about similarity.

        ## Decision Criteria

        Be honest about what you can and cannot see. If the video is too blurry, too fast, or you genuinely can't tell what the user is doing, say so — return UNCLEAR. Do NOT invent or guess tasks based on vague visual signals. A wrong suggestion is worse than no suggestion.

        The AI agent has: shell access, Claude Code, native browser control, full file system access, and can execute any task on the user's computer.

        Only flag a task if ALL of these are true:
        - You can clearly see what the user is doing and what they're trying to accomplish
        - The task is concrete and completable (not vague like "help debug" or "improve code")
        - An AI agent could realistically do it 5x faster than the user
        - The AI agent's known weaknesses (slower at visual tasks, can't do real-time interaction) won't make it slower
        - The task is NOT already being handled by Fazm's AI agent (check with tools if unsure)
        - The task has NOT been previously suggested (you checked observer_activity above — if a similar task exists there, return NO_TASK)
        - The task is relevant to the user's goals and current work context

        AI agents are FASTER at: bulk text processing, searching codebases, running shell commands, filling forms with known data, writing boilerplate code, data transformation, file operations across many files, research, lookups.
        AI agents are SLOWER at: browsing casually, visual inspection, creative decisions, real-time human judgment.

        ## Response Format

        After using any tools you need, respond in this exact format:

        VERDICT: NO_TASK or TASK_FOUND or UNCLEAR
        CATEGORY: (only if TASK_FOUND) automate or heal — see definitions above. Default to automate.
        TASK: (only if TASK_FOUND) One sentence: what the user is trying to accomplish overall, and one concrete action the agent would take to help. For heal tasks, frame it as the symptom + the diagnostic the agent would run first (read-only, never destructive).
        DESCRIPTION: (only if TASK_FOUND) 3-5 sentences: what you observed the user doing, what apps/tools they were using, what patterns you noticed (e.g. repetitive actions, context switching, manual work that could be automated; for heal: which system symptom you saw and where on screen). Why this specific task is a strong candidate for AI assistance.
        DOCUMENT: (only if TASK_FOUND) A detailed write-up in markdown format. Include: ## What Was Observed (timeline of what the user did, apps used, files touched), ## The Task (exactly what needs to be done, scope, inputs/outputs), ## Why AI Can Help (what makes this suitable for automation — repetitive, mechanical, well-defined pattern; for heal: which read-only diagnostics make sense first), ## Recommended Approach (step-by-step how an AI agent would execute this — for heal tasks, read-only diagnostics first, propose fixes only after explicit user approval, never assume sudo). Be specific and reference actual apps, filenames, or patterns you saw in the recording.

        Return UNCLEAR if: you can't make out what the user is doing, the content is ambiguous, or you'd be guessing. It's better to say "I'm not sure" than to suggest a task the user never needed.
        Return NO_TASK if: you can clearly see what the user is doing but there's nothing an AI agent could meaningfully help with.
        """

    private let model = "gemini-pro-latest"
    private let maxChunks = 120  // Hard cap on buffered chunks (safety limit)
    private let targetDurationSeconds: TimeInterval = 3600  // Trigger analysis after 60 min of recordings
    /// Gemini File API: chunks above this size use resumable upload; smaller ones use inline base64.
    private let inlineSizeLimit = 1_500_000 // 1.5 MB

    /// Buffer of chunk entries waiting for analysis (persisted to disk as JSON).
    private var chunkBuffer: [ChunkEntry] = []
    private var isAnalyzing = false
    /// Cooldown after failed analysis to avoid spamming the API.
    private var lastFailedAnalysis: Date?
    private let retryCooldown: TimeInterval = 300 // 5 minutes

    /// Stable directory for chunk video files (inside Application Support, survives restarts).
    private let chunksDir: URL
    /// JSON file that persists the buffer index across restarts.
    private let bufferIndexURL: URL

    struct ActiveAppInfo: Codable, Sendable {
        let appName: String
        let windowTitle: String?
        let frameCount: Int
    }

    struct ChunkEntry: Codable, Sendable {
        let localURL: URL
        let chunkIndex: Int
        let startTimestamp: Date
        let endTimestamp: Date
        let activeApps: [ActiveAppInfo]
    }

    struct UsageMetrics: Sendable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var totalTokens: Int = 0

        mutating func add(_ other: UsageMetrics) {
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            totalTokens += other.totalTokens
        }
    }

    struct AnalysisResult: Sendable {
        let verdict: String  // "NO_TASK" or "TASK_FOUND"
        let category: String  // "automate" or "heal"
        let task: String?
        let description: String?
        let document: String?
        let raw: String
        let chunksAnalyzed: Int
        let toolCallCount: Int
        let turnsUsed: Int
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
    }

    /// Chunk info passed from SessionRecordingManager when a chunk is finalized.
    struct ChunkInfo: Sendable {
        let localURL: URL
        let chunkIndex: Int
        let startTimestamp: Date
        let endTimestamp: Date
        let activeApps: [ActiveAppInfo]
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Fazm/gemini-analysis", isDirectory: true)
        self.chunksDir = baseDir.appendingPathComponent("chunks", isDirectory: true)
        self.bufferIndexURL = baseDir.appendingPathComponent("buffer-index.json")

        try? FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        // Restore persisted buffer
        if let data = try? Data(contentsOf: bufferIndexURL),
           var entries = try? JSONDecoder().decode([ChunkEntry].self, from: data) {
            // Prune entries whose files no longer exist on disk
            entries.removeAll { !FileManager.default.fileExists(atPath: $0.localURL.path) }
            self.chunkBuffer = entries
            log("GeminiAnalysis: restored \(entries.count) chunks from disk")
        }

        // Clean up orphaned files not tracked by the buffer index
        let indexedFiles = Set(chunkBuffer.map { $0.localURL.lastPathComponent })
        if let allFiles = try? FileManager.default.contentsOfDirectory(atPath: chunksDir.path) {
            let orphans = allFiles.filter { $0.hasSuffix(".mp4") && !indexedFiles.contains($0) }
            for orphan in orphans {
                try? FileManager.default.removeItem(at: chunksDir.appendingPathComponent(orphan))
            }
            if !orphans.isEmpty {
                log("GeminiAnalysis: cleaned up \(orphans.count) orphaned chunk files")
            }
        }
    }

    /// Called by SessionRecordingManager when a chunk is finalized.
    /// Copies the file to a stable location and persists the buffer index.
    func handleChunk(_ info: ChunkInfo) {
        // Check if screen observer is disabled in settings
        guard UserDefaults.standard.object(forKey: "shortcut_screenObserverEnabled") as? Bool ?? true else {
            return
        }

        // Move (not copy) the chunk into Application Support. We need a stable
        // location because the buffer can hold chunks for up to ~1h before Gemini
        // analysis runs, and macOS may purge ~/Library/Caches under disk pressure.
        // Moving instead of copying also ensures observer-recordings/ doesn't grow
        // unbounded — observer mode has no uploader, so the library never deletes
        // the original from Caches on its own.
        let stableFile = chunksDir.appendingPathComponent("chunk_\(info.chunkIndex)_\(Int(info.startTimestamp.timeIntervalSince1970)).mp4")
        do {
            try? FileManager.default.removeItem(at: stableFile)  // clear any leftover at target
            try FileManager.default.moveItem(at: info.localURL, to: stableFile)
        } catch {
            log("GeminiAnalysis: failed to move chunk \(info.localURL.lastPathComponent) -> \(stableFile.lastPathComponent): \(error)")
            return
        }

        let entry = ChunkEntry(
            localURL: stableFile,
            chunkIndex: info.chunkIndex,
            startTimestamp: info.startTimestamp,
            endTimestamp: info.endTimestamp,
            activeApps: info.activeApps
        )
        chunkBuffer.append(entry)

        // Cap at maxChunks — drop oldest if over
        if chunkBuffer.count > maxChunks {
            let excess = chunkBuffer.prefix(chunkBuffer.count - maxChunks)
            for old in excess {
                try? FileManager.default.removeItem(at: old.localURL)
            }
            chunkBuffer.removeFirst(chunkBuffer.count - maxChunks)
        }

        persistBufferIndex()

        let totalDuration = bufferedDuration
        let totalMinutes = Int(totalDuration / 60)
        let targetMinutes = Int(targetDurationSeconds / 60)
        log("GeminiAnalysis: buffered chunk \(info.chunkIndex) (\(chunkBuffer.count) chunks, \(totalMinutes)/\(targetMinutes) min)")

        // Trigger analysis when total buffered duration reaches the target (with cooldown after failures)
        if totalDuration >= targetDurationSeconds && !isAnalyzing {
            if let lastFail = lastFailedAnalysis, Date().timeIntervalSince(lastFail) < retryCooldown {
                // Still in cooldown — skip retry
            } else {
                Task { await triggerAnalysis() }
            }
        }
    }

    /// Force analysis with whatever chunks are buffered (e.g., on app quit or manual trigger).
    func analyzeNow() async -> AnalysisResult? {
        guard !chunkBuffer.isEmpty, !isAnalyzing else { return nil }
        guard UserDefaults.standard.object(forKey: "shortcut_screenObserverEnabled") as? Bool ?? true else { return nil }
        return await triggerAnalysis()
    }

    /// Run analysis on the current buffer. Only clears buffer and deletes files on success.
    private func triggerAnalysis() async -> AnalysisResult? {
        let chunks = Array(chunkBuffer)
        let analyzedCount = chunks.count
        let result = await runAnalysis(chunks: chunks)
        if let result {
            // Track the analysis result in PostHog
            var properties: [String: Any] = [
                "verdict": result.verdict,
                "category": result.category,
                "chunks_analyzed": result.chunksAnalyzed,
                "response": result.raw,
                "tool_call_count": result.toolCallCount,
                "turns_used": result.turnsUsed,
                "input_tokens": result.inputTokens,
                "output_tokens": result.outputTokens,
                "total_tokens": result.totalTokens,
            ]
            if let task = result.task {
                properties["task"] = task
            }
            PostHogSDK.shared.capture("gemini_analysis_completed", properties: properties)

            if result.totalTokens > 0 {
                let usage = result
                Task.detached(priority: .background) {
                    await APIClient.shared.recordLlmUsage(
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        totalTokens: usage.totalTokens,
                        costUsd: 0,
                        account: "observer_gemini"
                    )
                    await APIClient.shared.recordExternalLlmTrace(
                        model: "gemini-2.5-pro",
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens,
                        totalTokens: usage.totalTokens,
                        source: "fazm_observer"
                    )
                }
            }

            // Persist TASK_FOUND results to observer_activity and show overlay
            if result.verdict == "TASK_FOUND", let task = result.task {
                await persistAndShowOverlay(task: task, category: result.category, description: result.description, document: result.document, result: result)
            }

            // Success — remove only the chunks we analyzed (new ones may have arrived during analysis)
            let analyzedURLs = Set(chunks.map { $0.localURL })
            chunkBuffer.removeAll { analyzedURLs.contains($0.localURL) }
            persistBufferIndex()
            cleanupChunkFiles(chunks: chunks)
            log("GeminiAnalysis: cleared \(analyzedCount) chunks after successful analysis, \(chunkBuffer.count) new chunks kept")
        } else {
            // Failed — keep buffer intact, set cooldown before retry
            lastFailedAnalysis = Date()
            PostHogSDK.shared.capture("gemini_analysis_failed", properties: ["chunks_count": analyzedCount])
            log("GeminiAnalysis: analysis failed, keeping \(chunks.count) chunks for retry (cooldown \(Int(retryCooldown))s)")
        }
        return result
    }

    var bufferedChunkCount: Int { chunkBuffer.count }

    /// Total duration of all buffered chunks in seconds.
    var bufferedDuration: TimeInterval {
        chunkBuffer.reduce(0) { $0 + $1.endTimestamp.timeIntervalSince($1.startTimestamp) }
    }

    // MARK: - Persistence

    private func persistBufferIndex() {
        do {
            let data = try JSONEncoder().encode(chunkBuffer)
            try data.write(to: bufferIndexURL, options: .atomic)
        } catch {
            log("GeminiAnalysis: failed to persist buffer index: \(error)")
        }
    }

    // MARK: - Gemini API

    @discardableResult
    private func runAnalysis(chunks: [ChunkEntry]) async -> AnalysisResult? {
        isAnalyzing = true
        defer { isAnalyzing = false }

        guard let apiKey = await resolveAPIKey() else {
            log("GeminiAnalysis: no Gemini API key available")
            return nil
        }

        log("GeminiAnalysis: starting analysis of \(chunks.count) chunks")

        // Gather user context in parallel with chunk upload preparation
        log("GeminiAnalysis: gathering user context...")
        let userContext = await gatherUserContext()
        log("GeminiAnalysis: user context gathered (\(userContext.count) chars)")

        // Upload large chunks via File API, prepare inline parts for small ones
        var parts: [[String: Any]] = []
        var uploadedFileNames: [String] = []

        for chunk in chunks {
            guard let data = try? Data(contentsOf: chunk.localURL) else { continue }

            if data.count <= inlineSizeLimit {
                // Inline base64
                parts.append([
                    "inlineData": [
                        "mimeType": "video/mp4",
                        "data": data.base64EncodedString()
                    ]
                ])
            } else {
                // Upload via File API
                if let fileInfo = await uploadToFileAPI(data: data, name: "chunk_\(chunk.chunkIndex).mp4", apiKey: apiKey) {
                    uploadedFileNames.append(fileInfo.name)
                    // Wait for processing
                    let ready = await waitForProcessing(fileName: fileInfo.name, apiKey: apiKey)
                    if ready {
                        parts.append([
                            "fileData": [
                                "mimeType": "video/mp4",
                                "fileUri": fileInfo.uri
                            ]
                        ])
                    }
                }
            }
        }

        // Build app context summary from chunk metadata
        let appContext = buildAppContextSummary(chunks: chunks)
        let prompt = analysisPromptTemplate
            .replacingOccurrences(of: "{APP_CONTEXT}", with: appContext)
            .replacingOccurrences(of: "{USER_CONTEXT}", with: userContext)

        // Add the prompt as the last part
        parts.append(["text": prompt])

        // Call generateContent with agentic loop (function calling enabled)
        let (result, toolCallCount, turnsUsed, usage) = await callGenerateContentAgentic(
            initialParts: parts,
            tools: toolDeclarations,
            apiKey: apiKey,
            maxTurns: 5
        )

        // Cleanup uploaded Gemini File API files (these are remote, always safe to delete)
        for fileName in uploadedFileNames {
            Task { await deleteFile(fileName: fileName, apiKey: apiKey) }
        }

        guard let raw = result else {
            log("GeminiAnalysis: generateContent returned no result")
            return nil
        }

        let parsed = parseResult(
            raw,
            chunksAnalyzed: chunks.count,
            toolCallCount: toolCallCount,
            turnsUsed: turnsUsed,
            usage: usage
        )
        log(
            "GeminiAnalysis: \(parsed.verdict) (\(chunks.count) chunks, \(toolCallCount) tool calls, \(turnsUsed) turns, tokens=\(parsed.inputTokens)+\(parsed.outputTokens)=\(parsed.totalTokens))"
        )
        if let task = parsed.task {
            log("GeminiAnalysis: task=\(task)")
        }
        return parsed
    }

    private func resolveAPIKey() async -> String? {
        await KeyService.shared.ensureKeys(timeout: 5)
        return KeyService.shared.geminiAPIKey
    }

    // MARK: - User Context Gathering

    /// Gather all user context to inject into the analysis prompt.
    private func gatherUserContext() async -> String {
        var sections: [String] = []

        // User identity (AuthService is not Sendable — read on main actor)
        let userName = await MainActor.run {
            AuthService.shared.displayName.isEmpty ? "Unknown" : AuthService.shared.displayName
        }
        let timezone = TimeZone.current.identifier
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone.current
        let now = dateFormatter.string(from: Date())
        sections.append("<user_identity>\nName: \(userName)\nTimezone: \(timezone)\nCurrent time: \(now)\n</user_identity>")

        // AI user profile
        if let profile = await AIUserProfileService.shared.getLatestProfile(),
           !profile.profileText.isEmpty {
            let truncated = String(profile.profileText.prefix(2000))
            sections.append("<user_profile>\n\(truncated)\n</user_profile>")
            log("GeminiAnalysis: injected user profile (\(truncated.count) chars)")
        }

        // Recent chat messages (what the user has been asking Fazm)
        let messages = await ChatMessageStore.loadMessages(context: "__floating__", limit: 20)
        if !messages.isEmpty {
            var chatLines: [String] = []
            for msg in messages {
                let role = msg.sender == .user ? "User" : "Fazm"
                let text = String(msg.text.prefix(300))
                chatLines.append("[\(role)] \(text)")
            }
            sections.append("<recent_conversations>\nRecent messages between the user and Fazm's AI assistant (newest last):\n\(chatLines.joined(separator: "\n"))\n</recent_conversations>")
            log("GeminiAnalysis: injected \(messages.count) recent chat messages")
        }

        // Database schema (so Gemini knows what queries are possible)
        let schema = await loadDatabaseSchema()
        if !schema.isEmpty {
            sections.append("<database_schema>\n\(schema)\n</database_schema>")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Load the database schema using the same format as ChatProvider.
    private func loadDatabaseSchema() async -> String {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return "" }
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

            var lines: [String] = ["Database schema (fazm.db):"]
            for (name, sql) in tables {
                if ChatPrompts.excludedTables.contains(name) { continue }
                if ChatPrompts.excludedTablePrefixes.contains(where: { name.hasPrefix($0) }) { continue }
                if name.contains("_fts") { continue }

                // Extract column names from CREATE TABLE DDL
                let columnNames = extractColumnNames(from: sql).filter {
                    !ChatPrompts.excludedColumns.contains($0)
                }
                guard !columnNames.isEmpty else { continue }

                let annotation = ChatPrompts.tableAnnotations[name] ?? ""
                let header = annotation.isEmpty ? name : "\(name) — \(annotation)"
                lines.append(header)
                lines.append("  \(columnNames.joined(separator: ", "))")
            }
            lines.append(ChatPrompts.schemaFooter)
            return lines.joined(separator: "\n")
        } catch {
            log("GeminiAnalysis: failed to load schema: \(error)")
            return ""
        }
    }

    /// Extract column names from a CREATE TABLE SQL statement.
    private func extractColumnNames(from sql: String) -> [String] {
        // Find the content between the first ( and last )
        guard let openParen = sql.firstIndex(of: "("),
              let closeParen = sql.lastIndex(of: ")") else { return [] }
        let inner = String(sql[sql.index(after: openParen)..<closeParen])

        var names: [String] = []
        for part in inner.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip constraints (PRIMARY KEY, UNIQUE, CHECK, FOREIGN KEY)
            let upper = trimmed.uppercased()
            if upper.hasPrefix("PRIMARY") || upper.hasPrefix("UNIQUE") ||
               upper.hasPrefix("CHECK") || upper.hasPrefix("FOREIGN") ||
               upper.hasPrefix("CONSTRAINT") { continue }

            // First token is the column name
            if let name = trimmed.components(separatedBy: .whitespaces).first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")),
               !name.isEmpty {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - Gemini Function Calling (Tool Declarations)

    /// Tool declarations for the Gemini function calling API.
    private var toolDeclarations: [[String: Any]] {
        [[
            "functionDeclarations": [
                [
                    "name": "query_database",
                    "description": "Execute a read-only SQL SELECT query against the user's local fazm.db database. Tables include: chat_messages (conversation history), observer_activity (past discovered tasks, insights), ai_user_profiles (AI-generated user summaries), indexed_files (file metadata from Downloads/Documents/Desktop). Only SELECT queries are allowed.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "sql": ["type": "string", "description": "A SELECT SQL query to execute against the database"]
                        ],
                        "required": ["sql"]
                    ] as [String: Any]
                ] as [String: Any],
                [
                    "name": "read_dev_log",
                    "description": "Read the last N lines of Fazm's development log to see what the app and its AI agent have been doing recently. Useful for detecting if the AI agent is currently running automated tasks (you'll see ACP bridge messages, tool calls, query processing). If you see terminal/IDE activity in the video, check this log to determine if it's the AI agent working.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "lines": ["type": "integer", "description": "Number of lines to read from the end of the log (max 200, default 50)"]
                        ],
                        "required": ["lines"]
                    ] as [String: Any]
                ] as [String: Any],
                [
                    "name": "get_active_sessions",
                    "description": "Check if Fazm's AI agent is currently processing any tasks. Returns information about active ACP (Agent Control Protocol) sessions and recent tool activity. Use this when you see automated-looking activity in the video to avoid suggesting tasks the agent is already handling.",
                    "parameters": [
                        "type": "object",
                        "properties": [:] as [String: Any],
                        "required": [] as [String]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]]
    }

    // MARK: - Tool Execution

    private static let blockedSQLKeywords = [
        "DROP", "ALTER", "TRUNCATE", "CREATE", "ATTACH", "DETACH", "VACUUM", "REINDEX", "PRAGMA"
    ]

    /// Execute a tool call from Gemini and return the result string.
    private func executeTool(name: String, args: [String: Any]) async -> String {
        log("GeminiAnalysis: executing tool \(name) with args: \(args)")
        switch name {
        case "query_database":
            return await executeQueryDatabase(args: args)
        case "read_dev_log":
            return executeReadDevLog(args: args)
        case "get_active_sessions":
            return executeGetActiveSessions()
        default:
            return "Error: unknown tool '\(name)'"
        }
    }

    /// Execute a SELECT-only SQL query against fazm.db.
    private func executeQueryDatabase(args: [String: Any]) async -> String {
        guard let sql = args["sql"] as? String, !sql.isEmpty else {
            return "Error: sql parameter is required"
        }

        var sanitized = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fix common LLM SQL mistakes
        sanitized = sanitized.replacingOccurrences(of: "\\'", with: "''")
        let upper = sanitized.uppercased()

        // Block dangerous keywords
        for keyword in Self.blockedSQLKeywords {
            if upper.range(of: "\\b\(keyword)\\b", options: .regularExpression) != nil {
                return "Error: \(keyword) statements are not allowed. Only SELECT queries."
            }
        }

        // Must be SELECT or WITH
        guard upper.hasPrefix("SELECT") || upper.hasPrefix("WITH") else {
            return "Error: only SELECT queries are allowed"
        }

        // Block multi-statement
        let statements = sanitized.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if statements.count > 1 {
            return "Error: only single statements allowed"
        }

        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
            return "Error: database not available"
        }

        do {
            // Auto-append LIMIT if missing
            var finalQuery = sanitized
            if !upper.contains("LIMIT") {
                if finalQuery.hasSuffix(";") { finalQuery = String(finalQuery.dropLast()) }
                finalQuery += " LIMIT 100"
            }

            let query = finalQuery
            let rows = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: query)
            }

            if rows.isEmpty { return "No results" }

            let columns = Array(rows[0].columnNames)
            var lines: [String] = [columns.joined(separator: " | ")]
            lines.append(String(repeating: "-", count: min(columns.count * 20, 120)))

            for row in rows.prefix(100) {
                let values = row.map { (_, dbValue) -> String in
                    let value: String
                    switch dbValue.storage {
                    case .null: value = "NULL"
                    case .int64(let i): value = String(i)
                    case .double(let d): value = String(d)
                    case .string(let s): value = s
                    case .blob(let data): value = "<\(data.count) bytes>"
                    }
                    return value.count > 300 ? String(value.prefix(300)) + "..." : value
                }
                lines.append(values.joined(separator: " | "))
            }
            lines.append("\(rows.count) row(s)")

            // Cap total response size
            var result = lines.joined(separator: "\n")
            if result.count > 4000 {
                result = String(result.prefix(4000)) + "\n... (truncated)"
            }
            return result
        } catch {
            return "SQL Error: \(error.localizedDescription)"
        }
    }

    /// Read the last N lines of the dev log.
    private func executeReadDevLog(args: [String: Any]) -> String {
        let requestedLines = min(args["lines"] as? Int ?? 50, 200)

        // Try dev log first, then prod log
        let devPath = "/private/tmp/fazm-dev.log"
        let prodPath = "/private/tmp/fazm.log"
        let logPath = FileManager.default.fileExists(atPath: devPath) ? devPath : prodPath

        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return "No log file available"
        }

        let allLines = content.components(separatedBy: "\n")
        let tail = allLines.suffix(requestedLines)
        var result = tail.joined(separator: "\n")
        if result.count > 4000 {
            result = String(result.prefix(4000)) + "\n... (truncated)"
        }
        return result
    }

    /// Check for active ACP sessions by parsing the dev log for recent activity.
    private func executeGetActiveSessions() -> String {
        let devPath = "/private/tmp/fazm-dev.log"
        let prodPath = "/private/tmp/fazm.log"
        let logPath = FileManager.default.fileExists(atPath: devPath) ? devPath : prodPath

        guard let data = FileManager.default.contents(atPath: logPath),
              let content = String(data: data, encoding: .utf8) else {
            return "No log file available to determine session status"
        }

        // Look at the last 200 lines for ACP activity
        let allLines = content.components(separatedBy: "\n")
        let recentLines = allLines.suffix(200)

        var acpActivity: [String] = []
        var activeQueries: [String] = []

        for line in recentLines {
            // Check for ACP bridge activity
            if line.contains("ACPBridge:") || line.contains("acp") {
                acpActivity.append(String(line.prefix(200)))
            }
            // Check for active query processing
            if line.contains("query") && (line.contains("streaming") || line.contains("processing") || line.contains("tool_use")) {
                activeQueries.append(String(line.prefix(200)))
            }
        }

        var result = "Active Session Status:\n"
        if acpActivity.isEmpty && activeQueries.isEmpty {
            result += "No recent ACP agent activity detected. The AI agent appears idle."
        } else {
            if !activeQueries.isEmpty {
                result += "Recent agent query activity (may indicate active task):\n"
                for line in activeQueries.suffix(10) {
                    result += "  \(line)\n"
                }
            }
            if !acpActivity.isEmpty {
                result += "Recent ACP bridge activity:\n"
                for line in acpActivity.suffix(10) {
                    result += "  \(line)\n"
                }
            }
        }

        return result
    }

    // MARK: - Agentic Multi-Turn API

    /// Call Gemini with function calling support. Loops up to maxTurns when the model calls tools.
    /// Returns the final text response after all tool calls are resolved.
    private func callGenerateContentAgentic(
        initialParts: [[String: Any]],
        tools: [[String: Any]],
        apiKey: String,
        maxTurns: Int = 5
    ) async -> (text: String?, toolCallCount: Int, turnsUsed: Int, usage: UsageMetrics) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            return (nil, 0, 0, UsageMetrics())
        }

        var contents: [[String: Any]] = [["role": "user", "parts": initialParts]]
        var totalToolCalls = 0
        var totalUsage = UsageMetrics()

        for turn in 1...maxTurns {
            let body: [String: Any] = [
                "contents": contents,
                "tools": tools,
                "generationConfig": [
                    "temperature": 0.3,
                    "maxOutputTokens": 16384
                ],
                "safetySettings": [
                    ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                    ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                    ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                    ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
                ]
            ]

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            // Retry up to 3 times per turn
            var responseParts: [[String: Any]]?
            var turnUsage = UsageMetrics()
            for attempt in 1...3 {
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      let http = resp as? HTTPURLResponse else {
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                    }
                    continue
                }

                if (200...299).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let content = candidates.first?["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    responseParts = parts
                    if let usageJson = json["usageMetadata"] as? [String: Any] {
                        turnUsage = parseUsageMetadata(usageJson)
                    }
                    break
                }

                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                log("GeminiAnalysis: agentic turn \(turn) attempt \(attempt) failed (status=\(http.statusCode)): \(bodyStr.prefix(200))")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                }
            }

            guard let parts = responseParts else {
                log("GeminiAnalysis: agentic turn \(turn) failed after retries")
                return (nil, totalToolCalls, turn, totalUsage)
            }

            totalUsage.add(turnUsage)

            // Check if the response contains function calls
            var functionCalls: [(name: String, args: [String: Any])] = []
            var textParts: [String] = []

            for part in parts {
                if let fc = part["functionCall"] as? [String: Any],
                   let name = fc["name"] as? String {
                    let args = fc["args"] as? [String: Any] ?? [:]
                    functionCalls.append((name: name, args: args))
                }
                if let text = part["text"] as? String {
                    textParts.append(text)
                }
            }

            // If no function calls, we're done — return the text
            if functionCalls.isEmpty {
                let finalText = textParts.joined(separator: "\n")
                log("GeminiAnalysis: agentic loop completed in \(turn) turn(s), \(totalToolCalls) tool call(s)")
                return (finalText.isEmpty ? nil : finalText, totalToolCalls, turn, totalUsage)
            }

            // Append model's response to conversation
            contents.append(["role": "model", "parts": parts])

            // Execute each function call and build response parts
            var functionResponseParts: [[String: Any]] = []
            for fc in functionCalls {
                totalToolCalls += 1
                log("GeminiAnalysis: tool call #\(totalToolCalls): \(fc.name)")
                let result = await executeTool(name: fc.name, args: fc.args)
                functionResponseParts.append([
                    "functionResponse": [
                        "name": fc.name,
                        "response": ["result": result]
                    ] as [String: Any]
                ])
            }

            // Append tool results as user turn
            contents.append(["role": "user", "parts": functionResponseParts])
        }

        log("GeminiAnalysis: exhausted \(maxTurns) agentic turns")
        return (nil, totalToolCalls, maxTurns, totalUsage)
    }

    // MARK: - Gemini File API (Resumable Upload)

    private struct FileInfo {
        let name: String
        let uri: String
    }

    private func uploadToFileAPI(data: Data, name: String, apiKey: String) async -> FileInfo? {
        // Step 1: Start resumable upload
        guard let startURL = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files?key=\(apiKey)") else { return nil }

        var startReq = URLRequest(url: startURL)
        startReq.httpMethod = "POST"
        startReq.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startReq.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startReq.setValue("video/mp4", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startReq.setValue("\(data.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata = ["file": ["display_name": name]]
        startReq.httpBody = try? JSONSerialization.data(withJSONObject: metadata)

        let startResult: (Data, URLResponse)
        do {
            startResult = try await URLSession.shared.data(for: startReq)
        } catch {
            log("GeminiAnalysis: File API start failed for \(name) (network: \(error.localizedDescription))")
            return nil
        }
        guard let httpResp = startResult.1 as? HTTPURLResponse,
              let uploadURL = httpResp.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            let body = String(data: startResult.0, encoding: .utf8) ?? ""
            let status = (startResult.1 as? HTTPURLResponse)?.statusCode ?? -1
            log("GeminiAnalysis: File API start failed for \(name) (status=\(status)): \(body.prefix(300))")
            return nil
        }

        // Step 2: Upload the bytes
        guard let upURL = URL(string: uploadURL) else { return nil }
        var upReq = URLRequest(url: upURL)
        upReq.httpMethod = "PUT"
        upReq.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        upReq.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upReq.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upReq.httpBody = data

        guard let (upData, upResp) = try? await URLSession.shared.data(for: upReq),
              let upHttp = upResp as? HTTPURLResponse,
              (200...299).contains(upHttp.statusCode),
              let json = try? JSONSerialization.jsonObject(with: upData) as? [String: Any],
              let file = json["file"] as? [String: Any],
              let fileName = file["name"] as? String,
              let fileUri = file["uri"] as? String else {
            log("GeminiAnalysis: File API upload failed for \(name)")
            return nil
        }

        return FileInfo(name: fileName, uri: fileUri)
    }

    private func waitForProcessing(fileName: String, apiKey: String, maxWait: TimeInterval = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)

        while Date() < deadline {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)?key=\(apiKey)"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String else {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }

            if state == "ACTIVE" { return true }
            if state == "FAILED" { return false }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        return false
    }

    private func deleteFile(fileName: String, apiKey: String) async {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)?key=\(apiKey)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Generate Content

    private func callGenerateContent(parts: [[String: Any]], apiKey: String) async -> String? {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else { return nil }

        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 16384
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"],
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300 // 5 min for large video analysis
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Retry up to 3 times
        for attempt in 1...3 {
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                }
                continue
            }

            if (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let contentParts = content["parts"] as? [[String: Any]],
               let text = contentParts.first?["text"] as? String {
                return text
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            log("GeminiAnalysis: generateContent attempt \(attempt) failed (status=\(http.statusCode)): \(bodyStr.prefix(200))")

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// Build a text summary of which apps/windows were active across chunks, for the Gemini prompt.
    private func buildAppContextSummary(chunks: [ChunkEntry]) -> String {
        guard chunks.contains(where: { !$0.activeApps.isEmpty }) else {
            return "No app metadata available for these recordings."
        }

        // Aggregate frame counts across all chunks
        var appTotals: [String: (appName: String, windowTitle: String?, totalFrames: Int)] = [:]
        for chunk in chunks {
            for app in chunk.activeApps {
                let key = "\(app.appName)||\(app.windowTitle ?? "")"
                if var existing = appTotals[key] {
                    existing.totalFrames += app.frameCount
                    appTotals[key] = existing
                } else {
                    appTotals[key] = (appName: app.appName, windowTitle: app.windowTitle, totalFrames: app.frameCount)
                }
            }
        }

        let totalFrames = appTotals.values.reduce(0) { $0 + $1.totalFrames }
        guard totalFrames > 0 else { return "No app metadata available for these recordings." }

        let sorted = appTotals.values.sorted { $0.totalFrames > $1.totalFrames }
        var lines = ["Apps the user was using (sorted by time spent):"]
        for entry in sorted {
            let pct = Int(Double(entry.totalFrames) / Double(totalFrames) * 100)
            let title = entry.windowTitle.map { " — \"\($0)\"" } ?? ""
            lines.append("- \(entry.appName)\(title) (\(pct)% of time)")
        }

        return lines.joined(separator: "\n")
    }

    private func parseResult(
        _ raw: String,
        chunksAnalyzed: Int,
        toolCallCount: Int = 0,
        turnsUsed: Int = 0,
        usage: UsageMetrics = UsageMetrics()
    ) -> AnalysisResult {
        let lines = raw.components(separatedBy: "\n")

        var verdict = "NO_TASK"
        var category = "automate"
        var task: String?
        var description: String?
        var document: String?
        var inDocument = false
        var documentLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inDocument {
                // Everything after DOCUMENT: is part of the document
                documentLines.append(line)
            } else if trimmed.hasPrefix("VERDICT:") {
                verdict = trimmed.replacingOccurrences(of: "VERDICT:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("CATEGORY:") {
                let raw = trimmed.replacingOccurrences(of: "CATEGORY:", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                category = (raw == "heal") ? "heal" : "automate"
            } else if trimmed.hasPrefix("TASK:") {
                task = trimmed.replacingOccurrences(of: "TASK:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("DESCRIPTION:") {
                description = trimmed.replacingOccurrences(of: "DESCRIPTION:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("DOCUMENT:") {
                inDocument = true
                let firstLine = trimmed.replacingOccurrences(of: "DOCUMENT:", with: "").trimmingCharacters(in: .whitespaces)
                if !firstLine.isEmpty { documentLines.append(firstLine) }
            }
        }

        if !documentLines.isEmpty {
            document = documentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return AnalysisResult(
            verdict: verdict,
            category: category,
            task: task,
            description: description,
            document: document,
            raw: raw,
            chunksAnalyzed: chunksAnalyzed,
            toolCallCount: toolCallCount,
            turnsUsed: turnsUsed,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            totalTokens: usage.totalTokens
        )
    }

    private func parseUsageMetadata(_ usageJson: [String: Any]) -> UsageMetrics {
        let inputTokens = intValue(usageJson["promptTokenCount"])
        let outputTokens = intValue(usageJson["candidatesTokenCount"])
        let totalTokens = {
            let rawTotal = intValue(usageJson["totalTokenCount"])
            return rawTotal > 0 ? rawTotal : inputTokens + outputTokens
        }()

        return UsageMetrics(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }

    private func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let intValue = Int(string) {
            return intValue
        }
        return 0
    }

    private func cleanupChunkFiles(chunks: [ChunkEntry]) {
        for chunk in chunks {
            try? FileManager.default.removeItem(at: chunk.localURL)
        }
    }

    // MARK: - Persistence & Overlay

    /// Insert the analysis result into observer_activity and show the overlay above the floating bar.
    private func persistAndShowOverlay(task: String, category: String, description: String?, document: String?, result: AnalysisResult) async {
        // 1. Persist to observer_activity
        var activityId: Int64 = 0
        if let dbQueue = await AppDatabase.shared.getDatabaseQueue() {
            do {
                var contentJson: [String: Any] = [
                    "task": task,
                    "category": category,
                    "chunks_analyzed": result.chunksAnalyzed,
                    "raw": result.raw,
                    "input_tokens": result.inputTokens,
                    "output_tokens": result.outputTokens,
                    "total_tokens": result.totalTokens,
                ]
                if let description { contentJson["description"] = description }
                if let document { contentJson["document"] = document }
                let contentString = String(data: try JSONSerialization.data(withJSONObject: contentJson), encoding: .utf8) ?? task

                activityId = try await dbQueue.write { db -> Int64 in
                    try db.execute(
                        sql: """
                            INSERT INTO observer_activity (type, category, content, status, createdAt)
                            VALUES (?, ?, ?, 'pending', datetime('now'))
                        """,
                        arguments: ["gemini_analysis", category, contentString]
                    )
                    return db.lastInsertedRowID
                }
                log("GeminiAnalysis: persisted to observer_activity id=\(activityId) category=\(category)")

                // Track creation so we can measure discovery rate, automate vs heal mix,
                // and the funnel from created → shown → discussed/dismissed/ignored.
                // PostHogManager is @MainActor, so hop there from this async context.
                await MainActor.run {
                    PostHogManager.shared.track("discovered_task_created", properties: [
                        "task_id": activityId,
                        "task_category": category,
                        "task_title": String(task.prefix(100)),
                        "source": "gemini_analysis",
                        "type": "gemini_analysis",
                        "chunks_analyzed": result.chunksAnalyzed,
                        "input_tokens": result.inputTokens,
                        "output_tokens": result.outputTokens,
                    ])
                }
            } catch {
                log("GeminiAnalysis: failed to persist to DB: \(error)")
            }
        }

        // 2. Show overlay on main thread
        let savedId = activityId
        let desc = description
        let doc = document
        let cat = category
        await MainActor.run {
            if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
                AnalysisOverlayWindow.shared.show(below: barFrame, task: task, category: cat, description: desc, document: doc, activityId: savedId)
            } else {
                log("GeminiAnalysis: no bar frame available, skipping overlay")
            }
        }
    }
}
