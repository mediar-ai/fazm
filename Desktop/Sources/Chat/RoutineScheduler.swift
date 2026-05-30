import Darwin
import Foundation

/// Fires due user routines while the app is running — the in-app equivalent of the
/// dev-only launchd job (`inbox/skill/check-routines.sh`). Every 60s it finds due rows
/// in the active user's `cron_jobs` and spawns `acp-bridge/dist/cron-runner.mjs` for
/// each, with the SAME node binary + bridge environment interactive chat uses, so the
/// headless routine bridge authenticates identically. cron-runner.mjs writes results
/// back to `cron_runs` / `chat_messages` and recomputes `next_run_at`.
///
/// Why in-app and not a LaunchAgent: routines run through the LOCAL ACP bridge using the
/// user's local Claude/Gemini creds, files, and browser, so they can't run in the cloud;
/// a menu-bar app that's normally always-on covers the common case. A routine whose time
/// passed while the app was quit fires once on the next tick after launch (`next_run_at`
/// stays in the past = catch-up-once), matching how Claude Code's `/loop` behaves.
///
/// Concurrency is guarded two ways: an in-process `inFlight` set (fast path for this
/// process) and the `/tmp/fazm-routine-<id>.pid` file contract shared with
/// check-routines.sh, so the app and the dev launchd job never double-spend the same job.
@MainActor
final class RoutineScheduler {
    static let shared = RoutineScheduler()
    private init() {}

    private var timer: Timer?
    private var ticking = false
    /// Job ids this process has spawned and not yet reaped.
    private var inFlight = Set<String>()

    /// Match check-routines.sh's 60s launchd cadence.
    private let pollInterval: TimeInterval = 60
    /// Cap simultaneous routine bridges — each is a full ACP bridge (~600MB). Extra due
    /// jobs keep their past `next_run_at` and fire on subsequent ticks.
    private let maxConcurrent = 3

    func start() {
        guard timer == nil else { return }
        log("RoutineScheduler: starting (poll every \(Int(pollInterval))s)")
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick(reason: "timer") }
        }
        t.tolerance = 10  // let the OS coalesce wakeups; routines aren't second-sensitive
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Fire one tick shortly after launch so a routine that came due while the app was
        // closed runs promptly instead of waiting a full interval.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await self?.tick(reason: "startup")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick(reason: String) async {
        guard !ticking else { return }  // never overlap ticks
        ticking = true
        defer { ticking = false }

        let due = await CronJobStore.dueJobs()
        guard !due.isEmpty else { return }

        // Resolve the shared launch context once per tick. Any missing piece means we
        // skip this tick and try again in 60s.
        guard let node = ACPBridge.findNodeBinary() else {
            log("RoutineScheduler: node binary not found; deferring \(due.count) due routine(s)")
            return
        }
        guard let bridgeScript = ACPBridge.findBridgeScript() else {
            log("RoutineScheduler: bridge script not found; deferring due routine(s)")
            return
        }
        // cron-runner.mjs is the sibling of the bridge entry (both in acp-bridge/dist/).
        let runner = ((bridgeScript as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("cron-runner.mjs")
        guard FileManager.default.fileExists(atPath: runner) else {
            log("RoutineScheduler: cron-runner.mjs not found at \(runner); deferring")
            return
        }
        let dbPath = AppDatabase.activeDatabasePath()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            // No DB yet (e.g. before sign-in / first launch settles) — nothing to run.
            return
        }

        var env = await ACPBridge.makeBridgeEnvironment(mode: ACPBridge.currentMode(), nodePath: node)
        // Keep routine logs out of users' home dirs: cron-runner honors this and writes
        // routines.log here instead of creating ~/fazm/inbox/skill/logs.
        let logDir = AppPaths.supportRoot.appendingPathComponent("routine-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        env["FAZM_ROUTINE_LOG_DIR"] = logDir.path

        log("RoutineScheduler: \(reason) tick — \(due.count) routine(s) due")
        for job in due {
            if inFlight.count >= maxConcurrent {
                log("RoutineScheduler: \(inFlight.count) routine(s) running; deferring the rest to next tick")
                break
            }
            if inFlight.contains(job.id) { continue }
            if Self.pidFileAlive(jobId: job.id) {
                // Another scheduler (e.g. the dev launchd job on this machine) is already
                // running it — don't double-spend.
                continue
            }
            spawn(job: job, node: node, runner: runner, dbPath: dbPath, env: env)
        }
    }

    // MARK: - Spawn

    private func spawn(job: CronJob, node: String, runner: String, dbPath: String, env: [String: String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: node)
        proc.arguments = [
            "--max-old-space-size=512", runner,
            "--user-db", dbPath,
            "--job-id", job.id,
            "--timeout", "600",
        ]
        // Pin cwd to home, mirroring ACPBridge.start(); cron-runner spawns its bridge from here.
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        proc.environment = env
        // cron-runner writes its own per-run log file; we don't need its stdio.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let pidFile = Self.pidFilePath(jobId: job.id)
        proc.terminationHandler = { [weak self] p in
            try? FileManager.default.removeItem(atPath: pidFile)
            let status = p.terminationStatus
            Task { @MainActor in
                self?.inFlight.remove(job.id)
                log("RoutineScheduler: routine \(job.id.prefix(8)) '\(job.name)' finished (exit \(status))")
            }
        }

        inFlight.insert(job.id)
        do {
            try proc.run()
            // Write the child PID so the next tick and check-routines.sh see it as live.
            try? String(proc.processIdentifier)
                .write(toFile: pidFile, atomically: true, encoding: .utf8)
            log("RoutineScheduler: spawned routine \(job.id.prefix(8)) '\(job.name)' (pid \(proc.processIdentifier))")
        } catch {
            inFlight.remove(job.id)
            try? FileManager.default.removeItem(atPath: pidFile)
            logError("RoutineScheduler: failed to spawn routine \(job.id)", error: error)
        }
    }

    // MARK: - PID-file interlock (shared contract with inbox/skill/check-routines.sh)

    private static func pidFilePath(jobId: String) -> String {
        "/tmp/fazm-routine-\(jobId).pid"
    }

    /// True when a PID file exists and that process is still alive (another scheduler is
    /// running this job). Cleans up a stale file and returns false otherwise.
    private static func pidFileAlive(jobId: String) -> Bool {
        let path = pidFilePath(jobId: jobId)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        if kill(pid, 0) == 0 { return true }  // signal 0 = liveness probe
        try? FileManager.default.removeItem(atPath: path)  // stale
        return false
    }
}
