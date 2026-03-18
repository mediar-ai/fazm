import Foundation
import SessionReplay

/// Accumulates session recording chunks and periodically sends them to the Gemini API
/// for multimodal video analysis to identify tasks an AI agent could help with.
actor GeminiAnalysisService {
    static let shared = GeminiAnalysisService()

    private let analysisPrompt = """
        You are watching ~60 minutes of a user's session recording. Your job is to identify the ONE most impactful task an AI agent could take off their plate.

        With this much context, you should almost always find something. Only return NO_TASK if the user is genuinely idle or doing something an AI agent cannot help with at all.

        The AI agent has: shell access, Claude Code, native browser control, full file system access, and can execute any task on the user's computer.

        Only flag a task if ALL of these are true:
        - The task is concrete and completable (not vague like "help debug" or "improve code")
        - An AI agent could realistically do it 5x faster than the user
        - The AI agent's known weaknesses (slower at visual tasks, can't do real-time interaction) won't make it slower

        AI agents are FASTER at: bulk text processing, searching codebases, running shell commands, filling forms with known data, writing boilerplate code, data transformation, file operations across many files, research, lookups.
        AI agents are SLOWER at: browsing casually, visual inspection, creative decisions, real-time human judgment.

        Respond in this exact format:

        VERDICT: NO_TASK or TASK_FOUND
        TASK: (only if TASK_FOUND) One sentence: what the user is trying to accomplish overall, and one concrete action the agent would take to help.
        CONFIDENCE: (only if TASK_FOUND) How confident this saves 5x time (low/medium/high)
        """

    private let model = "gemini-pro-latest"
    private let maxChunks = 60
    /// Gemini File API: chunks above this size use resumable upload; smaller ones use inline base64.
    private let inlineSizeLimit = 1_500_000 // 1.5 MB

    /// Buffer of chunk file URLs waiting for analysis.
    private var chunkBuffer: [ChunkEntry] = []
    private var isAnalyzing = false

    struct ChunkEntry: Sendable {
        let localURL: URL
        let chunkIndex: Int
        let startTimestamp: Date
        let endTimestamp: Date
    }

    struct AnalysisResult: Sendable {
        let verdict: String  // "NO_TASK" or "TASK_FOUND"
        let task: String?
        let confidence: String?
        let raw: String
        let chunksAnalyzed: Int
    }

    /// Chunk info passed from SessionRecordingManager when a chunk is finalized.
    /// TODO: Replace with SessionRecorder.ChunkInfo once macos-session-replay exposes it.
    struct ChunkInfo: Sendable {
        let localURL: URL
        let chunkIndex: Int
        let startTimestamp: Date
        let endTimestamp: Date
    }

    /// Called by SessionRecordingManager when a chunk is finalized.
    /// Reads the file into memory immediately (before upload deletes it), then buffers it.
    func handleChunk(_ info: ChunkInfo) {
        // Read file data now, before upload deletes the local file
        guard let data = try? Data(contentsOf: info.localURL) else {
            log("GeminiAnalysis: failed to read chunk at \(info.localURL.path)")
            return
        }

        chunkBuffer.append(ChunkEntry(
            localURL: info.localURL,
            chunkIndex: info.chunkIndex,
            startTimestamp: info.startTimestamp,
            endTimestamp: info.endTimestamp
        ))

        // Store the data in a temp location so it survives upload deletion
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-analysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent("chunk_\(info.chunkIndex).mp4")
        try? data.write(to: tempFile)

        // Update the buffer entry to point to temp copy
        if var last = chunkBuffer.last {
            chunkBuffer[chunkBuffer.count - 1] = ChunkEntry(
                localURL: tempFile,
                chunkIndex: last.chunkIndex,
                startTimestamp: last.startTimestamp,
                endTimestamp: last.endTimestamp
            )
        }

        log("GeminiAnalysis: buffered chunk \(info.chunkIndex) (\(chunkBuffer.count)/\(maxChunks))")

        // Trigger analysis when we have enough chunks
        if chunkBuffer.count >= maxChunks && !isAnalyzing {
            let chunks = Array(chunkBuffer.prefix(maxChunks))
            chunkBuffer.removeFirst(min(maxChunks, chunkBuffer.count))
            Task { await runAnalysis(chunks: chunks) }
        }
    }

    /// Force analysis with whatever chunks are buffered (e.g., on app quit or manual trigger).
    func analyzeNow() async -> AnalysisResult? {
        guard !chunkBuffer.isEmpty, !isAnalyzing else { return nil }
        let chunks = chunkBuffer
        chunkBuffer.removeAll()
        return await runAnalysis(chunks: chunks)
    }

    var bufferedChunkCount: Int { chunkBuffer.count }

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

        // Add the prompt as the last part
        parts.append(["text": analysisPrompt])

        // Call generateContent
        let result = await callGenerateContent(parts: parts, apiKey: apiKey)

        // Cleanup: delete uploaded files and temp copies
        for fileName in uploadedFileNames {
            Task { await deleteFile(fileName: fileName, apiKey: apiKey) }
        }
        cleanupTempFiles(chunks: chunks)

        if let raw = result {
            let parsed = parseResult(raw, chunksAnalyzed: chunks.count)
            log("GeminiAnalysis: \(parsed.verdict) (\(chunks.count) chunks)")
            if let task = parsed.task {
                log("GeminiAnalysis: task=\(task) confidence=\(parsed.confidence ?? "?")")
            }
            return parsed
        }

        return nil
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

        guard let (_, startResp) = try? await URLSession.shared.data(for: startReq),
              let httpResp = startResp as? HTTPURLResponse,
              let uploadURL = httpResp.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            log("GeminiAnalysis: File API start failed for \(name)")
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

    private func parseResult(_ raw: String, chunksAnalyzed: Int) -> AnalysisResult {
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        var verdict = "NO_TASK"
        var task: String?
        var confidence: String?

        for line in lines {
            if line.hasPrefix("VERDICT:") {
                verdict = line.replacingOccurrences(of: "VERDICT:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("TASK:") {
                task = line.replacingOccurrences(of: "TASK:", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("CONFIDENCE:") {
                confidence = line.replacingOccurrences(of: "CONFIDENCE:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        return AnalysisResult(verdict: verdict, task: task, confidence: confidence, raw: raw, chunksAnalyzed: chunksAnalyzed)
    }

    private func cleanupTempFiles(chunks: [ChunkEntry]) {
        for chunk in chunks {
            try? FileManager.default.removeItem(at: chunk.localURL)
        }
    }
}
