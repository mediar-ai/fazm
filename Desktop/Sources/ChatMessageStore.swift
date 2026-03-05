import Foundation
import GRDB

/// Generic persistence layer for chat messages stored in the local SQLite database.
/// Uses the `chat_messages` table (renamed from `task_chat_messages` in V3 migration).
enum ChatMessageStore {

    static func saveMessage(_ message: ChatMessage, context: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        let sender = message.sender == .user ? "user" : "ai"
        let now = Date()
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO chat_messages
                        (taskId, messageId, sender, messageText, createdAt, updatedAt, backendSynced)
                        VALUES (?, ?, ?, ?, ?, ?, 0)
                    """,
                    arguments: [context, message.id, sender, message.text, message.createdAt, now]
                )
            }
        } catch {
            log("ChatMessageStore: Failed to save message: \(error)")
        }
    }

    static func updateMessage(id: String, text: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE chat_messages SET messageText = ?, updatedAt = ? WHERE messageId = ?",
                    arguments: [text, Date(), id]
                )
            }
        } catch {
            log("ChatMessageStore: Failed to update message: \(error)")
        }
    }

    static func loadMessages(context: String, limit: Int? = nil) async -> [ChatMessage] {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            return try await dbQueue.read { db in
                let sql: String
                let arguments: StatementArguments
                if let limit = limit {
                    // Fetch the N most recent messages, then return in chronological order
                    sql = """
                        SELECT * FROM (
                            SELECT messageId, sender, messageText, createdAt
                            FROM chat_messages
                            WHERE taskId = ?
                            ORDER BY createdAt DESC
                            LIMIT ?
                        ) ORDER BY createdAt ASC
                    """
                    arguments = [context, limit]
                } else {
                    sql = """
                        SELECT messageId, sender, messageText, createdAt
                        FROM chat_messages
                        WHERE taskId = ?
                        ORDER BY createdAt ASC
                    """
                    arguments = [context]
                }
                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)

                return rows.map { row in
                    ChatMessage(
                        id: row["messageId"],
                        text: row["messageText"],
                        createdAt: row["createdAt"],
                        sender: (row["sender"] as String) == "user" ? .user : .ai,
                        isStreaming: false,
                        isSynced: true
                    )
                }
            }
        } catch {
            log("ChatMessageStore: Failed to load messages: \(error)")
            return []
        }
    }

    static func clearMessages(context: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM chat_messages WHERE taskId = ?",
                    arguments: [context]
                )
            }
        } catch {
            log("ChatMessageStore: Failed to clear messages: \(error)")
        }
    }
}
