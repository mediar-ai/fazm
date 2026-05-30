import Foundation
import GRDB

/// One scheduled AI task ("routine"). Mirrors the `cron_jobs` row.
struct CronJob: Identifiable, Equatable {
    let id: String
    var name: String
    var prompt: String
    /// One of: `cron:<expr>`, `every:<seconds>`, `at:<iso8601>`.
    var schedule: String
    var timezone: String
    var enabled: Bool
    var model: String?
    var workspace: String?
    /// `"new"` (each run is a fresh ACP session) or `"resume"` (continues the previous).
    var sessionMode: String
    var acpSessionId: String?
    let createdAt: Date
    var updatedAt: Date
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastStatus: String?
    var lastError: String?
    var runCount: Int
}

/// One execution of a routine. Mirrors the `cron_runs` row.
struct CronRun: Identifiable, Equatable {
    let id: Int64
    let jobId: String
    let startedAt: Date
    let finishedAt: Date?
    /// `"ok" | "error" | "timeout" | "running"`
    let status: String
    let outputText: String?
    let errorMessage: String?
    let costUsd: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let durationMs: Int?
    let chatMessageId: String?
}

/// Persistence layer for routines. Reads/writes the `cron_jobs` and `cron_runs`
/// tables via the shared GRDB pool. The headless runner
/// (`~/fazm/acp-bridge/src/cron-runner.mjs`) writes to the same tables from
/// Node — WAL mode keeps that safe.
enum CronJobStore {

    // MARK: - Jobs

