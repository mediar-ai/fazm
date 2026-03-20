import AppKit
import Foundation
import GRDB

/// Executes tool calls from Gemini and returns results
/// Tools: execute_sql (read/write SQL on fazm.db), complete_task, capture_screenshot, etc.
@MainActor
class ChatToolExecutor {

    // MARK: - Onboarding State

    /// Set by OnboardingChatView before starting the chat
    static var onboardingAppState: AppState?
    /// Called when AI invokes complete_onboarding
    static var onCompleteOnboarding: (() -> Void)?
    /// Called when AI invokes ask_followup — delivers question text and quick-reply options to the UI
    static var onQuickReplyOptions: ((_ question: String, _ options: [String]) -> Void)?
    /// Called when AI invokes save_knowledge_graph — notifies the graph view to update
    static var onKnowledgeGraphUpdated: (() -> Void)?
    /// Called when scan_files completes — used to kick off parallel exploration
    static var onScanFilesCompleted: ((_ fileCount: Int) -> Void)?
    /// Called to programmatically send a follow-up message (e.g. after OAuth completes)
    static var onSendFollowUp: ((_ message: String) -> Void)?

    private static var fileScanFileCount = 0

    /// Execute a tool call and return the result as a string
    static func execute(_ toolCall: ToolCall) async -> String {
        log("Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")

        switch toolCall.name {
        case "execute_sql":
            return await executeSQL(toolCall.arguments)


        case "capture_screenshot":
            return await executeCaptureScreenshot(toolCall.arguments)

        // Onboarding tools
        case "request_permission":
            let result = await executeRequestPermission(toolCall.arguments)
            let permType = toolCall.arguments["type"] as? String ?? "unknown"
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "request_permission", properties: ["permission": permType, "result": result.contains("granted") ? "granted" : "pending"])
            return result

        case "check_permission_status":
            let result = await executeCheckPermissionStatus(toolCall.arguments)
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "check_permission_status")
            return result

