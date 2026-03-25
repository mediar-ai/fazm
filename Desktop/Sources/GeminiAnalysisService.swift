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
        You are watching ~60 minutes of a user's screen recording. Each video clip captures the active window of whatever app the user was using at that moment. Your job is to identify the ONE most impactful task an AI agent could take off their plate.

        IMPORTANT: Each recording chunk shows only the focused app window, not the full screen. The metadata below tells you which app and window title was active during each chunk.

        {APP_CONTEXT}

        Be honest about what you can and cannot see. If the video is too blurry, too fast, or you genuinely can't tell what the user is doing, say so — return UNCLEAR. Do NOT invent or guess tasks based on vague visual signals. A wrong suggestion is worse than no suggestion.

        The AI agent has: shell access, Claude Code, native browser control, full file system access, and can execute any task on the user's computer.

        Only flag a task if ALL of these are true:
        - You can clearly see what the user is doing and what they're trying to accomplish
        - The task is concrete and completable (not vague like "help debug" or "improve code")
        - An AI agent could realistically do it 5x faster than the user
        - The AI agent's known weaknesses (slower at visual tasks, can't do real-time interaction) won't make it slower

        AI agents are FASTER at: bulk text processing, searching codebases, running shell commands, filling forms with known data, writing boilerplate code, data transformation, file operations across many files, research, lookups.
        AI agents are SLOWER at: browsing casually, visual inspection, creative decisions, real-time human judgment.

        Respond in this exact format:

        VERDICT: NO_TASK or TASK_FOUND or UNCLEAR
        TASK: (only if TASK_FOUND) One sentence: what the user is trying to accomplish overall, and one concrete action the agent would take to help.
        DESCRIPTION: (only if TASK_FOUND) 3-5 sentences: what you observed the user doing, what apps/tools they were using, what patterns you noticed (e.g. repetitive actions, context switching, manual work that could be automated), and why this specific task is a strong candidate for AI assistance.
        DOCUMENT: (only if TASK_FOUND) A detailed write-up in markdown format. Include: ## What Was Observed (timeline of what the user did, apps used, files touched), ## The Task (exactly what needs to be done, scope, inputs/outputs), ## Why AI Can Help (what makes this suitable for automation — repetitive, mechanical, well-defined pattern), ## Recommended Approach (step-by-step how an AI agent would execute this). Be specific and reference actual apps, filenames, or patterns you saw in the recording.

        Return UNCLEAR if: you can't make out what the user is doing, the content is ambiguous, or you'd be guessing. It's better to say "I'm not sure" than to suggest a task the user never needed.
        Return NO_TASK if: you can clearly see what the user is doing but there's nothing an AI agent could meaningfully help with.
        """

    private let model = "gemini-pro-latest"
    private let maxChunks = 60
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

    struct AnalysisResult: Sendable {
        let verdict: String  // "NO_TASK" or "TASK_FOUND"
        let task: String?
        let description: String?
        let document: String?
        let raw: String
        let chunksAnalyzed: Int
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
    }

    /// Called by SessionRecordingManager when a chunk is finalized.
    /// Copies the file to a stable location and persists the buffer index.
    func handleChunk(_ info: ChunkInfo) {
        // Read file data now, before upload deletes the local file
        guard let data = try? Data(contentsOf: info.localURL) else {
            log("GeminiAnalysis: failed to read chunk at \(info.localURL.path)")
            return
        }

        // Store in stable Application Support directory
        let stableFile = chunksDir.appendingPathComponent("chunk_\(info.chunkIndex)_\(Int(info.startTimestamp.timeIntervalSince1970)).mp4")
        do {
            try data.write(to: stableFile)
        } catch {
            log("GeminiAnalysis: failed to write chunk to \(stableFile.path): \(error)")
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

        log("GeminiAnalysis: buffered chunk \(info.chunkIndex) (\(chunkBuffer.count)/\(maxChunks))")

        // Trigger analysis when we have enough chunks (with cooldown after failures)
        if chunkBuffer.count >= maxChunks && !isAnalyzing {
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
                "chunks_analyzed": result.chunksAnalyzed,
                "response": result.raw,
            ]
            if let task = result.task {
                properties["task"] = task
            }
            PostHogSDK.shared.capture("gemini_analysis_completed", properties: properties)

            // Persist TASK_FOUND results to observer_activity and show overlay
            if result.verdict == "TASK_FOUND", let task = result.task {
                await persistAndShowOverlay(task: task, description: result.description, document: result.document, result: result)
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
        let prompt = analysisPromptTemplate.replacingOccurrences(of: "{APP_CONTEXT}", with: appContext)

        // Add the prompt as the last part
        parts.append(["text": prompt])

        // Call generateContent
        let result = await callGenerateContent(parts: parts, apiKey: apiKey)

        // Cleanup uploaded Gemini File API files (these are remote, always safe to delete)
        for fileName in uploadedFileNames {
            Task { await deleteFile(fileName: fileName, apiKey: apiKey) }
        }

        guard let raw = result else {
            log("GeminiAnalysis: generateContent returned no result")
            return nil
        }

        let parsed = parseResult(raw, chunksAnalyzed: chunks.count)
        log("GeminiAnalysis: \(parsed.verdict) (\(chunks.count) chunks)")
        if let task = parsed.task {
            log("GeminiAnalysis: task=\(task)")
        }
        return parsed
    }

    private func resolveAPIKey() async -> String? {
        await KeyService.shared.ensureKeys(timeout: 5)
        return KeyService.shared.geminiAPIKey
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

    private func parseResult(_ raw: String, chunksAnalyzed: Int) -> AnalysisResult {
        let lines = raw.components(separatedBy: "\n")

        var verdict = "NO_TASK"
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

        return AnalysisResult(verdict: verdict, task: task, description: description, document: document, raw: raw, chunksAnalyzed: chunksAnalyzed)
    }

    private func cleanupChunkFiles(chunks: [ChunkEntry]) {
        for chunk in chunks {
            try? FileManager.default.removeItem(at: chunk.localURL)
        }
    }

    // MARK: - Persistence & Overlay

    /// Insert the analysis result into observer_activity and show the overlay above the floating bar.
    private func persistAndShowOverlay(task: String, description: String?, document: String?, result: AnalysisResult) async {
        // 1. Persist to observer_activity
        var activityId: Int64 = 0
        if let dbQueue = await AppDatabase.shared.getDatabaseQueue() {
            do {
                var contentJson: [String: Any] = [
                    "task": task,
                    "chunks_analyzed": result.chunksAnalyzed,
                    "raw": result.raw,
                ]
                if let description { contentJson["description"] = description }
                if let document { contentJson["document"] = document }
                let contentString = String(data: try JSONSerialization.data(withJSONObject: contentJson), encoding: .utf8) ?? task

                activityId = try await dbQueue.write { db -> Int64 in
                    try db.execute(
                        sql: """
                            INSERT INTO observer_activity (type, content, status, createdAt)
                            VALUES (?, ?, 'pending', datetime('now'))
                        """,
                        arguments: ["gemini_analysis", contentString]
                    )
                    return db.lastInsertedRowID
                }
                log("GeminiAnalysis: persisted to observer_activity id=\(activityId)")
            } catch {
                log("GeminiAnalysis: failed to persist to DB: \(error)")
            }
        }

        // 2. Show overlay on main thread
        let savedId = activityId
        let desc = description
        let doc = document
        await MainActor.run {
            if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
                AnalysisOverlayWindow.shared.show(below: barFrame, task: task, description: desc, document: doc, activityId: savedId)
            } else {
                log("GeminiAnalysis: no bar frame available, skipping overlay")
            }
        }
    }
}
