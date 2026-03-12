import AppKit
import Foundation
import GRDB

/// Executes tool calls from Gemini and returns results
/// Tools: execute_sql (read/write SQL on fazm.db), semantic_search (vector similarity)
@MainActor
class ChatToolExecutor {

    // MARK: - Onboarding State

    /// Set by OnboardingChatView before starting the chat
    static var onboardingAppState: AppState?
    /// Called when AI invokes complete_onboarding
    static var onCompleteOnboarding: (() -> Void)?
    /// Called when AI invokes ask_followup — delivers quick-reply options to the UI
    static var onQuickReplyOptions: ((_ options: [String]) -> Void)?
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

        case "get_daily_recap":
            return await executeDailyRecap(toolCall.arguments)

        case "complete_task":
            return await executeCompleteTask(toolCall.arguments)

        case "delete_task":
            return await executeDeleteTask(toolCall.arguments)

        case "google_workspace":
            return await executeGoogleWorkspace(toolCall.arguments)

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

        // If the query modified the action_items table, refresh TasksStore from local cache
        if changes > 0 {
            let upper = query.uppercased()
            if upper.contains("ACTION_ITEMS") {
                log("Tool execute_sql: action_items modified, refreshing TasksStore")
                await TasksStore.shared.reloadFromLocalCache()
                // Sync newly inserted action items to the backend (Firestore)
                if upper.contains("INSERT") {
                    await TasksStore.shared.retryUnsyncedItems(includeRecent: true)
                }
            }
        }