        case "extract_browser_profile":
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "extract_browser_profile")
            return await executeExtractBrowserProfile(toolCall.arguments)

        case "query_browser_profile":
            return await executeQueryBrowserProfile(toolCall.arguments)

        case "edit_browser_profile":
            return await executeEditBrowserProfile(toolCall.arguments)

        case "scan_files", "start_file_scan":
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "scan_files")
            return await executeScanFiles(toolCall.arguments)

        case "get_file_scan_results":
            return await executeScanFiles(toolCall.arguments)

        case "set_user_preferences":
            let result = await executeSetUserPreferences(toolCall.arguments)
            var props: [String: Any] = [:]
            if let name = toolCall.arguments["name"] as? String { props["name_changed"] = true; props["name"] = name }
            if let lang = toolCall.arguments["language"] as? String { props["language"] = lang }
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "set_user_preferences", properties: props)
            return result

        case "ask_followup":
            let result = await executeAskFollowup(toolCall.arguments)
            let question = toolCall.arguments["question"] as? String ?? ""
            let optionCount = (toolCall.arguments["options"] as? [String])?.count ?? 0
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "ask_followup", properties: ["question_length": question.count, "option_count": optionCount])
            return result

        case "complete_onboarding":
            let result = await executeCompleteOnboarding(toolCall.arguments)
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "complete_onboarding")
            return result

        case "list_bundled_skills":
            let result = SkillInstaller.listBundledSkills()
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "list_bundled_skills")
            return result

        case "install_skills":
            let names = toolCall.arguments["names"] as? [String]
            let result = SkillInstaller.install(names: names)
            let count = names?.count ?? SkillInstaller.bundledSkillNames.count
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "install_skills", properties: ["requested_count": count])
            return result

        case "save_knowledge_graph":
            let result = await executeSaveKnowledgeGraph(toolCall.arguments)
            let nodes = toolCall.arguments["nodes"] as? [[String: Any]] ?? []
            let nodeCount = nodes.count
            let edgeCount = (toolCall.arguments["edges"] as? [[String: Any]])?.count ?? 0
            AnalyticsManager.shared.onboardingChatToolUsed(tool: "save_knowledge_graph", properties: ["nodes": nodeCount, "edges": edgeCount])
            // Fire discovery source event if the AI saved the deterministic discovery nodes
            if let platform = nodes.first(where: { $0["id"] as? String == "discovery_platform" })?["label"] as? String,
               let detail = nodes.first(where: { $0["id"] as? String == "discovery_detail" })?["label"] as? String {
                AnalyticsManager.shared.onboardingDiscoverySource(platform: platform, detail: detail)
            }
            return result

        default:
            return "Unknown tool: \(toolCall.name)"
        }
    }

    /// Execute multiple tool calls and return results keyed by tool name
    static func executeAll(_ toolCalls: [ToolCall]) async -> [String: String] {
        var results: [String: String] = [:]

        for call in toolCalls {
            results[call.name] = await execute(call)
        }

        return results
    }

    // MARK: - SQL Execution

    /// Blocked SQL keywords that are never allowed
    private static let blockedKeywords: Set<String> = [
        "DROP", "ALTER", "CREATE", "PRAGMA", "ATTACH", "DETACH", "VACUUM"
    ]

    /// Execute a SQL query on fazm.db
    private static func executeSQL(_ args: [String: Any]) async -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: query is required"
        }

        // Sanitize common LLM SQL mistakes:
        // 1. Backslash-escaped single quotes (\') → SQL-standard doubled quotes ('')
        // 2. Escaped newlines/tabs that aren't valid in SQL literals
        var sanitized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "\\'", with: "''")
        sanitized = sanitized.replacingOccurrences(of: "\\\"", with: "\"")

        var upper = sanitized.uppercased()

        // Block dangerous keywords
        for keyword in blockedKeywords {
            if upper.range(of: "\\b\(keyword)\\b", options: .regularExpression) != nil {
                return "Error: \(keyword) statements are not allowed"
            }
        }

        // Block multi-statement queries (semicolon followed by another statement)
        let statements = sanitized.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if statements.count > 1 {
            return "Error: multi-statement queries are not allowed. Send one statement at a time."
        }

        // Fix bare `now` → `datetime('now')` in SQL values.
        // Matches `now` as a standalone value (e.g. VALUES(..., now, ...) or SET col = now)
        // but not inside strings, function calls like datetime('now'), or as part of other words.
        sanitized = sanitized.replacingOccurrences(
            of: #"(?<!')(?<!\w)now(?!\w)(?!')"#,
            with: "datetime('now')",
            options: .regularExpression
        )

        // Fix double-escaped quotes: datetime(''now'') → datetime('now')
        // LLMs sometimes produce ''now'' (two single quotes) which SQLite parses as
        // empty-string || bare-identifier || empty-string → syntax error.
        sanitized = sanitized.replacingOccurrences(
            of: #"datetime\(''now''\)"#,
            with: "datetime('now')",
            options: .regularExpression
        )
        upper = sanitized.uppercased()

        // Auto-convert INSERTs into knowledge graph / profile tables to use OR REPLACE
        // to avoid UNIQUE constraint failures when the AI re-inserts existing data
        if upper.hasPrefix("INSERT") && !upper.hasPrefix("INSERT OR") {
            let tables = ["LOCAL_KG_NODES", "LOCAL_KG_EDGES", "AI_USER_PROFILES"]
            if tables.contains(where: { upper.contains($0) }) {
                sanitized = "INSERT OR REPLACE" + sanitized.dropFirst("INSERT".count)
                upper = sanitized.uppercased()
            }
        }

        let trimmed = sanitized

        // Determine query type
        let isSelect = upper.hasPrefix("SELECT") || upper.hasPrefix("WITH")
        let isInsert = upper.hasPrefix("INSERT")
        let isUpdate = upper.hasPrefix("UPDATE")
        let isDelete = upper.hasPrefix("DELETE")

        // Block UPDATE/DELETE without WHERE
        if (isUpdate || isDelete) && !upper.contains("WHERE") {
            return "Error: \(isUpdate ? "UPDATE" : "DELETE") without WHERE clause is not allowed"
        }

        // Get database queue
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
            return "Error: database not available"
        }

        do {
            if isSelect {
                return try await executeSelectQuery(trimmed, upper: upper, dbQueue: dbQueue)
            } else if isInsert || isUpdate || isDelete {
                return try await executeWriteQuery(trimmed, dbQueue: dbQueue)
            } else {
                return "Error: only SELECT, INSERT, UPDATE, DELETE statements are allowed"
            }
        } catch {
            logError("Tool execute_sql failed", error: error)
            return "SQL Error: \(error.localizedDescription)\nFailed query: \(trimmed)"
        }
    }

    /// Execute a SELECT query and format results as text
    private static func executeSelectQuery(_ query: String, upper: String, dbQueue: DatabasePool) async throws -> String {
        // Auto-append LIMIT 200 if no LIMIT clause
        var finalQuery = query
        if !upper.contains("LIMIT") {
            // Remove trailing semicolon if present
            if finalQuery.hasSuffix(";") {
                finalQuery = String(finalQuery.dropLast())
            }
            finalQuery += " LIMIT 200"
        }

        let query = finalQuery
        let rows = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: query)
        }

        if rows.isEmpty {
            return "No results"
        }

        // Get column names from first row
        let columns = Array(rows[0].columnNames)
        var lines: [String] = []

        // Header
        lines.append(columns.joined(separator: " | "))
        lines.append(String(repeating: "-", count: min(columns.count * 20, 120)))

        // Rows (max 200) — Row is RandomAccessCollection of (String, DatabaseValue)
        for row in rows.prefix(200) {
            let values = row.map { (_, dbValue) -> String in
                let value: String
                switch dbValue.storage {
                case .null:
                    value = "NULL"
                case .int64(let i):
                    value = String(i)
                case .double(let d):
                    value = String(d)
                case .string(let s):
                    value = s
                case .blob(let data):
                    value = "<\(data.count) bytes>"
                }
                // Truncate long cell values
                if value.count > 500 {
                    return String(value.prefix(500)) + "..."
                }
                return value
            }
            lines.append(values.joined(separator: " | "))
        }

        lines.append("\n\(rows.count) row(s)")
        log("Tool execute_sql returned \(rows.count) rows")
        return lines.joined(separator: "\n")
    }

    /// Execute a write (INSERT/UPDATE/DELETE) query
    private static func executeWriteQuery(_ query: String, dbQueue: DatabasePool) async throws -> String {
        let changes = try await dbQueue.write { db -> Int in
            try db.execute(sql: query)
            return db.changesCount
        }

        log("Tool execute_sql write: \(changes) row(s) affected")

        return "OK: \(changes) row(s) affected"
    }

    // MARK: - Task Tools

    /// Toggle a task's completion status via TasksStore (handles local + API sync)

    // MARK: - Onboarding Tools

    /// Request a specific macOS permission
    private static func executeRequestPermission(_ args: [String: Any]) async -> String {
        guard let type = args["type"] as? String else {
            return "Error: 'type' parameter is required (screen_recording, microphone, notifications, accessibility, automation)"
        }

        guard let appState = onboardingAppState else {
            return "Error: onboarding not active"
        }

        AnalyticsManager.shared.permissionRequested(permission: type)

        switch type {
        case "screen_recording":
            appState.triggerScreenRecordingPermission()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            appState.checkScreenRecordingPermission()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if appState.hasScreenRecordingPermission {
                return "granted"
            } else {
                return "pending - user needs to toggle Screen Recording for Fazm in System Settings, then quit and reopen the app"
            }

        case "microphone":
            appState.requestMicrophonePermission()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if appState.hasMicrophonePermission {
                return "granted"
            } else {
                return "pending - user needs to allow microphone access in the system dialog"
            }

        case "notifications":
            appState.requestNotificationPermission()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            appState.checkNotificationPermission()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if appState.hasNotificationPermission {
                return "granted"
            } else {
                return "pending - user needs to allow notifications in the system dialog"
            }

        case "accessibility":
            appState.triggerAccessibilityPermission()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            appState.checkAccessibilityPermission()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if appState.hasAccessibilityPermission {
                return "granted"
            } else {
                return "pending - user needs to toggle Accessibility for Fazm in System Settings"
            }

        default:
            return "Error: unknown permission type '\(type)'. Valid types: screen_recording, microphone, notifications, accessibility"
        }
    }

    /// Check status of all macOS permissions
    private static func executeCheckPermissionStatus(_ args: [String: Any]) async -> String {
        guard let appState = onboardingAppState else {
            return "Error: onboarding not active"
        }

        appState.checkAllPermissions()
        try? await Task.sleep(nanoseconds: 500_000_000)

        let statuses: [String: String] = [
            "screen_recording": appState.hasScreenRecordingPermission ? "granted" : "not_granted",
            "microphone": appState.hasMicrophonePermission ? "granted" : "not_granted",
            "accessibility": appState.hasAccessibilityPermission ? "granted" : "not_granted",
        ]

        if let data = try? JSONSerialization.data(withJSONObject: statuses, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "screen_recording: \(statuses["screen_recording"]!), microphone: \(statuses["microphone"]!), accessibility: \(statuses["accessibility"]!)"
    }

    /// Scan files — triggers folder access dialogs, waits for scan, returns results.
    /// File enumeration runs on a background thread to avoid blocking the main thread.
    private static func executeScanFiles(_ args: [String: Any]) async -> String {
        // Run folder pre-check and scan on a background thread to avoid main-thread hangs
        let (accessibleFolders, deniedFolders) = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let homeDir = fm.homeDirectoryForCurrentUser
            let foldersToScan = ["Downloads", "Documents", "Desktop", "Developer", "Projects"]
                .map { homeDir.appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) }

            let applicationsURL = URL(fileURLWithPath: "/Applications")
            var allFolders = foldersToScan
            if fm.fileExists(atPath: applicationsURL.path) {
                allFolders.append(applicationsURL)
            }

            // Pre-check folder access — this triggers macOS TCC dialogs
            var denied: [String] = []
            var accessible: [URL] = []
            for folder in allFolders {
                do {
                    _ = try fm.contentsOfDirectory(
                        at: folder,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: [.skipsHiddenFiles]
                    )
                    accessible.append(folder)
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain && nsError.code == 257 {
                        denied.append(folder.lastPathComponent)
                    } else {
                        log("FileIndexer: Pre-check failed for \(folder.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            return (accessible, denied)
        }.value

        // Actually scan accessible folders (runs on FileIndexerService actor)
        let count = await FileIndexerService.shared.scanFolders(accessibleFolders)
        fileScanFileCount = count
        log("Onboarding file scan completed: \(count) files indexed, \(deniedFolders.count) folders denied")

        // Build results from database
        let resultsStr = await getFileScanResultsFromDB()

        var out = resultsStr

        if !deniedFolders.isEmpty {
            out += "\n\n## FOLDER ACCESS DENIED\n"
            out += "The following folders were NOT scanned because the user didn't grant access:\n"
            for folder in deniedFolders {
                out += "- ~/\(folder)\n"
            }
            out += "\nTell the user to click 'Allow' on the macOS dialogs, then call scan_files again to pick up those folders."
        }

        // Notify that scan completed — triggers parallel exploration
        onScanFilesCompleted?(count)

        return out
    }

    // MARK: - Browser Profile Extraction

    /// Extract user browser profile using the ai-browser-profile Python package.
    /// Runs the fast extraction steps (autofill, history, bookmarks, logins, Notion) + cleanup,
    /// then returns the interim profile. WhatsApp contacts and embeddings continue in the background.
    private static func executeExtractBrowserProfile(_ args: [String: Any]) async -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let aiBrowserProfileDir = homeDir.appendingPathComponent("ai-browser-profile")
        let python = aiBrowserProfileDir.appendingPathComponent(".venv/bin/python").path
        let extractScript = aiBrowserProfileDir.appendingPathComponent("extract.py").path

        // Check if ai-browser-profile is installed, auto-install if not
        if !FileManager.default.fileExists(atPath: python) ||
           !FileManager.default.fileExists(atPath: extractScript) {
            log("ai-browser-profile not found, installing via npx...")
            let installResult = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["npx", "ai-browser-profile", "init"]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
                } catch {
                    return (false, "Failed to run npx: \(error.localizedDescription)")
                }
            }.value

            if !installResult.0 {
                return "Failed to install ai-browser-profile: \(installResult.1)\nUser can install manually: npx ai-browser-profile init"
            }

            // Also install embeddings
            let _ = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["npx", "ai-browser-profile", "install-embeddings"]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try? process.run()
                process.waitUntilExit()
            }.value
        }

        // Run extraction — return as soon as the interim profile is printed (don't wait for embeddings)
        let result = await Task.detached(priority: .userInitiated) { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [extractScript]
            process.currentDirectoryURL = aiBrowserProfileDir

            // Use separate pipes so we can read both stdout and stderr
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return "Failed to run extraction: \(error.localizedDescription)"
            }

            // Read output incrementally, return as soon as interim profile marker appears
            let interimMarker = "Interim profile ready (WhatsApp + embeddings still running):\n"

            return await withCheckedContinuation { continuation in
                // nonisolated(unsafe) silences Swift 6 Sendable warnings for these vars
                // that are safely guarded by the NSLock below.
                nonisolated(unsafe) var hasResumed = false
                let lock = NSLock()
                nonisolated(unsafe) var accumulatedOutput = ""

                @Sendable func tryResumeWithInterim() {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !hasResumed else { return }

                    // Parse browser transparency lines
                    func parseLine(_ prefix: String) -> [String] {
                        guard let range = accumulatedOutput.range(of: prefix),
                              let end = accumulatedOutput[range.upperBound...].firstIndex(of: "\n") else { return [] }
                        let value = String(accumulatedOutput[range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
                        return value.isEmpty ? [] : value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }

                    guard let profileStart = accumulatedOutput.range(of: interimMarker) else { return }

                    let browsersScanned = parseLine("BROWSERS_SCANNED: ")
                    let browsersDenied = parseLine("BROWSERS_PERMISSION_DENIED: ")

                    var browserSummaryPrefix = ""
                    if !browsersScanned.isEmpty {
                        let scanned = browsersScanned.map { $0.capitalized }.joined(separator: ", ")
                        browserSummaryPrefix += "Browsers scanned: \(scanned)"
                        if !browsersDenied.isEmpty {
                            let denied = browsersDenied.map { $0.capitalized }.joined(separator: ", ")
                            browserSummaryPrefix += "\nSkipped (needs Full Disk Access): \(denied)"
                        }
                        browserSummaryPrefix += "\n\n"
                    }

                    let afterMarker = accumulatedOutput[profileStart.upperBound...]
                    // Profile ends at the next log line (starts with timestamp like "HH:MM:SS")
                    let profileText: String
                    if let nextLogLine = afterMarker.range(of: #"\n\d{2}:\d{2}:\d{2} "#, options: .regularExpression) {
                        profileText = String(afterMarker[..<nextLogLine.lowerBound])
                    } else {
                        profileText = String(afterMarker)
                    }

                    hasResumed = true
                    continuation.resume(returning: browserSummaryPrefix + profileText)
                }

                // Read stderr (where logging output goes) incrementally
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let str = String(data: data, encoding: .utf8) {
                        lock.lock()
                        accumulatedOutput += str
                        lock.unlock()
                        tryResumeWithInterim()
                    }
                }

                // Also read stdout for BROWSERS_SCANNED lines
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let str = String(data: data, encoding: .utf8) {
                        lock.lock()
                        accumulatedOutput += str
                        lock.unlock()
                        tryResumeWithInterim()
                    }
                }

                // Fallback: if process exits without the marker, return whatever we have
                process.terminationHandler = { _ in
                    // Clean up handlers
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil

                    lock.lock()
                    let alreadyResumed = hasResumed
                    if !alreadyResumed { hasResumed = true }
                    let output = accumulatedOutput
                    lock.unlock()

                    guard !alreadyResumed else { return }

                    // Process exited without interim marker — try reading profile from DB
                    let profileProcess = Process()
                    profileProcess.executableURL = URL(fileURLWithPath: python)
                    profileProcess.arguments = ["-c", """
                        import sys, os
                        sys.path.insert(0, os.path.expanduser("~/ai-browser-profile"))
                        from ai_browser_profile import MemoryDB
                        mem = MemoryDB(os.path.expanduser("~/ai-browser-profile/memories.db"))
                        print(mem.profile_text())
                        mem.close()
                        """]
                    profileProcess.currentDirectoryURL = aiBrowserProfileDir
                    let profilePipe = Pipe()
                    profileProcess.standardOutput = profilePipe
                    profileProcess.standardError = profilePipe
                    do {
                        try profileProcess.run()
                        profileProcess.waitUntilExit()
                        let profileData = profilePipe.fileHandleForReading.readDataToEndOfFile()
                        let fallback = String(data: profileData, encoding: .utf8) ?? "Extraction complete but could not read profile."
                        continuation.resume(returning: fallback)
                    } catch {
                        continuation.resume(returning: "Extraction finished but could not read profile: \(output)")
                    }
                }
            }
        }.value

        let isOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        AnalyticsManager.shared.browserProfileExtractionCompleted(source: isOnboarding ? "onboarding" : "migration")
        OnboardingChatPersistence.markStepCompleted("ai_browser_profile")
        log("Browser profile extraction completed")
        return result
    }

    // MARK: - Browser Profile Query

    /// Query the user's browser profile database (always available, not onboarding-only).
    private static func executeQueryBrowserProfile(_ args: [String: Any]) async -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let aiBrowserProfileDir = homeDir.appendingPathComponent("ai-browser-profile")
        let python = aiBrowserProfileDir.appendingPathComponent(".venv/bin/python").path
        let dbPath = aiBrowserProfileDir.appendingPathComponent("memories.db").path

        guard FileManager.default.fileExists(atPath: python),
              FileManager.default.fileExists(atPath: dbPath) else {
            return "Browser profile not available. Run `npx ai-browser-profile init` then extract browser data to set it up."
        }

        let query = args["query"] as? String ?? "full profile"
        let tags = args["tags"] as? [String] ?? []
        let queryLiteral = pythonStringLiteral(query)

        return await Task.detached(priority: .userInitiated) { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)

            let tagsExpr = tags.isEmpty ? "None" : "[\(tags.map { "\"\($0)\"" }.joined(separator: ", "))]"
            let script = """
                import sys, os
                sys.path.insert(0, os.path.expanduser("~/ai-browser-profile"))
                from ai_browser_profile import MemoryDB
                mem = MemoryDB(os.path.expanduser("~/ai-browser-profile/memories.db"))
                query = \(queryLiteral)
                tags = \(tagsExpr)
                if query in ("full profile", "profile"):
                    print(mem.profile_text())
                elif tags:
                    results = mem.search(tags, limit=20)
                    for r in results:
                        print(f'{r["key"]}: {r["value"]}')
                else:
                    results = mem.semantic_search(query, limit=15)
                    for r in results:
                        print(f'{r["key"]}: {r["value"]}')
                mem.close()
                """

            process.arguments = ["-c", script]
            process.currentDirectoryURL = aiBrowserProfileDir
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return output.isEmpty ? "No results found for query: \(query)" : output
            } catch {
                return "Failed to query browser profile: \(error.localizedDescription)"
            }
        }.value
    }

    /// Delete or update a specific memory in the browser profile database.
    private static func executeEditBrowserProfile(_ args: [String: Any]) async -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let aiBrowserProfileDir = homeDir.appendingPathComponent("ai-browser-profile")
        let python = aiBrowserProfileDir.appendingPathComponent(".venv/bin/python").path
        let dbPath = aiBrowserProfileDir.appendingPathComponent("memories.db").path

        guard FileManager.default.fileExists(atPath: python),
              FileManager.default.fileExists(atPath: dbPath) else {
            return "Browser profile not available."
        }

        let action = args["action"] as? String ?? "delete"
        let query = args["query"] as? String ?? ""
        let newValue = args["new_value"] as? String ?? ""
        let queryLiteral = pythonStringLiteral(query)
        let newValueLiteral = pythonStringLiteral(newValue)

        let script: String
        if action == "delete" {
            script = """
                import sys, os, logging
                logging.disable(logging.CRITICAL)
                sys.path.insert(0, os.path.expanduser("~/ai-browser-profile"))
                from ai_browser_profile import MemoryDB
                mem = MemoryDB(os.path.expanduser("~/ai-browser-profile/memories.db"), defer_embeddings=True)
                q = \(queryLiteral).lower()
                rows = mem.conn.execute("SELECT id, key, value FROM memories WHERE lower(value) LIKE ? OR lower(key) LIKE ?", (f'%{q}%', f'%{q}%')).fetchall()
                if not rows:
                    print(f"No memories found matching: \(queryLiteral)")
                else:
                    for row in rows:
                        mem.delete(row[0])
                        print(f"Deleted: {row[1]}: {row[2]}")
                mem.close()
                """
        } else {
            script = """
                import sys, os, logging
                logging.disable(logging.CRITICAL)
                sys.path.insert(0, os.path.expanduser("~/ai-browser-profile"))
                from ai_browser_profile import MemoryDB
                mem = MemoryDB(os.path.expanduser("~/ai-browser-profile/memories.db"), defer_embeddings=True)
                q = \(queryLiteral).lower()
                rows = mem.conn.execute("SELECT id, key, value FROM memories WHERE lower(value) LIKE ? OR lower(key) LIKE ?", (f'%{q}%', f'%{q}%')).fetchall()
                if not rows:
                    print(f"No memories found matching: \(queryLiteral)")
                else:
                    for row in rows:
                        mem.update_memory(row[0], value=\(newValueLiteral))
                        print(f"Updated: {row[1]}: {row[2]} -> \(newValueLiteral)")
                mem.close()
                """
        }

        return await Task.detached(priority: .userInitiated) { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", script]
            process.currentDirectoryURL = aiBrowserProfileDir
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Done."
            } catch {
                return "Failed to edit browser profile: \(error.localizedDescription)"
            }
        }.value
    }

    private static func pythonStringLiteral(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Get file scan results from the database
    private static func getFileScanResultsFromDB() async -> String {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
            return "Error: database not available"
        }

        do {
            return try await dbQueue.read { db in
                // File type breakdown
                let typeBreakdown = try Row.fetchAll(db, sql: """
                    SELECT fileType, COUNT(*) as count
                    FROM indexed_files
                    GROUP BY fileType
                    ORDER BY count DESC
                    LIMIT 10
                """)

                // Project indicators
                let projectIndicators = try Row.fetchAll(db, sql: """
                    SELECT filename, path FROM indexed_files
                    WHERE filename IN ('package.json', 'Cargo.toml', 'Podfile', 'go.mod',
                        'requirements.txt', 'Pipfile', 'setup.py', 'pyproject.toml',
                        'build.gradle', 'pom.xml', 'CMakeLists.txt', 'Makefile',
                        '.xcodeproj', '.xcworkspace', 'Package.swift', 'Gemfile',
                        'composer.json', 'mix.exs', 'pubspec.yaml')
                    LIMIT 30
                """)

                // Recently modified files
                let recentFiles = try Row.fetchAll(db, sql: """
                    SELECT filename, path, fileType, modifiedAt FROM indexed_files
                    ORDER BY modifiedAt DESC
                    LIMIT 15
                """)

                // Applications
                let apps = try Row.fetchAll(db, sql: """
                    SELECT filename, path FROM indexed_files
                    WHERE folder = '/Applications' AND fileExtension = 'app'
                    ORDER BY filename
                    LIMIT 30
                """)

                let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_files") ?? 0

                var out = "# File Scan Results (\(totalCount) files indexed)\n\n"

                out += "## File Types\n"
                for row in typeBreakdown {
                    let type = row["fileType"] as? String ?? "unknown"
                    let count = row["count"] as? Int ?? 0
                    out += "- \(type): \(count) files\n"
                }

                out += "\n## Project Indicators (build files found)\n"
                if projectIndicators.isEmpty {
                    out += "- No project build files found\n"
                } else {
                    for row in projectIndicators {
                        let filename = row["filename"] as? String ?? ""
                        let path = row["path"] as? String ?? ""
                        // Extract project directory name
                        let dir = (path as NSString).deletingLastPathComponent
                        let projectName = (dir as NSString).lastPathComponent
                        out += "- \(projectName)/\(filename)\n"
                    }
                }

                out += "\n## Recently Modified Files\n"
                for row in recentFiles {
                    let filename = row["filename"] as? String ?? ""
                    let fileType = row["fileType"] as? String ?? ""
                    let modifiedAt = row["modifiedAt"] as? String ?? ""
                    out += "- \(filename) (\(fileType)) — modified \(modifiedAt)\n"
                }

                if !apps.isEmpty {
                    out += "\n## Installed Applications\n"
                    let appNames = apps.compactMap { ($0["filename"] as? String)?.replacingOccurrences(of: ".app", with: "") }
                    out += appNames.joined(separator: ", ")
                    out += "\n"
                }

                log("Tool get_file_scan_results: \(totalCount) files, \(projectIndicators.count) projects, \(apps.count) apps")
                return out
            }
        } catch {
            logError("Tool get_file_scan_results failed", error: error)
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Set user preferences (language, name)
    private static func executeSetUserPreferences(_ args: [String: Any]) async -> String {
        var results: [String] = []

        if let language = args["language"] as? String, !language.isEmpty {
            AssistantSettings.shared.transcriptionLanguage = language
            let supportsMulti = AssistantSettings.supportsAutoDetect(language)
            AssistantSettings.shared.transcriptionAutoDetect = supportsMulti
            Task {
                _ = try? await APIClient.shared.updateUserLanguage(language)
            }
            results.append("Language set to \(language)")
        }

        if let name = args["name"] as? String, !name.isEmpty {
            await AuthService.shared.updateGivenName(name)
            results.append("Name updated to \(name)")
        }

        if results.isEmpty {
            return "No preferences were changed. Provide 'language' (code like 'en', 'es', 'ja') and/or 'name' (string)."
        }
        return results.joined(separator: ". ") + "."
    }

    // MARK: - Knowledge Graph Tool

    /// Save a knowledge graph extracted by the AI during file exploration
    private static func executeSaveKnowledgeGraph(_ args: [String: Any]) async -> String {
        let nodesArray = args["nodes"] as? [[String: Any]] ?? []
        let edgesArray = args["edges"] as? [[String: Any]] ?? []

        guard !nodesArray.isEmpty || !edgesArray.isEmpty else {
            return "Error: 'nodes' or 'edges' array is required"
        }

        let now = Date()
        var nodeRecords: [LocalKGNodeRecord] = []
        var edgeRecords: [LocalKGEdgeRecord] = []

        // Load existing node IDs from the database so edges can reference previously-saved nodes
        let existingGraph = await KnowledgeGraphStorage.shared.loadGraph()
        var knownNodeIds = Set(existingGraph.nodes.map { $0.id })

        // Deduplicate nodes by label (case-insensitive)
        var seenLabels: [String: String] = [:] // lowercase label → nodeId
        var idRemap: [String: String] = [:] // original id → canonical id

        for node in nodesArray {
            guard let id = node["id"] as? String,
                  let label = node["label"] as? String else { continue }

            let nodeType = node["node_type"] as? String ?? "concept"
            let aliases = node["aliases"] as? [String] ?? []
            let lowerLabel = label.lowercased()

            if let existingId = seenLabels[lowerLabel] {
                idRemap[id] = existingId
                continue
            }

            seenLabels[lowerLabel] = id
            idRemap[id] = id
            knownNodeIds.insert(id)

            var aliasesJson: String?
            if !aliases.isEmpty, let data = try? JSONEncoder().encode(aliases) {
                aliasesJson = String(data: data, encoding: .utf8)
            }

            nodeRecords.append(LocalKGNodeRecord(
                nodeId: id,
                label: label,
                nodeType: nodeType,
                aliasesJson: aliasesJson,
                sourceFileIds: nil,
                createdAt: now,
                updatedAt: now
            ))
        }

        for edge in edgesArray {
            guard let sourceId = edge["source_id"] as? String,
                  let targetId = edge["target_id"] as? String,
                  let label = edge["label"] as? String else { continue }

            let remappedSource = idRemap[sourceId] ?? sourceId
            let remappedTarget = idRemap[targetId] ?? targetId

            // Skip self-referencing edges and edges to missing nodes
            guard remappedSource != remappedTarget,
                  knownNodeIds.contains(remappedSource),
                  knownNodeIds.contains(remappedTarget) else { continue }

            let edgeId = "\(remappedSource)_\(remappedTarget)_\(label.lowercased().replacingOccurrences(of: " ", with: "_"))"
            edgeRecords.append(LocalKGEdgeRecord(
                edgeId: edgeId,
                sourceNodeId: remappedSource,
                targetNodeId: remappedTarget,
                label: label,
                createdAt: now
            ))
        }

        do {
            try await KnowledgeGraphStorage.shared.mergeGraph(nodes: nodeRecords, edges: edgeRecords)
            log("Local graph built with \(nodeRecords.count) nodes, \(edgeRecords.count) edges")
            DispatchQueue.main.async { onKnowledgeGraphUpdated?() }
            return "OK: saved \(nodeRecords.count) nodes and \(edgeRecords.count) edges to local knowledge graph"
        } catch {
            logError("Tool save_knowledge_graph failed", error: error)
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Present a follow-up question with quick-reply options to the user
    private static func executeAskFollowup(_ args: [String: Any]) async -> String {
        guard let question = args["question"] as? String else {
            return "Error: 'question' parameter is required"
        }
        let options = (args["options"] as? [String]) ?? []

        // Notify the UI to render question text and quick-reply buttons
        onQuickReplyOptions?(question, options)

        return "Presented to user: \"\(question)\" with options: \(options.joined(separator: ", "))"
    }


    private static func executeCompleteOnboarding(_ args: [String: Any]) async -> String {
        guard let appState = onboardingAppState else {
            return "Error: onboarding not active"
        }

        // Log analytics for each permission
        let permissions: [(String, Bool)] = [
            ("screen_recording", appState.hasScreenRecordingPermission),
            ("microphone", appState.hasMicrophonePermission),
            ("accessibility", appState.hasAccessibilityPermission),
        ]
        for (name, granted) in permissions {
            if granted {
                AnalyticsManager.shared.permissionGranted(permission: name)
            } else {
                AnalyticsManager.shared.permissionSkipped(permission: name)
            }
        }

        // Install bundled skills (in case the AI didn't call install_skills during onboarding)
        let _ = SkillInstaller.install()

        // Mark that the tool was called so the "Continue to App" button shows even after restart
        OnboardingChatPersistence.markToolCompleted()

        // Call the completion callback
        onCompleteOnboarding?()

        // Clean up state
        onboardingAppState = nil
        onCompleteOnboarding = nil
        onQuickReplyOptions = nil
        onKnowledgeGraphUpdated = nil
        onScanFilesCompleted = nil
        onSendFollowUp = nil
        fileScanFileCount = 0

        return "Onboarding completed successfully! The app is now set up."
    }

    @MainActor
    private static func executeCaptureScreenshot(_ args: [String: Any]) async -> String {
        let mode = args["mode"] as? String ?? "screen"

        // Screen capture APIs may require main thread on some macOS versions
        let url: URL?
        if mode == "window" {
            let pid = FloatingControlBarManager.shared.lastActiveAppPID
            if pid != 0 {
                url = ScreenCaptureManager.captureAppWindow(pid: pid)
            } else {
                url = ScreenCaptureManager.captureScreen()
            }
        } else {
            url = ScreenCaptureManager.captureScreen()
        }
        guard let url else {
            log("capture_screenshot tool: capture returned nil (permission issue?)")
            return "ERROR: Failed to capture screenshot. Make sure Screen Recording permission is granted."
        }
        guard let data = try? Data(contentsOf: url) else {
            log("capture_screenshot tool: could not read file at \(url.path)")
            return "ERROR: Failed to read screenshot file."
        }
        log("capture_screenshot tool: returning \(data.count) bytes as base64")
        return data.base64EncodedString()
    }
}