    static func listJobs() async -> [CronJob] {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM cron_jobs
                    ORDER BY enabled DESC, COALESCE(next_run_at, 9.0e15) ASC, name ASC
                """)
                return rows.map(parseJob)
            }
        } catch {
            logError("CronJobStore: listJobs failed", error: error)
            return []
        }
    }

    /// Routines that are due to fire now: enabled, with a `next_run_at` at or before
    /// `now`. This is the in-app equivalent of the `SELECT ... WHERE enabled = 1 AND
    /// next_run_at <= now` query in `inbox/skill/check-routines.sh`. A routine whose
    /// time passed while the app was closed still has `next_run_at` in the past, so it
    /// shows up here on the next tick after launch (catch-up-once).
    static func dueJobs(now: Date = Date()) async -> [CronJob] {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM cron_jobs
                    WHERE enabled = 1
                      AND next_run_at IS NOT NULL
                      AND next_run_at <= ?
                    ORDER BY next_run_at ASC
                """, arguments: [now.timeIntervalSince1970])
                return rows.map(parseJob)
            }
        } catch {
            logError("CronJobStore: dueJobs failed", error: error)
            return []
        }
    }

    static func getJob(id: String) async -> CronJob? {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return nil }
        do {
            return try await dbQueue.read { db in
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM cron_jobs WHERE id = ?", arguments: [id]) {
                    return parseJob(row)
                }
                return nil
            }
        } catch {
            logError("CronJobStore: getJob failed", error: error)
            return nil
        }
    }

    @discardableResult
    static func upsertJob(_ job: CronJob) async -> Bool {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return false }
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO cron_jobs
                        (id, name, prompt, schedule, timezone, enabled, model, workspace,
                         session_mode, acp_session_id, created_at, updated_at, next_run_at,
                         last_run_at, last_status, last_error, run_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        prompt = excluded.prompt,
                        schedule = excluded.schedule,
                        timezone = excluded.timezone,
                        enabled = excluded.enabled,
                        model = excluded.model,
                        workspace = excluded.workspace,
                        session_mode = excluded.session_mode,
                        updated_at = excluded.updated_at,
                        next_run_at = excluded.next_run_at
                """, arguments: [
                    job.id, job.name, job.prompt, job.schedule, job.timezone,
                    job.enabled ? 1 : 0, job.model, job.workspace,
                    job.sessionMode, job.acpSessionId,
                    job.createdAt.timeIntervalSince1970, job.updatedAt.timeIntervalSince1970,
                    job.nextRunAt?.timeIntervalSince1970, job.lastRunAt?.timeIntervalSince1970,
                    job.lastStatus, job.lastError, job.runCount
                ])
            }
            return true
        } catch {
            logError("CronJobStore: upsertJob failed", error: error)
            return false
        }
    }

    static func setEnabled(id: String, enabled: Bool) async {
        await update(id: id, sql: "UPDATE cron_jobs SET enabled = ?, updated_at = ? WHERE id = ?",
                     args: [enabled ? 1 : 0, Date().timeIntervalSince1970, id])
    }

    static func deleteJob(id: String) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM cron_runs WHERE job_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM cron_jobs WHERE id = ?", arguments: [id])
            }
        } catch {
            logError("CronJobStore: deleteJob failed", error: error)
        }
    }

    // MARK: - Runs

    static func listRuns(jobId: String? = nil, limit: Int = 50) async -> [CronRun] {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            return try await dbQueue.read { db in
                let sql: String
                let args: StatementArguments
                if let jobId = jobId {
                    sql = """
                        SELECT * FROM cron_runs
                        WHERE job_id = ?
                        ORDER BY started_at DESC LIMIT ?
                    """
                    args = [jobId, limit]
                } else {
                    sql = "SELECT * FROM cron_runs ORDER BY started_at DESC LIMIT ?"
                    args = [limit]
                }
                let rows = try Row.fetchAll(db, sql: sql, arguments: args)
                return rows.map(parseRun)
            }
        } catch {
            logError("CronJobStore: listRuns failed", error: error)
            return []
        }
    }

    /// Counts of routines by status, for the sidebar badge / quick-glance.
    static func summary() async -> (total: Int, enabled: Int, errored: Int) {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return (0, 0, 0) }
        do {
            return try await dbQueue.read { db in
                let total: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cron_jobs") ?? 0
                let enabled: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cron_jobs WHERE enabled = 1") ?? 0
                let errored: Int = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cron_jobs WHERE last_status = 'error'") ?? 0
                return (total, enabled, errored)
            }
        } catch {
            return (0, 0, 0)
        }
    }

    // MARK: - Helpers

    private static func update(id: String, sql: String, args: StatementArguments) async {
        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(sql: sql, arguments: args)
            }
        } catch {
            logError("CronJobStore: update failed", error: error)
        }
    }

    private static func parseJob(_ row: Row) -> CronJob {
        CronJob(
            id: row["id"],
            name: row["name"],
            prompt: row["prompt"],
            schedule: row["schedule"],
            timezone: row["timezone"],
            enabled: (row["enabled"] as Int? ?? 0) != 0,
            model: row["model"],
            workspace: row["workspace"],
            sessionMode: row["session_mode"],
            acpSessionId: row["acp_session_id"],
            createdAt: dateFrom(row["created_at"]),
            updatedAt: dateFrom(row["updated_at"]),
            nextRunAt: optionalDate(row["next_run_at"]),
            lastRunAt: optionalDate(row["last_run_at"]),
            lastStatus: row["last_status"],
            lastError: row["last_error"],
            runCount: row["run_count"] ?? 0
        )
    }

    private static func parseRun(_ row: Row) -> CronRun {
        CronRun(
            id: row["id"],
            jobId: row["job_id"],
            startedAt: dateFrom(row["started_at"]),
            finishedAt: optionalDate(row["finished_at"]),
            status: row["status"],
            outputText: row["output_text"],
            errorMessage: row["error_message"],
            costUsd: row["cost_usd"],
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            durationMs: row["duration_ms"],
            chatMessageId: row["chat_message_id"]
        )
    }

    private static func dateFrom(_ value: Double?) -> Date {
        Date(timeIntervalSince1970: value ?? 0)
    }

    private static func optionalDate(_ value: Double?) -> Date? {
        guard let v = value else { return nil }
        return Date(timeIntervalSince1970: v)
    }
}
