import Foundation
import GRDB

/// Actor-based database manager for Rewind screenshots
actor RewindDatabase {
    static let shared = RewindDatabase()

    private var dbQueue: DatabasePool?

    /// Track if we recovered from corruption (for UI notification)
    private(set) var didRecoverFromCorruption = false

    /// Track initialization state to prevent concurrent init attempts
    private var initializationTask: Task<Void, Error>?

    /// Path to the running flag file (used to detect unclean shutdown)
    private var runningFlagPath: String?

    /// The user ID this database is configured for (nil = not yet configured → "anonymous")
    private var configuredUserId: String?

    /// The user ID that was actually used to open the current database
    private var openedForUserId: String?

    /// Generation counter — incremented on close() so stale task completions don't corrupt state
    private var initGeneration: Int = 0

    /// Static user ID for nonisolated markCleanShutdown (set by configure(userId:))
    nonisolated(unsafe) static var currentUserId: String?

    /// Monotonic counter incremented by configure(). Used by closeIfStale() to detect
    /// whether a new sign-in session has started since the close was requested.
    nonisolated(unsafe) static var configureGeneration: Int = 0

    /// Runtime error tracking: consecutive SQLITE_IOERR/CORRUPT errors during normal queries.
    /// When this hits the threshold, we close the database so the next initialize() attempt
    /// goes through the full recovery path (WAL cleanup, corruption detection, fresh DB).
    private var consecutiveQueryIOErrors = 0
    private let maxQueryIOErrorsBeforeRecovery = 5

    // MARK: - Initialization

    private init() {}

    /// Whether the database has been successfully initialized
    var isInitialized: Bool { dbQueue != nil }

    /// Get the database pool for other storage actors
    func getDatabaseQueue() -> DatabasePool? {
        return dbQueue
    }

    /// Report a query error from a storage actor or subsystem.
    /// Tracks consecutive SQLITE_IOERR/CORRUPT errors. When the threshold is reached,
    /// closes the database so the next initialize() call triggers recovery.
    func reportQueryError(_ error: Error) {
        guard dbQueue != nil else { return }  // DB already closed, nothing to do
        guard let dbError = error as? DatabaseError else { return }
        let code = dbError.resultCode
        let extendedCode = dbError.extendedResultCode.rawValue
        let isIOError = code == .SQLITE_IOERR
        let isCorrupt = code == .SQLITE_CORRUPT
        let isCorruptFS = extendedCode == 6922

        guard isIOError || isCorrupt || isCorruptFS else { return }

        consecutiveQueryIOErrors += 1
        if consecutiveQueryIOErrors >= maxQueryIOErrorsBeforeRecovery {
            logError("RewindDatabase: \(consecutiveQueryIOErrors) consecutive I/O errors during queries, closing database for recovery")
            close()
            // Next getDatabaseQueue() returns nil → callers get databaseNotInitialized
            // Next initialize() call will go through full recovery path
        }
    }

    /// Report a successful query, resetting the runtime error counter.
    func reportQuerySuccess() {
        if consecutiveQueryIOErrors > 0 {
            consecutiveQueryIOErrors = 0
        }
    }

    /// Configure the database for a specific user.
    /// Does NOT close or reopen the database — call initialize() after this.
    /// initialize() will detect the user mismatch and reopen if needed.
    func configure(userId: String?) {
        let resolvedId = (userId?.isEmpty == false) ? userId! : "anonymous"
        configuredUserId = resolvedId
        RewindDatabase.currentUserId = resolvedId
        RewindDatabase.configureGeneration += 1
        log("RewindDatabase: Configured for user \(resolvedId) (generation \(RewindDatabase.configureGeneration))")
    }

    /// Close the database only if no new session has started (configure() not called since).
    /// Prevents a stale sign-out Task from closing a freshly opened database.
    func closeIfStale(generation: Int) {
        guard generation == RewindDatabase.configureGeneration else {
            log("RewindDatabase: Skipping stale close (requested gen \(generation), current gen \(RewindDatabase.configureGeneration))")
            return
        }
        close()
    }

    /// Close the database, allowing re-initialization for a different user.
    func close() {
        dbQueue = nil
        initializationTask = nil
        runningFlagPath = nil
        openedForUserId = nil
        initGeneration += 1
        log("RewindDatabase: Closed database (generation \(initGeneration))")
    }

    /// Switch to a different user's database.
    func switchUser(to userId: String?) async throws {
        close()
        configure(userId: userId)
        try await initialize()
    }

    /// Returns the per-user base directory: ~/Library/Application Support/Fazm/users/{userId}/
    /// Falls back to the static currentUserId (set synchronously at app start) when
    /// configure() hasn't been called yet (e.g., TierManager triggers init early).
    private func userBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userId = configuredUserId ?? RewindDatabase.currentUserId ?? "anonymous"
        return appSupport
            .appendingPathComponent("Fazm", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
    }

    /// Static version of userBaseDirectory for nonisolated markCleanShutdown
    private static func staticUserBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let userId = currentUserId ?? "anonymous"
        return appSupport
            .appendingPathComponent("Fazm", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
    }

    /// Mark a clean shutdown by removing the running flag file.
    /// Call from applicationWillTerminate to avoid unnecessary integrity checks on next launch.
    /// This is nonisolated so it can be called synchronously from the main thread during termination.
    nonisolated static func markCleanShutdown() {
        let userDir = staticUserBaseDirectory()
        let flagPath = userDir.appendingPathComponent(".fazm_running").path
        try? FileManager.default.removeItem(atPath: flagPath)
        log("RewindDatabase: Clean shutdown flagged")
    }

    /// Check if the previous session ended with an unclean shutdown (crash, force quit, etc.)
    func hadUncleanShutdown() -> Bool {
        let flagPath = userBaseDirectory().appendingPathComponent(".fazm_running").path
        return FileManager.default.fileExists(atPath: flagPath)
    }

    /// Initialize the database with migrations.
    /// If the DB is already open for the correct user, returns immediately.
    /// If the DB is open for a different user (e.g., "anonymous" before configure was called),
    /// closes it and reopens for the configured user.
    func initialize() async throws {
        let targetUser = configuredUserId ?? RewindDatabase.currentUserId ?? "anonymous"

        // Already initialized for the correct user
        if dbQueue != nil && openedForUserId == targetUser {
            return
        }

        // Initialized for wrong user — close and reopen
        if dbQueue != nil {
            log("RewindDatabase: Re-initializing for user \(targetUser) (was \(openedForUserId ?? "nil"))")
            close()
        }

        // If initialization is in progress, wait for it then re-check
        if let existingTask = initializationTask {
            _ = try? await existingTask.value
            // After waiting, check if the result is for the right user
            if dbQueue != nil && openedForUserId == targetUser {
                return
            }
            // Wrong user or failed — close and proceed
            if dbQueue != nil {
                close()
            }
        }

        // Start initialization
        let myGeneration = initGeneration
        let task = Task {
            try await performInitialization()
        }
        initializationTask = task

        do {
            try await task.value
            // Only clear if no close() happened since we started (generation unchanged)
            if initGeneration == myGeneration {
                initializationTask = nil
            }
        } catch {
            if initGeneration == myGeneration {
                initializationTask = nil
            }
            throw error
        }
    }

    /// Actual initialization logic (called only once at a time)
    private func performInitialization() async throws {
        guard dbQueue == nil else { return }

        let fazmDir = userBaseDirectory()

        // Create directory if needed (withIntermediateDirectories creates parents too)
        try FileManager.default.createDirectory(at: fazmDir, withIntermediateDirectories: true)

        // Migrate data from legacy path if this is first launch with per-user paths
        migrateFromLegacyPathIfNeeded(to: fazmDir)

        // Rename omi.db → fazm.db if needed (rebrand migration)
        let legacyOmiDB = fazmDir.appendingPathComponent("omi.db").path
        let fazmDBPath = fazmDir.appendingPathComponent("fazm.db").path
        if FileManager.default.fileExists(atPath: legacyOmiDB) && !FileManager.default.fileExists(atPath: fazmDBPath) {
            do {
                try FileManager.default.moveItem(atPath: legacyOmiDB, toPath: fazmDBPath)
                // Also move WAL/SHM if present
                for suffix in ["-wal", "-shm"] {
                    let src = legacyOmiDB + suffix
                    let dst = fazmDBPath + suffix
                    if FileManager.default.fileExists(atPath: src) {
                        try FileManager.default.moveItem(atPath: src, toPath: dst)
                    }
                }
                log("RewindDatabase: Migrated omi.db → fazm.db")
            } catch {
                logError("RewindDatabase: Failed to rename omi.db → fazm.db", error: error)
            }
        }

        let dbPath = fazmDir.appendingPathComponent("fazm.db").path
        let flagPath = fazmDir.appendingPathComponent(".fazm_running").path
        runningFlagPath = flagPath
        log("RewindDatabase: Opening database at \(dbPath)")

        // Detect unclean shutdown: if the running flag file exists, the previous launch
        // didn't exit cleanly (crash, force quit, power loss)
        let previousCrashed = FileManager.default.fileExists(atPath: flagPath)
        if previousCrashed {
            log("RewindDatabase: Unclean shutdown detected (running flag exists)")
        }

        // Clean up stale WAL files that can cause disk I/O errors (SQLite error 10)
        if FileManager.default.fileExists(atPath: dbPath) {
            cleanupStaleWALFiles(at: dbPath)
        }

        var config = Configuration()
        config.prepareDatabase { db in
            // Try to enable WAL mode for better crash resistance and performance
            // WAL mode keeps writes in a separate file, making corruption much less likely
            // If WAL fails (disk I/O error, permissions), continue with default journal mode
            do {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                // synchronous = NORMAL is safe with WAL and much faster than FULL
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                // Auto-checkpoint every 1000 pages (~4MB) for WAL
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
            } catch {
                // WAL mode failed - log but continue with default journal mode
                // This can happen with disk I/O errors, permission issues, or full disk
                log("RewindDatabase: WAL mode unavailable (\(error.localizedDescription)), using default journal mode")
            }

            // Enable foreign keys (required)
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            // Set busy timeout to avoid "database is locked" errors (5 seconds)
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        let queue: DatabasePool
        do {
            queue = try DatabasePool(path: dbPath, configuration: config)
        } catch {
            // If opening fails (e.g. disk I/O error on WAL), try once more without WAL files
            log("RewindDatabase: Failed to open database: \(error), cleaning WAL and retrying...")
            removeWALFiles(at: dbPath)
            do {
                queue = try DatabasePool(path: dbPath, configuration: config)
            } catch let retryError {
                // If still failing, check for database corruption:
                //   - SQLITE_CORRUPT (error 11): malformed database
                //   - SQLITE_IOERR_CORRUPTFS (extended code 6922): filesystem reports file
                //     corruption, commonly caused by migrating WAL files to a new path
                let isCorrupted: Bool
                if let dbError = retryError as? DatabaseError {
                    let isCorruptError = dbError.resultCode == .SQLITE_CORRUPT
                    let isCorruptFS = dbError.extendedResultCode.rawValue == 6922 // SQLITE_IOERR_CORRUPTFS
                    isCorrupted = isCorruptError || isCorruptFS
                } else {
                    isCorrupted = "\(retryError)".contains("malformed")
                }

                if isCorrupted && FileManager.default.fileExists(atPath: dbPath) {
                    log("RewindDatabase: Database is corrupted (error: \(retryError)), attempting recovery...")
                    try await handleCorruptedDatabase(at: dbPath, in: fazmDir)
                    // Retry with recovered or fresh database
                    queue = try DatabasePool(path: dbPath, configuration: config)
                } else {
                    throw retryError
                }
            }
        }

        // Post-open health check: verify we can actually run queries on the opened database.
        // This catches cases where the DB opens successfully (PRAGMAs pass) but data queries
        // fail with SQLITE_IOERR — e.g., stale WAL files from migration, page-level corruption.
        var activeQueue = queue
        do {
            try await activeQueue.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
            }
        } catch {
            if let dbError = error as? DatabaseError,
               dbError.resultCode == .SQLITE_IOERR || dbError.resultCode == .SQLITE_CORRUPT {
                log("RewindDatabase: Database opened but queries fail (\(error)), removing WAL and retrying...")
                removeWALFiles(at: dbPath)
                let retryQueue = try DatabasePool(path: dbPath, configuration: config)
                try await retryQueue.read { db in
                    _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
                }
                activeQueue = retryQueue
            } else {
                throw error
            }
        }

        dbQueue = activeQueue
        openedForUserId = configuredUserId ?? RewindDatabase.currentUserId ?? "anonymous"
        consecutiveQueryIOErrors = 0

        try migrate(activeQueue)

        // After unclean shutdown, do a cheap schema sanity check (not a full DB scan).
        // PRAGMA quick_check scans the ENTIRE database regardless of the (N) argument
        // (N only limits error reporting), so on large databases (e.g. 4+ GB) it can take 60-90s.
        if previousCrashed {
            log("RewindDatabase: Running lightweight integrity check after unclean shutdown...")
            try verifyDatabaseIntegrity(activeQueue)
        } else {
            // Still log journal mode on clean startup (cheap PRAGMA, no full check)
            try await activeQueue.read { db in
                let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
                log("RewindDatabase: Journal mode is \(journalMode ?? "unknown")")
            }
        }

        // Set running flag — will be cleared on clean shutdown
        FileManager.default.createFile(atPath: flagPath, contents: nil)

        log("RewindDatabase: Initialized successfully")
    }

    // MARK: - Legacy Migration

    /// Migrate data from the legacy shared path (Fazm/) or from the anonymous fallback
    /// (Fazm/users/anonymous/) to the per-user path (Fazm/users/{userId}/).
    /// Handles both first-time migration (DB move) and partial re-runs (directory merges).
    private func migrateFromLegacyPathIfNeeded(to userDir: URL) {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fazmDir = appSupport.appendingPathComponent("Fazm", isDirectory: true)

        // Determine migration source: prefer legacy root (Fazm/fazm.db), fall back to anonymous dir.
        // The anonymous fallback covers the case where TierManager or another early caller
        // triggered initialize() before configure(userId:) was called, causing data to land
        // in users/anonymous/ instead of the real user's directory.
        let legacyDB = fazmDir.appendingPathComponent("fazm.db")
        let anonymousDir = fazmDir
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent("anonymous", isDirectory: true)

        let effectiveUserId = configuredUserId ?? RewindDatabase.currentUserId ?? "anonymous"
        let sourceDir: URL
        if fileManager.fileExists(atPath: legacyDB.path) {
            sourceDir = fazmDir
        } else if effectiveUserId != "anonymous",
                  fileManager.fileExists(atPath: anonymousDir.path) {
            // Check if anonymous dir has anything worth migrating (DB, Videos, Screenshots, backups)
            let hasContent = ["fazm.db", "Screenshots", "Videos", "backups"].contains {
                fileManager.fileExists(atPath: anonymousDir.appendingPathComponent($0).path)
            }
            guard hasContent else { return }
            sourceDir = anonymousDir
        } else {
            return // Nothing to migrate
        }

        // Don't migrate to ourselves
        guard sourceDir.path != userDir.path else { return }

        log("RewindDatabase: Migrating data from \(sourceDir.path) to \(userDir.path)")

        // Items to migrate: fazm.db, Screenshots/, Videos/, backups/
        // IMPORTANT: Do NOT move fazm.db-wal, fazm.db-shm, or .fazm_running:
        //   - WAL/SHM files are path-bound. Moving them to a new directory makes them
        //     invalid, causing SQLITE_IOERR_CORRUPTFS (error 6922) on the next open.
        //     SQLite will cleanly recover without stale WAL files.
        //   - .fazm_running would falsely trigger unclean-shutdown recovery at the
        //     destination, running an expensive integrity check on the migrated DB.
        let itemsToMove = [
            "fazm.db", "Screenshots", "Videos", "backups",
        ]

        // Checkpoint WAL at destination before deleting — preserves recent writes
        // (e.g. knowledge graph saved during onboarding, before app restart for permissions)
        let destDB = userDir.appendingPathComponent("fazm.db")
        if fileManager.fileExists(atPath: destDB.path) {
            let destWAL = userDir.appendingPathComponent("fazm.db-wal")
            if fileManager.fileExists(atPath: destWAL.path) {
                do {
                    let config = Configuration()
                    let pool = try DatabasePool(path: destDB.path, configuration: config)
                    try pool.write { db in
                        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    }
                    try pool.close()
                    log("RewindDatabase: Checkpointed WAL at dest before migration")
                } catch {
                    log("RewindDatabase: WAL checkpoint failed: \(error.localizedDescription)")
                }
            }
        }

        // Delete WAL/SHM and running flag at source AND destination — do NOT migrate them.
        // Stale WAL/SHM at the destination (from a prior partial migration or crash) would
        // also cause SQLITE_IOERR_CORRUPTFS when SQLite opens the migrated DB.
        for staleFile in ["fazm.db-wal", "fazm.db-shm", ".fazm_running"] {
            for dir in [sourceDir, userDir] {
                let path = dir.appendingPathComponent(staleFile)
                if fileManager.fileExists(atPath: path.path) {
                    try? fileManager.removeItem(at: path)
                    let label = dir == sourceDir ? "source" : "dest"
                    log("RewindDatabase: Deleted \(staleFile) from \(label) (not migrating)")
                }
            }
        }

        for name in itemsToMove {
            let source = sourceDir.appendingPathComponent(name)
            let dest = userDir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: source.path, isDirectory: &isDir)

            do {
                if isDir.boolValue && fileManager.fileExists(atPath: dest.path) {
                    // Both source and dest dirs exist — merge contents (move each child item)
                    let children = try fileManager.contentsOfDirectory(atPath: source.path)
                    var moved = 0
                    for child in children {
                        let childSrc = source.appendingPathComponent(child)
                        let childDst = dest.appendingPathComponent(child)
                        if fileManager.fileExists(atPath: childDst.path) { continue }
                        try fileManager.moveItem(at: childSrc, to: childDst)
                        moved += 1
                    }
                    // Remove source dir if now empty
                    let remaining = try? fileManager.contentsOfDirectory(atPath: source.path)
                    if remaining?.isEmpty == true {
                        try? fileManager.removeItem(at: source)
                    }
                    log("RewindDatabase: Merged \(name) (\(moved) items moved)")
                } else if fileManager.fileExists(atPath: dest.path) {
                    // File already exists at dest — remove stale source copy
                    try? fileManager.removeItem(at: source)
                    log("RewindDatabase: Removed stale \(name) from source (already at dest)")
                } else {
                    try fileManager.moveItem(at: source, to: dest)
                    log("RewindDatabase: Migrated \(name)")
                }
            } catch {
                log("RewindDatabase: Failed to migrate \(name): \(error.localizedDescription)")
            }
        }

        // Clean up source dir if it's now empty (don't leave empty anonymous/ dirs around)
        if sourceDir != fazmDir {
            let remaining = try? fileManager.contentsOfDirectory(atPath: sourceDir.path)
            if remaining?.isEmpty == true {
                try? fileManager.removeItem(at: sourceDir)
                log("RewindDatabase: Removed empty source dir \(sourceDir.lastPathComponent)")
            }
        }

        log("RewindDatabase: Legacy migration complete")
    }

    // MARK: - Corruption Detection & Recovery

    /// Check if database file is corrupted using quick_check
    /// Returns true if corrupted, false if OK
    private func checkDatabaseCorruption(at path: String) async -> Bool {
        // Open in read-write mode (NOT readonly) because WAL recovery requires write access.
        // Opening readonly with a pending WAL file causes SQLITE_CANTOPEN (error 14),
        // which is a false positive - the database isn't actually corrupted.
        do {
            let testQueue = try DatabaseQueue(path: path)
            let result = try await testQueue.read { db -> String in
                try String.fetchOne(db, sql: "PRAGMA quick_check(1)") ?? "ok"
            }
            return result.lowercased() != "ok"
        } catch {
            // If we can't even open the database, it's definitely corrupted
            log("RewindDatabase: Database failed to open for integrity check: \(error)")
            return true
        }
    }

    /// Clean up stale WAL/SHM files that can cause disk I/O errors (SQLite error 10, code 3850)
    /// This happens when the app crashes and leaves behind WAL files that are in a bad state
    private func cleanupStaleWALFiles(at dbPath: String) {
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let fileManager = FileManager.default

        // Only clean up if WAL file exists and is empty (indicates stale/orphaned WAL)
        // Non-empty WAL files may contain uncommitted data we don't want to lose
        if fileManager.fileExists(atPath: walPath),
           let attrs = try? fileManager.attributesOfItem(atPath: walPath),
           let size = attrs[.size] as? Int64, size == 0 {
            try? fileManager.removeItem(atPath: walPath)
            try? fileManager.removeItem(atPath: shmPath)
            log("RewindDatabase: Cleaned up stale empty WAL/SHM files")
        }
    }

    /// Force-remove WAL/SHM files (last resort when database won't open)
    private func removeWALFiles(at dbPath: String) {
        let fileManager = FileManager.default
        for ext in ["-wal", "-shm"] {
            let filePath = dbPath + ext
            if fileManager.fileExists(atPath: filePath) {
                try? fileManager.removeItem(atPath: filePath)
                log("RewindDatabase: Removed \(ext) file for recovery")
            }
        }
    }

    /// Number of records recovered from corrupted database (0 if none)
    private(set) var recoveredRecordCount: Int = 0

    /// Handle corrupted database: attempt recovery, backup, and recreate
    private func handleCorruptedDatabase(at dbPath: String, in fazmDir: URL) async throws {
        let fileManager = FileManager.default

        // Create backup directory
        let backupDir = fazmDir.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Generate backup filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let backupPath = backupDir.appendingPathComponent("omi_corrupted_\(timestamp).db")

        // Backup the corrupted database (for potential manual recovery)
        log("RewindDatabase: Backing up corrupted database to \(backupPath.path)")
        try fileManager.copyItem(atPath: dbPath, toPath: backupPath.path)

        // Attempt to recover data from corrupted database
        let recoveredPath = fazmDir.appendingPathComponent("fazm_recovered.db").path
        let recoveredCount = await attemptDataRecovery(from: dbPath, to: recoveredPath)
        recoveredRecordCount = recoveredCount

        if recoveredCount > 0 {
            log("RewindDatabase: Recovered \(recoveredCount) records from corrupted database")
            // Use recovered database instead of creating fresh one
            try fileManager.removeItem(atPath: dbPath)
            try fileManager.moveItem(atPath: recoveredPath, toPath: dbPath)

            // Remove WAL/SHM files from corrupted database
            for ext in ["-wal", "-shm", "-journal"] {
                let file = dbPath + ext
                if fileManager.fileExists(atPath: file) {
                    try? fileManager.removeItem(atPath: file)
                }
            }

            log("RewindDatabase: Using recovered database with \(recoveredCount) records")
        } else {
            // No data recovered, remove corrupted database and start fresh
            log("RewindDatabase: No data could be recovered, creating fresh database")

            // Clean up recovery attempt if it exists
            if fileManager.fileExists(atPath: recoveredPath) {
                try? fileManager.removeItem(atPath: recoveredPath)
            }

            // Remove corrupted database and associated WAL/SHM files
            let filesToRemove = [
                dbPath,
                dbPath + "-wal",
                dbPath + "-shm",
                dbPath + "-journal"
            ]

            for file in filesToRemove {
                if fileManager.fileExists(atPath: file) {
                    try fileManager.removeItem(atPath: file)
                    log("RewindDatabase: Removed \(file)")
                }
            }
        }

        logError("RewindDatabase: Corrupted database backed up and removed. A fresh database will be created.")

        // Clean up old backups (keep only last 5)
        try await cleanupOldBackups(in: backupDir, keepCount: 5)
    }

    /// Attempt to recover data from a corrupted database using sqlite3 .recover
    /// Returns the number of records recovered (counted from the memories table)
    private func attemptDataRecovery(from corruptedPath: String, to recoveredPath: String) async -> Int {
        let fileManager = FileManager.default

        // Remove any existing recovered database
        if fileManager.fileExists(atPath: recoveredPath) {
            try? fileManager.removeItem(atPath: recoveredPath)
        }

        // Run sqlite3 recovery in a detached task to avoid blocking the actor
        let (success, recoveredSQL) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Data), Never>) in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = [corruptedPath, ".recover"]

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: (true, data))
                    } else {
                        continuation.resume(returning: (false, Data()))
                    }
                } catch {
                    continuation.resume(returning: (false, Data()))
                }
            }
        }

        if success && !recoveredSQL.isEmpty {
            let importSuccess = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Task.detached {
                    let importProcess = Process()
                    importProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                    importProcess.arguments = [recoveredPath]

                    let inputPipe = Pipe()
                    importProcess.standardInput = inputPipe
                    importProcess.standardOutput = FileHandle.nullDevice
                    importProcess.standardError = FileHandle.nullDevice

                    do {
                        try importProcess.run()
                        inputPipe.fileHandleForWriting.write(recoveredSQL)
                        inputPipe.fileHandleForWriting.closeFile()
                        importProcess.waitUntilExit()
                        continuation.resume(returning: importProcess.terminationStatus == 0)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }

            if importSuccess && fileManager.fileExists(atPath: recoveredPath) {
                // Count recovered memories as a proxy for recovery success
                do {
                    let queue = try DatabaseQueue(path: recoveredPath)
                    return try await queue.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
                    }
                } catch {
                    return 0
                }
            }
        }

        return 0
    }

    /// Clean up old database backups, keeping only the most recent ones
    private func cleanupOldBackups(in backupDir: URL, keepCount: Int) async throws {
        let fileManager = FileManager.default

        let files = try fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "db" }

        // Sort by creation date, newest first
        let sortedFiles = files.sorted { file1, file2 in
            let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }

        // Remove files beyond keepCount
        for file in sortedFiles.dropFirst(keepCount) {
            try fileManager.removeItem(at: file)
            log("RewindDatabase: Removed old backup \(file.lastPathComponent)")
        }
    }

    /// Verify database integrity after successful initialization
    private func verifyDatabaseIntegrity(_ queue: DatabasePool) throws {
        try queue.read { db in
            // Cheap schema-level check: verify we can read from a core table and the page count.
            // Avoids PRAGMA quick_check which scans the entire DB (75s+ on 4 GB databases).
            let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let dbSizeMB = (pageCount * pageSize) / (1024 * 1024)
            log("RewindDatabase: Database size ~\(dbSizeMB) MB (\(pageCount) pages)")

            // Verify schema is readable by querying sqlite_master
            let tableCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table'") ?? 0
            log("RewindDatabase: Schema OK (\(tableCount) tables)")

            // Log journal mode (WAL preferred, but may fall back to delete/rollback)
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
            log("RewindDatabase: Journal mode is \(journalMode ?? "unknown")")

            // Log warning if not using WAL (less crash-resistant)
            if journalMode?.lowercased() != "wal" {
                log("RewindDatabase: WARNING - Not using WAL mode, database may be less crash-resistant")
            }
        }
    }

    // MARK: - Migrations

    private func migrate(_ queue: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        // Single clean migration for Fazm (no legacy OMI tables).
        // Creates only the 5 active tables used by the app.
        migrator.registerMigration("fazmV1") { db in

            // 1. memories
            try db.create(table: "memories") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("backendId", .text).unique()
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
                t.column("content", .text).notNull()
                t.column("category", .text).notNull()
                t.column("tagsJson", .text)
                t.column("visibility", .text).notNull().defaults(to: "private")
                t.column("reviewed", .boolean).notNull().defaults(to: false)
                t.column("userReview", .boolean)
                t.column("manuallyAdded", .boolean).notNull().defaults(to: false)
                t.column("scoring", .text)
                t.column("source", .text)
                t.column("conversationId", .text)
                t.column("confidence", .double)
                t.column("reasoning", .text)
                t.column("sourceApp", .text)
                t.column("windowTitle", .text)
                t.column("contextSummary", .text)
                t.column("currentActivity", .text)
                t.column("inputDeviceName", .text)
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isDismissed", .boolean).notNull().defaults(to: false)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("headline", .text)
                t.column("accessCount", .integer).notNull().defaults(to: 0)
                t.column("lastAccessedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_memories_backend_id", on: "memories", columns: ["backendId"])
            try db.create(index: "idx_memories_created", on: "memories", columns: ["createdAt"])
            try db.create(index: "idx_memories_category", on: "memories", columns: ["category"])
            try db.create(index: "idx_memories_synced", on: "memories", columns: ["backendSynced"])
            try db.create(index: "idx_memories_deleted", on: "memories", columns: ["deleted"])

            // 2. ai_user_profiles
            try db.create(table: "ai_user_profiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileText", .text).notNull()
                t.column("dataSourcesUsed", .integer).notNull()
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
                t.column("generatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_ai_user_profiles_generated",
                          on: "ai_user_profiles", columns: ["generatedAt"])

            // 3. indexed_files
            try db.create(table: "indexed_files") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("fileExtension", .text)
                t.column("fileType", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.column("folder", .text).notNull()
                t.column("depth", .integer).notNull()
                t.column("createdAt", .datetime)
                t.column("modifiedAt", .datetime)
                t.column("indexedAt", .datetime).notNull()
            }
            try db.create(index: "idx_indexed_files_path", on: "indexed_files", columns: ["path"], unique: true)
            try db.create(index: "idx_indexed_files_type", on: "indexed_files", columns: ["fileType"])
            try db.create(index: "idx_indexed_files_folder", on: "indexed_files", columns: ["folder"])
            try db.create(index: "idx_indexed_files_ext", on: "indexed_files", columns: ["fileExtension"])
            try db.create(index: "idx_indexed_files_modified", on: "indexed_files", columns: ["modifiedAt"])

            // 4. local_kg_nodes
            try db.create(table: "local_kg_nodes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("nodeId", .text).notNull().unique()
                t.column("label", .text).notNull()
                t.column("nodeType", .text).notNull()
                t.column("aliasesJson", .text)
                t.column("sourceFileIds", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // 5. local_kg_edges
            try db.create(table: "local_kg_edges") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("edgeId", .text).notNull().unique()
                t.column("sourceNodeId", .text).notNull()
                t.column("targetNodeId", .text).notNull()
                t.column("label", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        // V2: Add task_chat_messages for onboarding message persistence
        migrator.registerMigration("fazmV2") { db in
            try db.create(table: "task_chat_messages") { t in
                t.column("taskId", .text).notNull()
                t.column("messageId", .text).notNull().unique()
                t.column("sender", .text).notNull()
                t.column("messageText", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_task_chat_messages_task",
                          on: "task_chat_messages", columns: ["taskId"])
        }

        try migrator.migrate(queue)
    }


    // MARK: - CRUD Operations

    /// Insert a new screenshot record
    @discardableResult
    func insertScreenshot(_ screenshot: Screenshot) throws -> Screenshot {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.write { db -> Screenshot in
            let record = screenshot
            try record.insert(db)
            return record
        }
    }

    /// Update OCR text for a screenshot (legacy - without bounding boxes)
    func updateOCRText(id: Int64, ocrText: String) throws {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE screenshots SET ocrText = ?, isIndexed = 1 WHERE id = ?",
                arguments: [ocrText, id]
            )
        }
    }

    /// Update OCR result with bounding boxes for a screenshot
    func updateOCRResult(id: Int64, ocrResult: OCRResult) throws {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        let ocrDataJson: String?
        do {
            let data = try JSONEncoder().encode(ocrResult)
            ocrDataJson = String(data: data, encoding: .utf8)
        } catch {
            ocrDataJson = nil
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE screenshots SET ocrText = ?, ocrDataJson = ?, isIndexed = 1, skippedForBattery = 0 WHERE id = ?",
                arguments: [ocrResult.fullText, ocrDataJson, id]
            )
        }
    }

    /// Get screenshots pending OCR processing
    func getPendingOCRScreenshots(limit: Int = 10) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .filter(Column("isIndexed") == false)
                .order(Column("timestamp").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get screenshots that were skipped due to battery and need OCR backfill
    func getBatterySkippedScreenshots(limit: Int = 10) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .filter(Column("skippedForBattery") == true)
                .order(Column("timestamp").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Clear skippedForBattery flag for a screenshot that can't be processed (e.g. missing file)
    func clearSkippedForBattery(id: Int64) throws {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE screenshots SET skippedForBattery = 0 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Get screenshot by ID
    func getScreenshot(id: Int64) throws -> Screenshot? {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot.fetchOne(db, key: id)
        }
    }

    // MARK: - Screenshot Embedding Methods

    /// Store embedding BLOB for a screenshot
    func updateScreenshotEmbedding(id: Int64, embedding: Data) throws {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE screenshots SET embedding = ? WHERE id = ?",
                arguments: [embedding, id]
            )
        }
    }

    /// Get screenshots missing embeddings (for backfill)
    func getScreenshotsMissingEmbeddings(limit: Int = 100) throws -> [(id: Int64, ocrText: String, appName: String, windowTitle: String?)] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, ocrText, appName, windowTitle FROM screenshots
                WHERE embedding IS NULL AND ocrText IS NOT NULL AND LENGTH(ocrText) >= 20
                ORDER BY id LIMIT ?
            """, arguments: [limit]).compactMap { row in
                guard let id: Int64 = row["id"],
                      let ocrText: String = row["ocrText"],
                      let appName: String = row["appName"] else { return nil }
                let windowTitle: String? = row["windowTitle"]
                return (id: id, ocrText: ocrText, appName: appName, windowTitle: windowTitle)
            }
        }
    }

    /// Read screenshot embedding BLOBs in batches for disk-based vector search
    func readEmbeddingBatch(startDate: Date, endDate: Date, appFilter: String? = nil, limit: Int = 5000, offset: Int = 0) throws -> [(screenshotId: Int64, embedding: Data)] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            var sql = """
                SELECT id, embedding FROM screenshots
                WHERE embedding IS NOT NULL
                  AND timestamp >= ? AND timestamp <= ?
            """
            var arguments: [DatabaseValueConvertible] = [startDate, endDate]

            if let app = appFilter {
                sql += " AND appName = ?"
                arguments.append(app)
            }

            sql += " ORDER BY id LIMIT ? OFFSET ?"
            arguments.append(limit)
            arguments.append(offset)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).compactMap { row in
                guard let id: Int64 = row["id"],
                      let embedding: Data = row["embedding"] else { return nil }
                return (screenshotId: id, embedding: embedding)
            }
        }
    }

    /// Get screenshots for a date range
    func getScreenshots(from startDate: Date, to endDate: Date, limit: Int = 100) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .filter(Column("timestamp") >= startDate && Column("timestamp") <= endDate)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get screenshots filtered by allowed apps and browser window title patterns.
    /// For non-browser apps in the allowed list, all windows are returned.
    /// For browser apps, only windows matching at least one pattern are returned.
    func getScreenshotsFiltered(
        from startDate: Date,
        to endDate: Date,
        allowedApps: Set<String>,
        browserApps: Set<String>,
        browserWindowPatterns: [String],
        limit: Int = 100
    ) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        guard !allowedApps.isEmpty else { return [] }

        let nonBrowserApps = allowedApps.subtracting(browserApps)
        let allowedBrowserApps = allowedApps.intersection(browserApps)

        // Build SQL with two conditions OR'd:
        // 1. Non-browser allowed apps (all windows)
        // 2. Browser allowed apps with window title LIKE any pattern
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        // Timestamp range
        arguments.append(startDate)
        arguments.append(endDate)

        // Non-browser apps
        if !nonBrowserApps.isEmpty {
            let placeholders = nonBrowserApps.map { _ in "?" }.joined(separator: ", ")
            conditions.append("appName IN (\(placeholders))")
            for app in nonBrowserApps.sorted() {
                arguments.append(app)
            }
        }

        // Browser apps with window pattern matching
        if !allowedBrowserApps.isEmpty && !browserWindowPatterns.isEmpty {
            let appPlaceholders = allowedBrowserApps.map { _ in "?" }.joined(separator: ", ")
            let patternClauses = browserWindowPatterns.map { _ in "windowTitle LIKE ?" }.joined(separator: " OR ")
            conditions.append("(appName IN (\(appPlaceholders)) AND windowTitle IS NOT NULL AND (\(patternClauses)))")
            for app in allowedBrowserApps.sorted() {
                arguments.append(app)
            }
            for pattern in browserWindowPatterns {
                arguments.append("%\(pattern)%")
            }
        }

        guard !conditions.isEmpty else {
            log("RewindDatabase.getScreenshotsFiltered: No conditions generated, returning empty")
            return []
        }

        let sql = """
            SELECT * FROM screenshots
            WHERE timestamp >= ? AND timestamp <= ? AND (\(conditions.joined(separator: " OR ")))
            ORDER BY timestamp DESC
            LIMIT ?
        """
        arguments.append(limit)

        log("RewindDatabase.getScreenshotsFiltered: Executing query")
        log("  SQL: \(sql)")
        log("  Date range: \(startDate) to \(endDate)")
        log("  nonBrowserApps: \(nonBrowserApps.sorted())")
        log("  allowedBrowserApps: \(allowedBrowserApps.sorted())")
        log("  browserWindowPatterns count: \(browserWindowPatterns.count)")
        log("  Total arguments count: \(arguments.count)")

        return try dbQueue.read { db in
            let results = try Screenshot.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            log("RewindDatabase.getScreenshotsFiltered: Returned \(results.count) screenshots")
            return results
        }
    }

    /// Get recent screenshots
    func getRecentScreenshots(limit: Int = 50) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get all unique app names
    func getUniqueAppNames() throws -> [String] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT appName FROM screenshots ORDER BY appName")
        }
    }

    // MARK: - Search

    /// Expand a search query by splitting compound words (camelCase, numbers)
    /// e.g., "ActivityPerformance" -> "(ActivityPerformance* OR Activity* OR Performance*)"
    private func expandSearchQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Split query into words
        let words = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        let expandedWords = words.map { word -> String in
            var parts: [String] = [word]

            // Split camelCase: "ActivityPerformance" -> ["Activity", "Performance"]
            let camelCaseParts = splitCamelCase(word)
            if camelCaseParts.count > 1 {
                parts.append(contentsOf: camelCaseParts)
            }

            // Split on number boundaries: "test123" -> ["test", "123"]
            let numberParts = splitOnNumbers(word)
            if numberParts.count > 1 {
                parts.append(contentsOf: numberParts)
            }

            // Remove duplicates and create OR query with prefix matching
            let uniqueParts = Array(Set(parts)).filter { $0.count >= 2 }
            if uniqueParts.count == 1 {
                return "\(uniqueParts[0])*"
            } else {
                let prefixParts = uniqueParts.map { "\($0)*" }
                return "(\(prefixParts.joined(separator: " OR ")))"
            }
        }

        return expandedWords.joined(separator: " ")
    }

    /// Split camelCase string into parts
    private func splitCamelCase(_ string: String) -> [String] {
        var parts: [String] = []
        var currentPart = ""

        for char in string {
            if char.isUppercase && !currentPart.isEmpty {
                parts.append(currentPart)
                currentPart = String(char)
            } else {
                currentPart.append(char)
            }
        }

        if !currentPart.isEmpty {
            parts.append(currentPart)
        }

        return parts.filter { $0.count >= 2 }
    }

    /// Split string on number boundaries
    private func splitOnNumbers(_ string: String) -> [String] {
        var parts: [String] = []
        var currentPart = ""
        var wasDigit = false

        for char in string {
            let isDigit = char.isNumber
            if !currentPart.isEmpty && isDigit != wasDigit {
                parts.append(currentPart)
                currentPart = String(char)
            } else {
                currentPart.append(char)
            }
            wasDigit = isDigit
        }

        if !currentPart.isEmpty {
            parts.append(currentPart)
        }

        return parts.filter { $0.count >= 2 }
    }

    /// Full-text search on OCR text, window titles, and app names
    /// - Parameters:
    ///   - query: Search query (supports compound word expansion)
    ///   - appFilter: Optional app name filter (exact match)
    ///   - startDate: Optional start date for time range
    ///   - endDate: Optional end date for time range
    ///   - limit: Maximum results to return
    func search(
        query: String,
        appFilter: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 100
    ) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // Expand the query for better matching
        let expandedQuery = expandSearchQuery(query)
        guard !expandedQuery.isEmpty else {
            return []
        }

        return try dbQueue.read { db in
            var sql = """
                SELECT screenshots.* FROM screenshots
                JOIN screenshots_fts ON screenshots.id = screenshots_fts.rowid
                WHERE screenshots_fts MATCH ?
                """
            var arguments: [DatabaseValueConvertible] = [expandedQuery]

            // App filter (exact match, separate from FTS)
            if let app = appFilter {
                sql += " AND screenshots.appName = ?"
                arguments.append(app)
            }

            // Time range filtering
            if let start = startDate {
                sql += " AND screenshots.timestamp >= ?"
                arguments.append(start)
            }

            if let end = endDate {
                sql += " AND screenshots.timestamp <= ?"
                arguments.append(end)
            }

            // Order by relevance (BM25) then by timestamp
            sql += " ORDER BY bm25(screenshots_fts) ASC, screenshots.timestamp DESC LIMIT ?"
            arguments.append(limit)

            return try Screenshot.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Delete Result Types

    /// Result of bulk screenshot deletion (for cleanup)
    struct DeleteResult {
        let imagePaths: [String]           // Legacy JPEG paths to delete
        let orphanedVideoChunks: [String]  // Video chunks with all frames deleted
    }

    /// Result of single screenshot deletion
    struct SingleDeleteResult {
        let imagePath: String?
        let videoChunkPath: String?
        let isLastFrameInChunk: Bool
    }

    // MARK: - Cleanup

    /// Delete screenshots older than the specified date
    func deleteScreenshotsOlderThan(_ date: Date) throws -> DeleteResult {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // First get the image paths to delete (legacy JPEGs)
        let imagePaths = try dbQueue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM screenshots WHERE timestamp < ? AND imagePath IS NOT NULL",
                arguments: [date]
            )
        }

        // Get video chunk paths that will have frames deleted
        let videoChunksToCheck = try dbQueue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT videoChunkPath FROM screenshots WHERE timestamp < ? AND videoChunkPath IS NOT NULL",
                arguments: [date]
            )
        }

        // Delete the records
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM screenshots WHERE timestamp < ?",
                arguments: [date]
            )
        }

        // Check which video chunks are now orphaned (no remaining frames)
        let orphanedChunks = try dbQueue.read { db -> [String] in
            var orphaned: [String] = []
            for chunkPath in videoChunksToCheck {
                let remainingCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE videoChunkPath = ?",
                    arguments: [chunkPath]
                ) ?? 0
                if remainingCount == 0 {
                    orphaned.append(chunkPath)
                }
            }
            return orphaned
        }

        return DeleteResult(imagePaths: imagePaths, orphanedVideoChunks: orphanedChunks)
    }

    /// Delete a specific screenshot
    func deleteScreenshot(id: Int64) throws -> SingleDeleteResult? {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // Get the storage info first
        let storageInfo = try dbQueue.read { db -> (imagePath: String?, videoChunkPath: String?)? in
            try Row.fetchOne(
                db,
                sql: "SELECT imagePath, videoChunkPath FROM screenshots WHERE id = ?",
                arguments: [id]
            ).map { row in
                (imagePath: row["imagePath"] as String?, videoChunkPath: row["videoChunkPath"] as String?)
            }
        }

        guard let info = storageInfo else {
            return nil
        }

        // Check if this is the last frame in the video chunk
        var isLastFrame = false
        if let videoChunkPath = info.videoChunkPath {
            let frameCount = try dbQueue.read { db -> Int in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE videoChunkPath = ?",
                    arguments: [videoChunkPath]
                ) ?? 0
            }
            isLastFrame = frameCount == 1
        }

        // Delete the record
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM screenshots WHERE id = ?",
                arguments: [id]
            )
        }

        return SingleDeleteResult(
            imagePath: info.imagePath,
            videoChunkPath: info.videoChunkPath,
            isLastFrameInChunk: isLastFrame
        )
    }

    /// Get total screenshot count
    func getScreenshotCount() throws -> Int {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots") ?? 0
        }
    }

    /// Get database statistics
    func getStats() throws -> (total: Int, indexed: Int, oldestDate: Date?, newestDate: Date?) {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots") ?? 0
            let indexedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE isIndexed = 1") ?? 0
            let oldestDate = try Date.fetchOne(db, sql: "SELECT MIN(timestamp) FROM screenshots")
            let newestDate = try Date.fetchOne(db, sql: "SELECT MAX(timestamp) FROM screenshots")

            return (totalCount, indexedCount, oldestDate, newestDate)
        }
    }

    /// Delete all screenshots from a corrupted video chunk
    /// Returns the number of deleted records
    func deleteScreenshotsFromVideoChunk(videoChunkPath: String) throws -> Int {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        let deletedCount = try dbQueue.write { db -> Int in
            // Get count before deletion
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM screenshots WHERE videoChunkPath = ?",
                arguments: [videoChunkPath]
            ) ?? 0

            // Delete all records for this chunk
            try db.execute(
                sql: "DELETE FROM screenshots WHERE videoChunkPath = ?",
                arguments: [videoChunkPath]
            )

            return count
        }

        if deletedCount > 0 {
            log("RewindDatabase: Deleted \(deletedCount) screenshots from corrupted chunk: \(videoChunkPath)")
        }

        return deletedCount
    }
}
