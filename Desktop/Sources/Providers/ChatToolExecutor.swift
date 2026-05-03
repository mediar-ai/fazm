import AppKit
import AutofillExtractor
import AVFoundation
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
    /// Called when AI invokes ask_followup — delivers question text and quick-reply options to the UI.
    /// Per-session callbacks keyed by session key to prevent cross-contamination between pop-out windows.
    private static var quickReplyCallbacks: [String: (_ question: String, _ options: [String]) -> Void] = [:]
    /// Fallback for onboarding and contexts without a session key
    static var onQuickReplyOptions: ((_ question: String, _ options: [String]) -> Void)?
    /// Called when AI invokes save_knowledge_graph — notifies the graph view to update
    static var onKnowledgeGraphUpdated: (() -> Void)?
    /// Called when scan_files completes — used to kick off parallel exploration
    static var onScanFilesCompleted: ((_ fileCount: Int) -> Void)?
    /// Called to programmatically send a follow-up message (e.g. after OAuth completes).
    /// Per-session callbacks keyed by session key.
    private static var sendFollowUpCallbacks: [String: (_ message: String) -> Void] = [:]
    /// Fallback for contexts without a session key
    static var onSendFollowUp: ((_ message: String) -> Void)?

    /// The session key for the currently executing tool call, set before each execution
    static var activeSessionKey: String?

    /// Register per-session callbacks for quick replies and follow-ups
    static func registerCallbacks(
        sessionKey: String,
        onQuickReply: @escaping (_ question: String, _ options: [String]) -> Void,
        onFollowUp: ((_ message: String) -> Void)? = nil
    ) {
        quickReplyCallbacks[sessionKey] = onQuickReply
        if let onFollowUp {
            sendFollowUpCallbacks[sessionKey] = onFollowUp
        }
    }

    /// Remove per-session callbacks when a session ends
    static func unregisterCallbacks(sessionKey: String) {
        quickReplyCallbacks.removeValue(forKey: sessionKey)
        sendFollowUpCallbacks.removeValue(forKey: sessionKey)
    }

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

        case "speak_response":
            return await executeSpeakResponse(toolCall.arguments)

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

        // FTS5 tables don't support `docid` (FTS3/FTS4 only) — rewrite to `rowid`
        sanitized = sanitized.replacingOccurrences(
            of: "\\bdocid\\b",
            with: "rowid",
            options: .regularExpression
        )

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
        // Sanitize FTS5 MATCH terms: wrap each MATCH argument in double quotes
        // to force literal interpretation. Without this, user input like "e-horyzont"
        // is parsed as FTS5 column prefix syntax (column `e`, term `horyzont`),
        // and words like AND/OR/NOT are treated as FTS5 operators instead of literals.
        sanitized = sanitized.replacingOccurrences(
            of: #"MATCH\s+'([^']+)'"#,
            with: "MATCH '\"$1\"'",
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
            let result: String
            if isSelect {
                result = try await executeSelectQuery(trimmed, upper: upper, dbQueue: dbQueue)
            } else if isInsert || isUpdate || isDelete {
                result = try await executeWriteQuery(trimmed, dbQueue: dbQueue)
            } else {
                return "Error: only SELECT, INSERT, UPDATE, DELETE statements are allowed"
            }
            await AppDatabase.shared.reportQuerySuccess()
            return result
        } catch {
            logError("Tool execute_sql failed", error: error)
            await AppDatabase.shared.reportQueryError(error)
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

        // If this write touched the routines tables, notify ChatProvider so it
        // refreshes the <routines> briefing baked into the next system prompt.
        // DistributedNotificationCenter is used so the launchd routine runner could
        // also post the same notification when it updates run state. Case-insensitive
        // match; a UUID literal in a routine prompt that contains "cron_jobs" is fine
        // (a spurious refresh is cheap, just a small DB read).
        let lower = query.lowercased()
        if lower.contains("cron_jobs") || lower.contains("cron_runs") {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.fazm.routinesChanged"),
                object: nil, userInfo: nil, deliverImmediately: true
            )
        }

        return "OK: \(changes) row(s) affected"
    }

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

    /// Extract user browser profile using native Swift AutofillExtractor.
    /// Reads autofill, history, bookmarks, and logins directly from browser SQLite/JSON files,
    /// stores in ~/ai-browser-profile/memories.db, returns the profile text.
    private static func executeExtractBrowserProfile(_ args: [String: Any]) async -> String {
        let result = await Task.detached(priority: .userInitiated) { () -> String in
            let extractor = AutofillExtractor()
            let profile = extractor.extractAll()

            let counts = "addresses=\(profile.addresses.count), formFields=\(profile.formFields.count), cards=\(profile.cards.count), tools=\(profile.tools.count), accounts=\(profile.accounts.count), bookmarks=\(profile.bookmarks.count)"
            log("Browser profile raw counts: \(counts)")

            do {
                let db = try ProfileDatabase()
                db.ingestProfile(profile)
                let profileText = db.profileText()

                // Append extraction metadata so the AI knows what was found vs empty
                let total = profile.addresses.count + profile.formFields.count + profile.cards.count + profile.tools.count + profile.accounts.count + profile.bookmarks.count
                var warnings: [String] = []
                if profile.addresses.count == 0 && profile.formFields.count == 0 { warnings.append("autofill (no saved addresses or form data found)") }
                if profile.accounts.count == 0 { warnings.append("logins (no saved passwords found)") }
                if profile.bookmarks.count == 0 { warnings.append("bookmarks") }
                if profile.tools.count == 0 { warnings.append("history") }

                var meta = "\n\n---\nExtraction summary: \(total) entries total [\(counts)]"
                if !warnings.isEmpty {
                    meta += "\nEmpty sources: \(warnings.joined(separator: ", ")) — these browsers may not have this data, or the data hasn't synced yet."
                }
                return profileText + meta
            } catch {
                log("Browser profile DB error: \(error.localizedDescription)")
                // DB failed but we still have raw data — format inline
                var lines: [String] = []
                let grouped = profile.grouped
                for (key, vals) in grouped.sorted(by: { $0.key < $1.key }) {
                    lines.append("\(key): \(vals.joined(separator: ", "))")
                }
                return lines.isEmpty ? "Extraction failed: \(error.localizedDescription)" : lines.joined(separator: "\n")
            }
        }.value

        let isOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        AnalyticsManager.shared.browserProfileExtractionCompleted(source: isOnboarding ? "onboarding" : "migration")
        OnboardingChatPersistence.markStepCompleted("ai_browser_profile")
        log("Browser profile extraction completed")
        return result
    }

    // MARK: - Browser Profile Query

    /// Check if browser profile DB needs re-extraction: missing, stale (>24h), or incomplete.
    private static func browserProfileNeedsExtraction(dbPath: String) -> String? {
        let fm = FileManager.default

        if !fm.fileExists(atPath: dbPath) {
            return "DB not found"
        }

        // Stale check: re-extract if DB is older than 24 hours
        if let attrs = try? fm.attributesOfItem(atPath: dbPath),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 86400 {
            return "DB is stale (last updated \(Int(Date().timeIntervalSince(modified) / 3600))h ago)"
        }

        // Incomplete check: if only history entries exist (no autofill, logins, or bookmarks)
        if let db = try? ProfileDatabase(path: dbPath) {
            let hasAutofill = !db.search(tags: ["identity"], limit: 1).isEmpty
                || !db.search(tags: ["address"], limit: 1).isEmpty
                || !db.search(tags: ["payment"], limit: 1).isEmpty
            let hasAccounts = !db.search(tags: ["account"], limit: 1).isEmpty
            // If we have accounts OR autofill data, the extraction was meaningful
            if !hasAutofill && !hasAccounts {
                return "DB is incomplete (only history, no autofill or accounts)"
            }
        }

        return nil
    }

    /// Query the user's browser profile database (always available, not onboarding-only).
    private static func executeQueryBrowserProfile(_ args: [String: Any]) async -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = homeDir.appendingPathComponent("ai-browser-profile/memories.db").path

        if let reason = browserProfileNeedsExtraction(dbPath: dbPath) {
            log("Browser profile re-extraction needed: \(reason)")
            let extractResult = await executeExtractBrowserProfile([:])
            guard FileManager.default.fileExists(atPath: dbPath) else {
                return extractResult.isEmpty ? "Browser profile extraction failed." : extractResult
            }
        }

        let query = args["query"] as? String ?? "full profile"
        let tags = args["tags"] as? [String] ?? []

        return await Task.detached(priority: .userInitiated) { () -> String in
            do {
                let db = try ProfileDatabase(path: dbPath)

                if !tags.isEmpty {
                    let results = db.search(tags: tags, limit: 20)
                    if results.isEmpty { return "No results found for tags: \(tags.joined(separator: ", "))" }
                    return results.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                } else if query == "full profile" || query == "profile" {
                    return db.profileText()
                } else {
                    let results = db.textSearch(query: query, limit: 15)
                    if results.isEmpty { return "No results found for query: \(query)" }
                    return results.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                }
            } catch {
                return "Failed to query browser profile: \(error.localizedDescription)"
            }
        }.value
    }

    /// Delete or update a specific memory in the browser profile database.
    private static func executeEditBrowserProfile(_ args: [String: Any]) async -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = homeDir.appendingPathComponent("ai-browser-profile/memories.db").path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return "Browser profile not available."
        }

        let action = args["action"] as? String ?? "delete"
        let query = args["query"] as? String ?? ""
        let newValue = args["new_value"] as? String ?? ""

        return await Task.detached(priority: .userInitiated) { () -> String in
            do {
                let db = try ProfileDatabase(path: dbPath)

                if action == "delete" {
                    let results = db.delete(matching: query)
                    return results.isEmpty ? "No memories found matching: \(query)" : results.joined(separator: "\n")
                } else {
                    let results = db.update(matching: query, newValue: newValue)
                    return results.isEmpty ? "No memories found matching: \(query)" : results.joined(separator: "\n")
                }
            } catch {
                return "Failed to edit browser profile: \(error.localizedDescription)"
            }
        }.value
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

        if let voice = args["voice"] as? Bool {
            UserDefaults.standard.set(voice, forKey: "voiceResponseEnabled")
            results.append("Voice response \(voice ? "enabled" : "disabled")")
        }

        if results.isEmpty {
            return "No preferences were changed. Provide 'language' (code like 'en', 'es', 'ja'), 'name' (string), and/or 'voice' (true/false)."
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

        // Notify the UI to render question text and quick-reply buttons.
        // Use per-session callback if available (pop-out windows), fall back to global.
        if let key = activeSessionKey, let callback = quickReplyCallbacks[key] {
            callback(question, options)
        } else {
            onQuickReplyOptions?(question, options)
        }

        return "Buttons shown to user. Your turn is DONE. Do NOT generate any more text, tool calls, or content after this. The user will respond by clicking a button or typing."
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

        // Install bundled skills
        let _ = SkillInstaller.install()
        AnalyticsManager.shared.onboardingChatToolUsed(tool: "install_skills", properties: ["source": "complete_onboarding", "requested_count": SkillInstaller.bundledSkillNames.count])

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
                switch ScreenCaptureManager.captureAppWindow(pid: pid) {
                case .success(let capturedURL):
                    url = capturedURL
                case .permissionDenied:
                    log("capture_screenshot tool: Screen Recording permission missing/stale")
                    return "ERROR: Screen Recording permission is not granted. Tell the user to open System Settings → Privacy & Security → Screen Recording, toggle Fazm off and back on, then quit and reopen Fazm."
                }
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

    // MARK: - Voice Response (TTS)

    /// Shared audio player for TTS playback (kept alive to prevent dealloc during playback)
    private static var ttsAudioPlayer: AVAudioPlayer?
    /// AVSpeech fallback synthesizer (only used if /usr/bin/say cannot launch).
    private static let speechSynthesizer = AVSpeechSynthesizer()
    /// Running /usr/bin/say process for system-voice languages.
    /// AVSpeechSynthesizer was unreliable inside the bundled app on Sequoia, so we shell out.
    private static var ttsSayProcess: Process?

    /// Stop any currently playing TTS audio (Deepgram or system).
    static func stopTTSPlayback() {
        if let player = ttsAudioPlayer, player.isPlaying {
            player.stop()
        }
        ttsAudioPlayer = nil
        if let proc = ttsSayProcess, proc.isRunning {
            proc.terminate()
        }
        ttsSayProcess = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// Speak text aloud. The voice follows the detected language of the text:
    /// Deepgram Aura for en/es/fr/de/it/nl/ja, AVSpeechSynthesizer for everything else.
    private static func executeSpeakResponse(_ args: [String: Any]) async -> String {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return "Error: missing 'text' parameter"
        }

        log("speak_response: synthesizing \(text.count) chars")

        let speed = UserDefaults.standard.double(forKey: "voiceResponseSpeed")
        let clampedSpeed = speed > 0 ? min(max(speed, 0.25), 2.0) : 1.0

        let resolution = VoiceLanguageRouter.resolve(forText: text)
        stopTTSPlayback()

        switch resolution {
        case .deepgram(let model, let lang):
            return await speakViaDeepgram(text: text, model: model, languageCode: lang, speed: clampedSpeed)
        case .elevenlabs(let voiceId, let lang):
            // Try ElevenLabs first; if the API call fails (no key, network, 4xx),
            // fall back to system voice so the user still hears something.
            let result = await speakViaElevenLabs(text: text, voiceId: voiceId, languageCode: lang, speed: clampedSpeed)
            if result.hasPrefix("OK:") {
                return result
            }
            log("speak_response: elevenlabs failed (\(result)), falling back to system voice for \(lang)")
            if let voice = AVSpeechSynthesisVoice(language: VoiceLanguageRouter.bcp47Public(for: lang))
                ?? AVSpeechSynthesisVoice(language: lang)
                ?? AVSpeechSynthesisVoice(language: "en-US") {
                return speakViaSystem(text: text, voice: voice, languageCode: lang, speed: clampedSpeed)
            }
            return result
        case .system(let voice, let lang):
            return speakViaSystem(text: text, voice: voice, languageCode: lang, speed: clampedSpeed)
        }
    }

    private static func speakViaElevenLabs(text: String, voiceId: String, languageCode: String, speed: Double) async -> String {
        do {
            let apiKey = try await KeyService.resolveElevenLabsKey()
            let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30

            let body: [String: Any] = [
                "text": text,
                "model_id": VoiceLanguageRouter.elevenLabsModelId,
                "voice_settings": [
                    "stability": 0.5,
                    "similarity_boost": 0.75,
                    "style": 0.0,
                    "use_speaker_boost": true,
                ],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                log("speak_response: ElevenLabs API error \(status) (voice=\(voiceId), lang=\(languageCode)): \(errorBody)")
                return "Error: ElevenLabs TTS failed with status \(status)"
            }
            guard data.count > 1000 else {
                log("speak_response: ElevenLabs returned suspiciously small payload (\(data.count) bytes)")
                return "Error: ElevenLabs returned empty audio"
            }

            log("speak_response: received \(data.count) bytes (elevenlabs, lang=\(languageCode), voice=\(voiceId)), playing at speed \(speed)...")

            let player = try AVAudioPlayer(data: data)
            player.enableRate = true
            player.rate = Float(speed)
            ttsAudioPlayer = player
            player.play()

            return "OK: speaking \(text.count) chars (elevenlabs, \(languageCode))"
        } catch {
            log("speak_response: elevenlabs error: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }

    private static func speakViaDeepgram(text: String, model: String, languageCode: String, speed: Double) async -> String {
        do {
            let apiKey = try await TranscriptionService.resolveDeepgramKey()

            var components = URLComponents(string: "https://api.deepgram.com/v1/speak")!
            components.queryItems = [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: "24000"),
            ]

            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body = try JSONSerialization.data(withJSONObject: ["text": text])
            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                log("speak_response: Deepgram API error \(statusCode) (model=\(model)): \(errorBody)")
                return "Error: Deepgram TTS failed with status \(statusCode)"
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.contains("audio") || data.count > 1000 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                log("speak_response: unexpected content-type '\(contentType)': \(errorBody)")
                return "Error: Deepgram returned non-audio response"
            }

            log("speak_response: received \(data.count) bytes (model=\(model), lang=\(languageCode)), playing at speed \(speed)...")

            let player = try AVAudioPlayer(data: data)
            player.enableRate = true
            player.rate = Float(speed)
            ttsAudioPlayer = player
            player.play()

            return "OK: speaking \(text.count) chars (\(languageCode))"
        } catch {
            log("speak_response: deepgram error: \(error)")
            return "Error: \(error.localizedDescription)"
        }
    }

    private static func speakViaSystem(text: String, voice: AVSpeechSynthesisVoice, languageCode: String, speed: Double) -> String {
        let voiceName = voice.name
        let wpm = max(80, min(360, Int(175.0 * speed)))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voiceName, "-r", "\(wpm)", text]
        do {
            try process.run()
            ttsSayProcess = process
            log("speak_response: system TTS via /usr/bin/say lang=\(languageCode), voice=\(voiceName), wpm=\(wpm)")
            return "OK: speaking \(text.count) chars (system, \(languageCode))"
        } catch {
            log("speak_response: /usr/bin/say failed (\(error)), falling back to AVSpeechSynthesizer")
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            let target = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
            utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, target))
            speechSynthesizer.speak(utterance)
            return "OK: speaking \(text.count) chars (system fallback, \(languageCode))"
        }
    }
}
