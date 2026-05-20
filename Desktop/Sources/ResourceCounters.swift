import Foundation

/// Thread-safe registry for per-subsystem resource counters.
///
/// Subsystems publish queue depths, buffer sizes, or in-flight counts so
/// ResourceMonitor can include them in COMPONENTS diagnostic logs without
/// each subsystem having to wire its own periodic logging.
///
/// Why this exists: when an incident hits (memory leak, hot thread, runaway
/// CPU) the COMPONENTS line is often the only forensic signal we have. A
/// snapshot of every subsystem's queue depth at the moment of the incident
/// is far higher-signal than guessing which subsystem owns the leak.
///
/// Usage from any thread, no `await` required:
///   ResourceCounters.shared.set("sessionRecording_active", 1)
///   ResourceCounters.shared.set("geminiAnalysis_bufferedChunks", count)
///   ResourceCounters.shared.increment("acpBridge_messagesProcessed")
///
/// Read by ResourceMonitor.logComponentDiagnostics — never blocks writers.
public final class ResourceCounters: @unchecked Sendable {
    public static let shared = ResourceCounters()

    private let lock = NSLock()
    private var counters: [String: Int64] = [:]

    private init() {}

    public func set(_ key: String, _ value: Int) {
        lock.lock(); defer { lock.unlock() }
        counters[key] = Int64(value)
    }

    public func set(_ key: String, _ value: Int64) {
        lock.lock(); defer { lock.unlock() }
        counters[key] = value
    }

    public func set(_ key: String, _ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        counters[key] = value ? 1 : 0
    }

    public func increment(_ key: String, by delta: Int64 = 1) {
        lock.lock(); defer { lock.unlock() }
        counters[key, default: 0] += delta
    }

    public func clear(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counters[key] = nil
    }

    public func snapshot() -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        return counters
    }
}