        return "OK: \(changes) row(s) affected"
    }

    // MARK: - Daily Recap

    /// Get a pre-formatted daily activity recap
    private static func executeDailyRecap(_ args: [String: Any]) async -> String {
        let daysAgo = max(0, (args["days_ago"] as? Int) ?? 1)
        let dateLabel = daysAgo == 0 ? "Today" : daysAgo == 1 ? "Yesterday" : "Past \(daysAgo) days"

        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else {
            return "Error: database not available"
        }

        // For today (daysAgo=0), upper bound is now; for past days, upper bound is start of today
        let upperBound = daysAgo == 0
            ? "datetime('now', 'localtime')"
            : "datetime('now', 'start of day', 'localtime')"

        do {
            return try await dbQueue.read { db in
                // Format compact markdown
                var out = "# \(dateLabel) Recap\n\n"

                // Recent chat messages
                let messages = try Row.fetchAll(db, sql: """
                    SELECT role, text, createdAt FROM chat_messages
                    WHERE createdAt >= datetime('now', 'start of day', '-\(daysAgo) day', 'localtime')
                        AND createdAt < \(upperBound)
                    ORDER BY createdAt DESC
                    LIMIT 50
                    """)

                out += "## Chat Messages (\(messages.count))\n"
                if messages.isEmpty {
                    out += "No chat messages found.\n"
                } else {
                    for msg in messages {
                        let role = msg["role"] as? String ?? "unknown"
                        let text = msg["text"] as? String ?? ""
                        let preview = text.count > 120 ? String(text.prefix(120)) + "..." : text
                        out += "- **\(role)**: \(preview)\n"
                    }
                }

                log("Tool get_daily_recap: \(messages.count) messages")
                return out
            }
        } catch {
            logError("Tool get_daily_recap failed", error: error)
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Task Tools

    /// Toggle a task's completion status via TasksStore (handles local + API sync)
    private static func executeCompleteTask(_ args: [String: Any]) async -> String {
        guard let taskId = args["task_id"] as? String, !taskId.isEmpty else {
            return "Error: task_id is required"
        }

        do {
            guard let task = try await ActionItemStorage.shared.getLocalActionItem(byBackendId: taskId) else {
                return "Error: task not found with id '\(taskId)'"
            }

            if task.deleted == true {
                return "Error: task '\(task.description)' has been deleted"
            }

            let wasCompleted = task.completed
            await TasksStore.shared.toggleTask(task)

            let newState = wasCompleted ? "incomplete" : "completed"
            log("Tool complete_task: toggled '\(task.description)' to \(newState)")
            return "OK: task '\(task.description)' marked as \(newState)"
        } catch {
            logError("Tool complete_task failed", error: error)
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Delete a task via TasksStore (handles local + API sync)
    private static func executeDeleteTask(_ args: [String: Any]) async -> String {
        guard let taskId = args["task_id"] as? String, !taskId.isEmpty else {
            return "Error: task_id is required"
        }

        do {
            guard let task = try await ActionItemStorage.shared.getLocalActionItem(byBackendId: taskId) else {
                return "Error: task not found with id '\(taskId)'"
            }

            if task.deleted == true {
                return "Error: task '\(task.description)' is already deleted"
            }

            await TasksStore.shared.deleteTask(task)

            log("Tool delete_task: deleted '\(task.description)'")
            return "OK: task '\(task.description)' deleted"
        } catch {
            logError("Tool delete_task failed", error: error)
            return "Error: \(error.localizedDescription)"
        }
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

        // Notify the UI to render quick-reply buttons
        onQuickReplyOptions?(options)

        return "Presented to user: \"\(question)\" with options: \(options.joined(separator: ", "))"
    }

    // MARK: - Google Workspace

    /// Path to the gws binary (bundled or system-installed)
    private static var gwsBinaryPath: String? {
        // Check bundled binary first
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("gws").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // Check common install locations
        for path in ["/usr/local/bin/gws", "/opt/homebrew/bin/gws"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Check npm global installs (various locations)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let npmPaths = [
            home.appendingPathComponent(".npm-global/bin/gws").path,
            home.appendingPathComponent(".nvm/versions/node").path, // check nvm below
        ]
        for path in npmPaths {
            if path.contains(".nvm") {
                // Search nvm node versions for gws
                if let versions = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    for version in versions.sorted().reversed() {
                        let gwsPath = "\(path)/\(version)/bin/gws"
                        if FileManager.default.isExecutableFile(atPath: gwsPath) {
                            return gwsPath
                        }
                    }
                }
            } else if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Check if gws is authenticated by looking for credential files
    private static var isGWSAuthenticated: Bool {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gws")
        let fm = FileManager.default
        // Check plain credentials (credentials.json)
        let plainCreds = configDir.appendingPathComponent("credentials.json").path
        if fm.fileExists(atPath: plainCreds) { return true }
        // Check global encrypted credentials (credentials.enc)
        let encCreds = configDir.appendingPathComponent("credentials.enc").path
        if fm.fileExists(atPath: encCreds) { return true }
        // Check per-account encrypted credentials (credentials.<base64_email>.enc)
        if let contents = try? fm.contentsOfDirectory(atPath: configDir.path) {
            return contents.contains { $0.hasPrefix("credentials.") && $0.hasSuffix(".enc") }
        }
        return false
    }


    /// List connected gws accounts by reading ~/.config/gws/accounts.json
    private static func listGWSAccounts() -> (accounts: [[String: String]], defaultAccount: String?) {
        let fm = FileManager.default
        let accountsFile = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gws/accounts.json")
        guard let data = fm.contents(atPath: accountsFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountsDict = json["accounts"] as? [String: Any] else {
            return ([], nil)
        }
        let defaultAccount = json["default"] as? String
        let accounts = accountsDict.keys.sorted().map { email -> [String: String] in
            ["email": email, "is_default": email == defaultAccount ? "true" : "false"]
        }
        return (accounts, defaultAccount)
    }

    /// Execute a Google Workspace tool action
    private static func executeGoogleWorkspace(_ args: [String: Any]) async -> String {
        guard let action = args["action"] as? String else {
            return "Error: 'action' parameter is required (status, accounts, login, exec)"
        }

        let account = args["account"] as? String

        switch action {
        case "status":
            guard let _ = gwsBinaryPath else {
                return """
                {"connected": false, "installed": false, "message": "Google Workspace CLI (gws) is not installed."}
                """
            }
            if isGWSAuthenticated {
                let (accounts, defaultAccount) = listGWSAccounts()
                let accountsJSON = (try? JSONSerialization.data(withJSONObject: accounts))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                return """
                {"connected": true, "installed": true, "accounts": \(accountsJSON), \
                "default_account": \(defaultAccount.map { "\"\($0)\"" } ?? "null"), \
                "message": "Google Workspace is connected. \(accounts.count) account(s) available."}
                """
            } else {
                return """
                {"connected": false, "installed": true, "accounts": [], \
                "message": "Google Workspace is not authenticated. Call with action 'login' to start the OAuth flow."}
                """
            }

        case "accounts":
            let (accounts, defaultAccount) = listGWSAccounts()
            if accounts.isEmpty {
                return """
                {"accounts": [], "message": "No Google accounts connected. Use action 'login' to add one."}
                """
            }
            let accountsJSON = (try? JSONSerialization.data(withJSONObject: accounts))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return """
            {"accounts": \(accountsJSON), "default_account": \(defaultAccount.map { "\"\($0)\"" } ?? "null")}
            """

        case "login":
            guard let gwsPath = gwsBinaryPath else {
                return """
                {"success": false, "message": "Google Workspace CLI (gws) is not installed."}
                """
            }
            // Skip login if already authenticated with the requested account
            if isGWSAuthenticated, let account = account {
                let (accounts, _) = listGWSAccounts()
                let hasAccount = accounts.contains { $0["email"] == account }
                if hasAccount {
                    log("GWS login skipped — already authenticated with \(account)")
                    return """
                    {"success": true, "already_connected": true, \
                    "message": "Already connected to Google Workspace as \(account). Ready to use Gmail, Calendar, Drive, Sheets, and Docs."}
                    """
                }
            }
            return await runGWSLogin(gwsPath: gwsPath, account: account)

        case "auth_callback":
            return await checkGWSAuthCallback()

        case "exec":
            guard let command = args["command"] as? String, !command.isEmpty else {
                return "Error: 'command' parameter is required for action 'exec'"
            }
            guard let gwsPath = gwsBinaryPath else {
                return "Error: Google Workspace CLI (gws) is not installed."
            }
            guard isGWSAuthenticated else {
                return """
                {"error": "not_authenticated", "message": "Google Workspace is not connected. \
                Call with action 'login' first."}
                """
            }
            return await runGWSCommand(gwsPath: gwsPath, command: command, account: account)

        default:
            return "Error: unknown action '\(action)'. Valid actions: status, accounts, login, auth_callback, exec"
        }
    }

    /// Active gws login process — kept alive while the AI completes OAuth via Playwright
    private static var activeLoginProcess: Process?

    /// Run `gws auth login` — extracts the OAuth URL, opens it in the user's default browser,
    /// and returns a message for the AI to inform the user and show quick-reply buttons.
    private static func runGWSLogin(gwsPath: String, account: String? = nil) async -> String {
        // Kill any previous login process
        activeLoginProcess?.terminate()
        activeLoginProcess = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gwsPath)
        var loginArgs = ["auth", "login", "-s", "gmail,calendar,drive"]
        if let account = account {
            loginArgs += ["--account", account]
        }
        process.arguments = loginArgs

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate both stdout and stderr — gws writes the OAuth URL to stderr
        let accumulator = StdoutAccumulator()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                accumulator.append(text)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                accumulator.append(text)
            }
        }

        do {
            try process.run()
            log("GWS auth login started (pid=\(process.processIdentifier))")

            // Wait for the OAuth URL to appear in stdout (up to 10 seconds)
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                let output = accumulator.text
                if let urlRange = output.range(of: "https://accounts.google.com[^\n ]*", options: .regularExpression) {
                    let authURL = String(output[urlRange])
                    log("GWS auth login: extracted OAuth URL (\(authURL.prefix(80))...)")

                    // Keep the process alive — it's listening on localhost for the OAuth callback
                    activeLoginProcess = process

                    // Open the OAuth URL in Chrome (where the user's sessions live)
                    await MainActor.run {
                        BrowserExtensionSetup.openURLInChrome(authURL)
                    }
                    log("GWS auth login: opened OAuth URL in Chrome")

                    // Monitor the gws process in the background — when it exits (OAuth callback received),
                    // automatically continue the conversation
                    let monitoredProcess = process
                    Task.detached {
                        // Poll until the process finishes (OAuth redirect hits localhost)
                        while monitoredProcess.isRunning {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                        let exitCode = monitoredProcess.terminationStatus
                        if exitCode == 0 {
                            log("GWS OAuth completed in browser — auto-continuing conversation")
                            await MainActor.run {
                                onSendFollowUp?("I've signed in to Google")
                            }
                        } else {
                            log("GWS OAuth process exited with code \(exitCode)")
                            await MainActor.run {
                                onQuickReplyOptions?(["Try again", "Cancel"])
                            }
                        }
                    }

                    // Return instructions for the AI to inform the user
                    return """
                    {"success": false, "action_required": "user_oauth", \
                    "message": "A Google sign-in page has been opened in the user's browser. \
                    Tell the user briefly that they need to sign in with their Google account and approve permissions for Fazm. \
                    The conversation will continue automatically once sign-in completes. \
                    Do NOT call ask_followup. Do NOT use Playwright or try to automate this. \
                    When the user says they've signed in, call google_workspace with action 'auth_callback' to verify, \
                    then retry the original request."}
                    """
                }
            }

            // URL never appeared
            process.terminate()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let allOutput = accumulator.text
            log("GWS auth login: no OAuth URL detected. output=\(allOutput.prefix(400))")
            return """
            {"success": false, "message": "Could not detect OAuth URL from gws. Output: \(String(allOutput.prefix(300)))"}
            """
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            logError("GWS auth login error", error: error)
            return """
            {"success": false, "message": "Failed to start login: \(error.localizedDescription)"}
            """
        }
    }

    /// Check if the background gws login process completed (called after user finishes OAuth in browser)
    private static func checkGWSAuthCallback() async -> String {
        guard let process = activeLoginProcess else {
            // No active login — check if we're already authenticated
            if isGWSAuthenticated {
                return """
                {"success": true, "message": "Google Workspace is connected and ready."}
                """
            }
            return """
            {"success": false, "message": "No active login session. Call with action 'login' first."}
            """
        }

        // Wait up to 15 seconds for the process to finish (OAuth callback should arrive quickly)
        for _ in 0..<30 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if process.isRunning {
            // Still waiting — OAuth callback hasn't arrived yet
            return """
            {"success": false, "message": "Still waiting for OAuth callback. Make sure you completed the Google sign-in flow in the browser and approved all permissions."}
            """
        }

        let exitCode = process.terminationStatus
        activeLoginProcess = nil

        if exitCode == 0 {
            log("GWS auth login completed successfully")
            return """
            {"success": true, "message": "Google Workspace connected successfully! You can now access Gmail, Calendar, Drive, Sheets, and Docs."}
            """
        } else {
            log("GWS auth login process exited with code \(exitCode)")
            return """
            {"success": false, "message": "OAuth flow completed but gws reported an error (exit code \(exitCode)). Try again."}
            """
        }
    }

    /// Thread-safe accumulator for reading process stdout asynchronously
    private class StdoutAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func append(_ text: String) {
            lock.lock()
            buffer += text
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// Parse a shell-like command string into arguments, respecting quotes
    private static func parseGWSArguments(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for char in command {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" && !inSingleQuote {
                escaped = true
            } else if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if char == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }

    /// Run a gws CLI command and return JSON output
    private static func runGWSCommand(gwsPath: String, command: String, account: String? = nil) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gwsPath)
        var cmdArgs = parseGWSArguments(command)
        if let account = account {
            cmdArgs += ["--account", account]
        }
        process.arguments = cmdArgs

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            // Wait up to 30 seconds for the command to complete
            let deadline = Date().addingTimeInterval(30)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if process.isRunning {
                process.terminate()
                return "Error: command timed out after 30 seconds"
            }

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let exitCode = process.terminationStatus

            if exitCode == 0 {
                // Truncate very large responses
                if stdout.count > 10000 {
                    return String(stdout.prefix(10000)) + "\n... (truncated, \(stdout.count) total characters)"
                }
                return stdout
            } else {
                let errMsg = stderr.isEmpty ? stdout : stderr
                log("GWS command failed: \(command) exit=\(exitCode) error=\(errMsg.prefix(500))")
                return "Error: \(errMsg.prefix(1000))"
            }
        } catch {
            logError("GWS command error", error: error)
            return "Error: \(error.localizedDescription)"
        }
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
