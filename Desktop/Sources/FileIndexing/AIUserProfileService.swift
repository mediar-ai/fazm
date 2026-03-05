import Foundation
import GRDB

// MARK: - Database Record

/// Database record for AI-generated user profile history
struct AIUserProfileRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var profileText: String
    var dataSourcesUsed: Int
    var backendSynced: Bool
    var generatedAt: Date

    static let databaseTableName = "ai_user_profiles"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - TableDocumented

extension AIUserProfileRecord: TableDocumented {
    static var tableDescription: String { ChatPrompts.tableAnnotations["ai_user_profiles"]! }
    static var columnDescriptions: [String: String] { ChatPrompts.columnAnnotations["ai_user_profiles"] ?? [:] }
}

// MARK: - Service

/// Service that manages AI-generated user profiles stored in the local database.
/// During onboarding, the parallel exploration session saves its findings as a profile.
/// The profile is then injected into chat prompts for personalization.
actor AIUserProfileService {
    static let shared = AIUserProfileService()

    private let maxProfileLength = 10000

    /// Cached database pool
    private var _dbQueue: DatabasePool?

    /// Invalidate cached DB queue (called on user switch / sign-out)
    func invalidateCache() {
        _dbQueue = nil
    }

    // MARK: - Database Access

    private func ensureDB() async throws -> DatabasePool {
        if let db = _dbQueue { return db }
        try await AppDatabase.shared.initialize()
        guard let db = await AppDatabase.shared.getDatabaseQueue() else {
            throw ProfileError.databaseNotAvailable
        }
        _dbQueue = db
        return db
    }

    // MARK: - Public Interface

    /// Get the latest stored profile
    func getLatestProfile() async -> AIUserProfileRecord? {
        guard let db = try? await ensureDB() else { return nil }
        return try? await db.read { database in
            try AIUserProfileRecord
                .order(Column("generatedAt").desc)
                .fetchOne(database)
        }
    }

    /// Delete a profile by ID and return the next latest profile
    func deleteProfile(id: Int64) async -> AIUserProfileRecord? {
        guard let db = try? await ensureDB() else { return nil }
        _ = try? await db.write { database in
            try database.execute(
                sql: "DELETE FROM ai_user_profiles WHERE id = ?",
                arguments: [id]
            )
        }
        return await getLatestProfile()
    }

    /// Update the profile text of an existing record
    func updateProfileText(id: Int64, newText: String) async -> Bool {
        guard let db = try? await ensureDB() else { return false }
        do {
            try await db.write { database in
                try database.execute(
                    sql: "UPDATE ai_user_profiles SET profileText = ? WHERE id = ?",
                    arguments: [newText, id]
                )
            }
            log("AIUserProfileService: Updated profile text for id \(id)")
            return true
        } catch {
            log("AIUserProfileService: Failed to update profile text: \(error.localizedDescription)")
            return false
        }
    }

    /// Save exploration text as a new profile record (used during onboarding)
    func saveExplorationAsProfile(text: String) async -> Bool {
        guard let db = try? await ensureDB() else {
            log("AIUserProfileService: DB not available for saving exploration profile")
            return false
        }
        let record = AIUserProfileRecord(
            profileText: String(text.prefix(maxProfileLength)),
            dataSourcesUsed: 1,
            backendSynced: false,
            generatedAt: Date()
        )
        do {
            try await db.write { database in
                let mutableRecord = record
                try mutableRecord.insert(database)
            }
            log("AIUserProfileService: Saved exploration as new profile (\(record.profileText.count) chars)")
            return true
        } catch {
            log("AIUserProfileService: Failed to save exploration profile: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete all stored profiles
    func deleteAllProfiles() async {
        guard let db = try? await ensureDB() else { return }
        _ = try? await db.write { database in
            try database.execute(sql: "DELETE FROM ai_user_profiles")
        }
    }

    /// Get all stored profiles (newest first)
    func getAllProfiles(limit: Int = 30) async -> [AIUserProfileRecord] {
        guard let db = try? await ensureDB() else { return [] }
        return (try? await db.read { database in
            try AIUserProfileRecord
                .order(Column("generatedAt").desc)
                .limit(limit)
                .fetchAll(database)
        }) ?? []
    }

    // MARK: - Errors

    enum ProfileError: LocalizedError {
        case databaseNotAvailable

        var errorDescription: String? {
            switch self {
            case .databaseNotAvailable:
                return "Database is not available"
            }
        }
    }
}
