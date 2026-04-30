import AppKit
import Foundation
import PostHog
import Sentry
import MachO

/// Monitors system resources (memory, CPU, disk) and reports to Sentry
@MainActor
class ResourceMonitor {
    static let shared = ResourceMonitor()

    /// Check if this is a development build (avoids Sentry calls in dev)
    private let isDevBuild: Bool = Bundle.main.bundleIdentifier?.hasSuffix("-dev") == true

    // MARK: - Configuration

    /// How often to sample resources (seconds)
    private let sampleInterval: TimeInterval = 30

    /// Memory threshold (MB) - warn when exceeded
    private let memoryWarningThreshold: UInt64 = 500

    /// Memory threshold (MB) - critical alert
    private let memoryCriticalThreshold: UInt64 = 800

    /// Memory growth rate threshold (MB/min) - detect leaks
    private let memoryGrowthRateThreshold: Double = 50

    /// Extreme memory threshold - auto-restart to prevent system from becoming unusable.
    /// Keep this well below the point where free RAM is exhausted — at 4GB the system
    /// has ~120MB free and the new instance fails to launch, leaving the user stuck.
    /// At 3GB there is still ~10-13GB free on typical 16GB machines.
    private let memoryAutoRestartThreshold: UInt64 = 3000 // 3GB

    // MARK: - State

    private var monitorTimer: Timer?
    private var isMonitoring = false
    private var memorySamples: [(timestamp: Date, memoryMB: UInt64)] = []
    private let maxSamples = 20 // Keep last 20 samples for trend analysis
    private var lastWarningTime: Date?
    private var lastCriticalTime: Date?
    private var peakMemoryObserved: UInt64 = 0 // Track peak memory manually
    private var autoRestartTriggered = false // Only auto-restart once per session

    // Minimum time between warnings (prevent spam)
    private let warningCooldown: TimeInterval = 300 // 5 minutes

    private init() {}

    // MARK: - Public API

    /// Start monitoring resources
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        log("ResourceMonitor: Starting resource monitoring (interval: \(Int(sampleInterval))s)")

        // Take initial sample
        Task {
            await sampleResources()
        }

        // Start periodic sampling
        monitorTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.sampleResources()
            }
        }

        // One-shot system-health checks at startup. Each writes a 'heal' card to
        // observer_activity if a fresh signal is found (deduped via UserDefaults).
        Task.detached(priority: .background) { [weak self] in
            await self?.checkKernelPanicReports()
        }
    }

    /// Stop monitoring resources
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
        memorySamples.removeAll()
        log("ResourceMonitor: Stopped resource monitoring")
    }

    /// Get current resource snapshot
    func getCurrentResources() -> ResourceSnapshot {
        return getCurrentResourcesSync()
    }

    /// Thread-safe resource collection (all mach kernel calls are safe to call from any thread)
    nonisolated func getCurrentResourcesSync() -> ResourceSnapshot {
        return ResourceSnapshot(
            memoryUsageMB: getMemoryUsageMB(),
            memoryFootprintMB: getMemoryFootprintMB(),
            peakMemoryMB: getMemoryFootprintMB(), // Use footprint directly (peak tracking requires MainActor state)
            memoryPercent: getMemoryPercentage(),
            totalSystemRAM_MB: getTotalSystemRAM(),
            systemMemoryPressure: getSystemMemoryPressure(),
            cpuUsage: getCPUUsage(),
            diskUsedGB: getDiskUsedGB(),
            diskFreeGB: getDiskFreeGB(),
            threadCount: getThreadCount(),
            timestamp: Date()
        )
    }

    /// Manually report current resources to Sentry (call before known heavy operations)
    func reportResourcesNow(context: String) {
        let snapshot = getCurrentResources()

        // Add as breadcrumb (skip in dev builds)
        if !isDevBuild {
            let breadcrumb = Breadcrumb(level: .info, category: "resources")
            breadcrumb.message = "[\(context)] Memory: \(snapshot.memoryUsageMB)MB, Footprint: \(snapshot.memoryFootprintMB)MB, CPU: \(String(format: "%.1f", snapshot.cpuUsage))%"
            breadcrumb.data = snapshot.asDictionary()
            SentrySDK.addBreadcrumb(breadcrumb)
        }

        log("ResourceMonitor: [\(context)] \(snapshot.summary)")
    }

    // MARK: - Private Methods

    private func sampleResources() async {
        // Collect resource snapshot off the main thread to avoid blocking UI
        // (mach kernel calls are thread-safe but can stall under memory pressure)
        let snapshot = await Task.detached(priority: .utility) { [self] in
            return self.getCurrentResourcesSync()
        }.value

        // Store memory sample for trend analysis
        memorySamples.append((timestamp: snapshot.timestamp, memoryMB: snapshot.memoryFootprintMB))
        if memorySamples.count > maxSamples {
            memorySamples.removeFirst()
        }

        // Update Sentry context with current resources
        updateSentryContext(snapshot)

        // Check for issues
        checkMemoryThresholds(snapshot)
        checkMemoryGrowthRate()

        // Log periodically (every 5th sample = ~2.5 min)
        if memorySamples.count % 5 == 0 {
            log("ResourceMonitor: \(snapshot.summary)")
        }

        // Log per-component memory diagnostics every 10th sample (~5 min)
        if memorySamples.count % 10 == 0 {
            await logComponentDiagnostics(snapshot: snapshot)
        }
    }

    /// Collect and log per-component memory diagnostics to help identify leak sources
    private func logComponentDiagnostics(snapshot: ResourceSnapshot) async {
        var components: [String: Any] = [:]

        // LiveNotesMonitor buffers (MainActor — direct access)
        let liveNotes = LiveNotesMonitor.shared
        components["liveNotes_wordBuffer"] = liveNotes.wordBufferCount
        components["liveNotes_notesContext"] = liveNotes.existingNotesContextCount
        components["liveNotes_notesCount"] = liveNotes.notes.count

        // FocusAssistant pending tasks (actor — await, optional since it may not be initialized)
        if let focusAssistant = ProactiveAssistantsPlugin.shared.currentFocusAssistant {
            components["focus_pendingTasks"] = await focusAssistant.pendingTasksCount
            components["focus_historyCount"] = await focusAssistant.analysisHistoryCount
        }

        // Thread count is already in snapshot
        components["threadCount"] = snapshot.threadCount

        let componentSummary = components.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        log("ResourceMonitor: COMPONENTS: \(componentSummary)")

        // Add to Sentry context for crash diagnostics
        if !isDevBuild {
            SentrySDK.configureScope { scope in
                scope.setContext(value: components, key: "memory_components")
            }

            // Add breadcrumb when memory is elevated
            if snapshot.memoryFootprintMB >= memoryWarningThreshold {
                let breadcrumb = Breadcrumb(level: .warning, category: "memory_diagnostics")
                breadcrumb.message = "Component diagnostics at \(snapshot.memoryFootprintMB)MB"
                breadcrumb.data = components
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        }
    }

    private func updateSentryContext(_ snapshot: ResourceSnapshot) {
        // Set resource context that will be attached to all future events (skip in dev builds)
        guard !isDevBuild else { return }
        SentrySDK.configureScope { scope in
            scope.setContext(value: snapshot.asDictionary(), key: "resources")
        }
    }

    private func checkMemoryThresholds(_ snapshot: ResourceSnapshot) {
        let now = Date()

        // Extreme threshold - auto-restart to prevent the system from becoming unresponsive.
        // Without this, memory can climb to 7GB+, causing SQLite I/O failures and making
        // the app impossible to reopen without a full computer restart.
        if snapshot.memoryFootprintMB >= memoryAutoRestartThreshold && !autoRestartTriggered && !isDevBuild {
            autoRestartTriggered = true
            log("ResourceMonitor: EXTREME memory \(snapshot.memoryFootprintMB)MB — auto-restarting to prevent system degradation")

            // Capture enhanced diagnostics before auto-restart
            collectEnhancedDiagnostics(snapshot: snapshot)

            SentrySDK.capture(message: "App Auto-Restarting Due to Extreme Memory") { scope in
                scope.setLevel(.fatal)
                scope.setTag(value: "auto_restart", key: "resource_alert")
                scope.setContext(value: snapshot.asDictionary(), key: "resources")
            }

            // Give Sentry 3 seconds to flush, then relaunch and terminate.
            // Only terminate if the relaunch succeeds — otherwise the user would be
            // left with no running app and would need a full computer restart.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-n", Bundle.main.bundleURL.path]
                do {
                    try task.run()
                    NSApp.terminate(nil)
                } catch {
                    logError("ResourceMonitor: Failed to relaunch app during auto-restart, aborting terminate to avoid leaving user stuck", error: error)
                    self.autoRestartTriggered = false  // Allow retry on next threshold check
                }
            }
            return
        }

        // Critical threshold
        if snapshot.memoryFootprintMB >= memoryCriticalThreshold {
            if lastCriticalTime == nil || now.timeIntervalSince(lastCriticalTime!) > warningCooldown {
                lastCriticalTime = now

                log("ResourceMonitor: CRITICAL - Memory usage \(snapshot.memoryFootprintMB)MB exceeds \(memoryCriticalThreshold)MB threshold")

                // Collect component diagnostics immediately at critical threshold
                Task {
                    await logComponentDiagnostics(snapshot: snapshot)
                }

                // Collect enhanced diagnostics (per-thread CPU, malloc zones, VM regions)
                collectEnhancedDiagnostics(snapshot: snapshot)

                // Attempt to free memory by flushing heavy components
                triggerMemoryRemediation()

                // Send Sentry event (skip in dev builds)
                if !isDevBuild {
                    let threshold = self.memoryCriticalThreshold
                    SentrySDK.capture(message: "Critical Memory Usage") { scope in
                        scope.setLevel(.error)
                        scope.setTag(value: "memory_critical", key: "resource_alert")
                        scope.setContext(value: snapshot.asDictionary(), key: "resources")
                        scope.setContext(value: [
                            "threshold_mb": threshold,
                            "current_mb": snapshot.memoryFootprintMB,
                            "peak_mb": snapshot.peakMemoryMB
                        ], key: "memory_details")
                    }
                }
            }
        }
        // Warning threshold
        else if snapshot.memoryFootprintMB >= memoryWarningThreshold {
            if lastWarningTime == nil || now.timeIntervalSince(lastWarningTime!) > warningCooldown {
                lastWarningTime = now

                log("ResourceMonitor: WARNING - Memory usage \(snapshot.memoryFootprintMB)MB exceeds \(memoryWarningThreshold)MB threshold")

                // Add warning breadcrumb (skip in dev builds)
                if !isDevBuild {
                    let breadcrumb = Breadcrumb(level: .warning, category: "resources")
                    breadcrumb.message = "High memory usage: \(snapshot.memoryFootprintMB)MB"
                    breadcrumb.data = snapshot.asDictionary()
                    SentrySDK.addBreadcrumb(breadcrumb)
                }
            }
        }
    }

    private func checkMemoryGrowthRate() {
        guard memorySamples.count >= 5 else { return }

        // Calculate growth rate over last 5 samples
        let recentSamples = Array(memorySamples.suffix(5))
        guard let first = recentSamples.first, let last = recentSamples.last else { return }

        let timeDiffMinutes = last.timestamp.timeIntervalSince(first.timestamp) / 60.0
        guard timeDiffMinutes > 0 else { return }

        let memoryGrowthMB = Double(Int64(last.memoryMB) - Int64(first.memoryMB))
        let growthRateMBPerMin = memoryGrowthMB / timeDiffMinutes

        // Detect potential memory leak
        if growthRateMBPerMin > memoryGrowthRateThreshold {
            log("ResourceMonitor: WARNING - Memory growing at \(String(format: "%.1f", growthRateMBPerMin))MB/min (potential leak)")

            // Add breadcrumb (skip in dev builds)
            if !isDevBuild {
                let breadcrumb = Breadcrumb(level: .warning, category: "resources")
                breadcrumb.message = "Potential memory leak detected: \(String(format: "%.1f", growthRateMBPerMin))MB/min growth rate"
                breadcrumb.data = [
                    "growth_rate_mb_per_min": growthRateMBPerMin,
                    "samples_analyzed": recentSamples.count,
                    "time_span_minutes": timeDiffMinutes,
                    "start_memory_mb": first.memoryMB,
                    "end_memory_mb": last.memoryMB
                ]
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        }
    }

    // MARK: - Memory Remediation

    /// Attempt to free memory by flushing heavy components.
    /// Called at most once per warningCooldown (5 min) when critical threshold is exceeded.
    /// Closure called during memory remediation to trim transcript state.
    /// Set by AppState on init to avoid tight coupling.
    var onMemoryPressureTrimTranscript: (() -> Void)?

    private func triggerMemoryRemediation() {
        log("ResourceMonitor: Triggering memory remediation — clearing assistant pending work, trimming transcript, pausing AgentSync")

        let memoryBefore = getMemoryFootprintMB()

        // Clear queued frames in assistant coordinator
        AssistantCoordinator.shared.clearAllPendingWork()

        // Trim in-memory transcript segments (already persisted in SQLite)
        onMemoryPressureTrimTranscript?()

        Task {
            // Clear focus assistant pending tasks specifically
            if let focusAssistant = ProactiveAssistantsPlugin.shared.currentFocusAssistant {
                await focusAssistant.clearPendingWork()
            }

            // Pause AgentSync to reduce memory pressure and resume after 60s
            await AgentSyncService.shared.pause()
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                await AgentSyncService.shared.resume()
                log("ResourceMonitor: AgentSync resumed after 60s cooldown")
            }

            let memoryAfter = await MainActor.run { self.getMemoryFootprintMB() }
            log("ResourceMonitor: Memory remediation completed — \(memoryBefore)MB -> \(memoryAfter)MB")
        }

        if !isDevBuild {
            let breadcrumb = Breadcrumb(level: .warning, category: "memory_remediation")
            breadcrumb.message = "Memory remediation triggered at critical threshold"
            breadcrumb.data = [
                "memory_footprint_mb": memoryBefore,
                "threshold_mb": memoryCriticalThreshold
            ]
            SentrySDK.addBreadcrumb(breadcrumb)
        }
    }

    // MARK: - Enhanced Diagnostics (only at critical threshold)

    /// Collect per-thread CPU usage to identify which thread is burning CPU.
    /// Only called at critical threshold to avoid overhead.
    private nonisolated func collectPerThreadCPUDiagnostics() -> [String: Any] {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return ["error": "failed to get threads"]
        }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }

        var hotThreads: [(name: String, cpu: Double, userTime: Double, systemTime: Double)] = []

        for i in 0..<Int(threadCount) {
            // Get CPU usage
            var basicInfo = thread_basic_info()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let basicResult = withUnsafeMutablePointer(to: &basicInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }

            guard basicResult == KERN_SUCCESS && (basicInfo.flags & TH_FLAGS_IDLE) == 0 else { continue }

            let cpuPercent = Double(basicInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            let userTimeSec = Double(basicInfo.user_time.seconds) + Double(basicInfo.user_time.microseconds) / 1_000_000.0
            let systemTimeSec = Double(basicInfo.system_time.seconds) + Double(basicInfo.system_time.microseconds) / 1_000_000.0

            // Get thread name via extended info
            var extInfo = thread_extended_info()
            var extCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
            var threadName = "thread-\(i)"
            let extResult = withUnsafeMutablePointer(to: &extInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extCount)
                }
            }
            if extResult == KERN_SUCCESS {
                let name = withUnsafePointer(to: extInfo.pth_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 64) {
                        String(cString: $0)
                    }
                }
                if !name.isEmpty {
                    threadName = name
                }
            }

            if cpuPercent > 1.0 { // Only track threads using >1% CPU
                hotThreads.append((name: threadName, cpu: cpuPercent, userTime: userTimeSec, systemTime: systemTimeSec))
            }
        }

        // Sort by CPU usage descending
        hotThreads.sort { $0.cpu > $1.cpu }

        var result: [String: Any] = ["total_threads": Int(threadCount)]
        var threadDetails: [[String: Any]] = []
        for (idx, t) in hotThreads.prefix(5).enumerated() {
            threadDetails.append([
                "rank": idx + 1,
                "name": t.name,
                "cpu_percent": String(format: "%.1f", t.cpu),
                "user_time_sec": String(format: "%.1f", t.userTime),
                "system_time_sec": String(format: "%.1f", t.systemTime)
            ])
            log("ResourceMonitor: HOT THREAD #\(idx + 1): \(t.name) — CPU: \(String(format: "%.1f", t.cpu))%, user: \(String(format: "%.1f", t.userTime))s, sys: \(String(format: "%.1f", t.systemTime))s")
        }
        result["hot_threads"] = threadDetails
        return result
    }

    /// Collect malloc zone statistics to see heap vs VM allocations.
    private nonisolated func collectMallocZoneDiagnostics() -> [String: Any] {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats) // nil = default zone aggregate

        let result: [String: Any] = [
            "malloc_size_in_use_mb": stats.size_in_use / (1024 * 1024),
            "malloc_size_allocated_mb": stats.size_allocated / (1024 * 1024),
            "malloc_blocks_in_use": stats.blocks_in_use,
            "malloc_max_size_in_use_mb": stats.max_size_in_use / (1024 * 1024)
        ]

        log("ResourceMonitor: MALLOC ZONES: in_use=\(stats.size_in_use / (1024 * 1024))MB, allocated=\(stats.size_allocated / (1024 * 1024))MB, blocks=\(stats.blocks_in_use), max=\(stats.max_size_in_use / (1024 * 1024))MB")
        return result
    }

    /// Collect VM region breakdown from task_vm_info.
    private nonisolated func collectVMRegionDiagnostics() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return ["error": "task_vm_info failed"]
        }

        let toMB: (UInt64) -> UInt64 = { $0 / (1024 * 1024) }
        let toMBSigned: (Int64) -> Int64 = { $0 / (1024 * 1024) }

        let diagnostics: [String: Any] = [
            "phys_footprint_mb": toMB(UInt64(info.phys_footprint)),
            "internal_mb": toMBSigned(Int64(info.internal)),
            "external_mb": toMBSigned(Int64(info.external)),
            "compressed_mb": toMB(UInt64(info.compressed)),
            "purgeable_volatile_mb": toMB(UInt64(info.purgeable_volatile_pmap)),
            "virtual_size_mb": toMB(UInt64(info.virtual_size)),
            "resident_size_mb": toMB(UInt64(info.resident_size)),
            "reusable_mb": toMBSigned(Int64(info.reusable)),
        ]

        log("ResourceMonitor: VM REGIONS: phys=\(toMB(UInt64(info.phys_footprint)))MB, internal=\(toMBSigned(Int64(info.internal)))MB, external=\(toMBSigned(Int64(info.external)))MB, compressed=\(toMB(UInt64(info.compressed)))MB, virtual=\(toMB(UInt64(info.virtual_size)))MB, resident=\(toMB(UInt64(info.resident_size)))MB, reusable=\(toMBSigned(Int64(info.reusable)))MB")
        return diagnostics
    }

    /// Collect all enhanced diagnostics and send to Sentry.
    /// Only called at critical memory threshold to avoid overhead.
    /// Runs heavy mach introspection off the main thread.
    private func collectEnhancedDiagnostics(snapshot: ResourceSnapshot) {
        let isDevBuild = self.isDevBuild
        Task.detached(priority: .utility) { [self] in
            log("ResourceMonitor: === ENHANCED DIAGNOSTICS START (memory: \(snapshot.memoryFootprintMB)MB) ===")

            let threadDiag = self.collectPerThreadCPUDiagnostics()
            let mallocDiag = self.collectMallocZoneDiagnostics()
            let vmDiag = self.collectVMRegionDiagnostics()

            log("ResourceMonitor: === ENHANCED DIAGNOSTICS END ===")

            // Send to Sentry as breadcrumbs and context
            if !isDevBuild {
                SentrySDK.configureScope { scope in
                    scope.setContext(value: threadDiag, key: "hot_threads")
                    scope.setContext(value: mallocDiag, key: "malloc_zones")
                    scope.setContext(value: vmDiag, key: "vm_regions")
                }

                let breadcrumb = Breadcrumb(level: .error, category: "enhanced_diagnostics")
                breadcrumb.message = "Enhanced diagnostics at \(snapshot.memoryFootprintMB)MB"
                breadcrumb.data = [
                    "hot_threads": threadDiag,
                    "malloc_zones": mallocDiag,
                    "vm_regions": vmDiag
                ]
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        }
    }

    // MARK: - Resource Getters (macOS specific, all thread-safe)

    /// Get current memory usage in MB (resident set size)
    private nonisolated func getMemoryUsageMB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return info.resident_size / (1024 * 1024)
        }
        return 0
    }

    /// Get physical memory footprint in MB (more accurate for macOS)
    private nonisolated func getMemoryFootprintMB() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        if result == KERN_SUCCESS {
            return UInt64(info.phys_footprint) / (1024 * 1024)
        }
        return getMemoryUsageMB() // Fallback
    }

    /// Get peak memory usage in MB (tracked manually since phys_footprint_peak unavailable)
    private func getPeakMemoryMB() -> UInt64 {
        let current = getMemoryFootprintMB()
        if current > peakMemoryObserved {
            peakMemoryObserved = current
        }
        return peakMemoryObserved
    }

    /// Get CPU usage percentage (0-100+, can exceed 100% on multi-core)
    private nonisolated func getCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return 0
        }

        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }

        var totalCPU: Double = 0

        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)

            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }

            if result == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                totalCPU += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }

        return totalCPU
    }

    /// Get disk space used in GB
    private nonisolated func getDiskUsedGB() -> Double {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeDir.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            let total = values.volumeTotalCapacity ?? 0
            let available = values.volumeAvailableCapacity ?? 0
            return Double(total - available) / (1024 * 1024 * 1024)
        } catch {
            return 0
        }
    }

    /// Get disk space free in GB
    private nonisolated func getDiskFreeGB() -> Double {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        do {
            let values = try homeDir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return Double(values.volumeAvailableCapacity ?? 0) / (1024 * 1024 * 1024)
        } catch {
            return 0
        }
    }

    /// Get current thread count
    private nonisolated func getThreadCount() -> Int {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0

        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return 0
        }

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))

        return Int(threadCount)
    }

    /// Get total system RAM in MB
    private nonisolated func getTotalSystemRAM() -> UInt64 {
        return UInt64(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
    }

    /// Get app's memory usage as percentage of total system RAM
    private nonisolated func getMemoryPercentage() -> Double {
        let totalRAM = getTotalSystemRAM()
        guard totalRAM > 0 else { return 0 }
        let footprint = getMemoryFootprintMB()
        return (Double(footprint) / Double(totalRAM)) * 100.0
    }

    // MARK: - System Health Signals (Mac Doctor)

    /// Scan /Library/Logs/DiagnosticReports for recent kernel panics.
    /// Writes a 'heal' row to observer_activity for the most recent panic in the last 7 days,
    /// deduped via UserDefaults so we never flag the same panic twice.
    nonisolated func checkKernelPanicReports() async {
        let panicDir = "/Library/Logs/DiagnosticReports"
        let url = URL(fileURLWithPath: panicDir, isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        let panics: [(URL, Date)] = entries.compactMap { entry in
            guard entry.pathExtension == "panic" else { return nil }
            guard let attrs = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = attrs.contentModificationDate else { return nil }
            guard mtime >= sevenDaysAgo else { return nil }
            return (entry, mtime)
        }.sorted { $0.1 > $1.1 }

        guard let mostRecent = panics.first else { return }

        let lastFlaggedKey = "lastFlaggedKernelPanicMtime"
        let lastFlagged = UserDefaults.standard.double(forKey: lastFlaggedKey)
        let mostRecentTimestamp = mostRecent.1.timeIntervalSince1970

        guard mostRecentTimestamp > lastFlagged else { return }

        UserDefaults.standard.set(mostRecentTimestamp, forKey: lastFlaggedKey)
        log("ResourceMonitor: kernel panic detected at \(mostRecent.0.lastPathComponent), surfacing heal card")

        await persistKernelPanicHealCard(panicURL: mostRecent.0, mtime: mostRecent.1, totalCount: panics.count)
    }

    /// Insert a heal-category row into observer_activity for a kernel panic, and surface the
    /// floating overlay if the bar is visible. Schema mirrors what GeminiAnalysisService writes.
    nonisolated private func persistKernelPanicHealCard(panicURL: URL, mtime: Date, totalCount: Int) async {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let when = formatter.string(from: mtime)
        let ago = humanTimeAgo(mtime)

        let task = "Your Mac kernel-panicked \(ago), Fazm can read the panic report and explain the likely cause"
        let description = "macOS wrote a kernel panic report at \(when) (\(panicURL.lastPathComponent)). \(totalCount > 1 ? "There are \(totalCount) panic reports from the last 7 days. " : "")Panic reports name the panicked process and stack; Fazm can identify the likely subsystem (third-party kext, GPU driver, runaway process, namei zone exhaustion, etc.) and recommend safe next steps. All diagnostics are read-only by default."
        let document = """
        ## What Was Observed

        macOS kernel panic report:
        - Path: `\(panicURL.path)`
        - When: \(when)
        - Total panic reports in last 7 days: \(totalCount)

        ## The Task

        Read the panic report and explain in plain English what likely caused the kernel panic. Identify whether it is hardware, a third-party kext, a runaway process, or a known macOS bug. Recommend specific next steps the user can take.

        ## Why AI Can Help

        Panic reports are dense and full of stack-trace jargon most users cannot parse. The AI can read the file, identify the panicked subsystem, cross-reference it against known issues, and translate the verdict into something actionable.

        ## Recommended Approach

        1. Read `\(panicURL.path)` (world-readable, no sudo needed) to get the full report.
        2. Identify the panicked thread, the kext (if any), and the process backtrace.
        3. Check for known patterns: `vfs.namei` zone exhaustion, third-party kexts (anything not `com.apple.*` in the loaded kexts list), GPU driver crashes, thermal shutdowns.
        4. Explain the likely cause and the user's options (uninstall a kext, restart a leaky daemon, file a sysdiagnose to Apple, etc.).
        5. Read-only first. Never run `sudo`, `kextunload`, or anything destructive without explicit user approval.
        """

        let contentJson: [String: Any] = [
            "task": task,
            "category": "heal",
            "description": description,
            "document": document,
            "panic_path": panicURL.path,
            "panic_mtime": ISO8601DateFormatter().string(from: mtime),
            "panic_count_7d": totalCount,
        ]

        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            let contentString = String(data: try JSONSerialization.data(withJSONObject: contentJson), encoding: .utf8) ?? task
            let activityId = try await dbQueue.write { db -> Int64 in
                try db.execute(
                    sql: """
                        INSERT INTO observer_activity (type, category, content, status, createdAt)
                        VALUES (?, ?, ?, 'pending', datetime('now'))
                    """,
                    arguments: ["system_signal", "heal", contentString]
                )
                return db.lastInsertedRowID
            }
            log("ResourceMonitor: persisted kernel panic heal card id=\(activityId)")

            // Track creation so we can measure heal-card discovery rate and the funnel
            // from created → shown → investigated/dismissed/ignored.
            await MainActor.run {
                PostHogSDK.shared.capture("discovered_task_created", properties: [
                    "task_id": activityId,
                    "task_category": "heal",
                    "task_title": String(task.prefix(100)),
                    "source": "kernel_panic",
                    "type": "system_signal",
                    "panic_count_7d": totalCount,
                ])
            }

            let savedId = activityId
            let savedTask = task
            let savedDesc = description
            let savedDoc = document
            await MainActor.run {
                if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
                    AnalysisOverlayWindow.shared.show(below: barFrame, task: savedTask, category: "heal", description: savedDesc, document: savedDoc, activityId: savedId)
                }
            }
        } catch {
            log("ResourceMonitor: failed to persist kernel panic heal card: \(error)")
        }
    }

    private nonisolated func humanTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 { return "less than an hour ago" }
        if interval < 86400 {
            let h = Int(interval / 3600)
            return h == 1 ? "an hour ago" : "\(h) hours ago"
        }
        let d = Int(interval / 86400)
        return d == 1 ? "yesterday" : "\(d) days ago"
    }

    /// Get system-wide memory pressure (percentage of total RAM in use by all apps)
    private nonisolated func getSystemMemoryPressure() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = UInt64(vm_kernel_page_size)
        let totalRAM = ProcessInfo.processInfo.physicalMemory

        // Active + Wired + Compressed = memory in use
        let activeBytes = UInt64(stats.active_count) * pageSize
        let wiredBytes = UInt64(stats.wire_count) * pageSize
        let compressedBytes = UInt64(stats.compressor_page_count) * pageSize
        let usedBytes = activeBytes + wiredBytes + compressedBytes

        return (Double(usedBytes) / Double(totalRAM)) * 100.0
    }
}

// MARK: - Resource Snapshot

struct ResourceSnapshot {
    let memoryUsageMB: UInt64      // Resident set size
    let memoryFootprintMB: UInt64  // Physical footprint (more accurate)
    let peakMemoryMB: UInt64       // Peak memory since launch
    let memoryPercent: Double      // App memory as % of total RAM
    let totalSystemRAM_MB: UInt64  // Total system RAM
    let systemMemoryPressure: Double // System-wide RAM usage %
    let cpuUsage: Double           // CPU percentage
    let diskUsedGB: Double         // Disk used
    let diskFreeGB: Double         // Disk free
    let threadCount: Int           // Number of threads
    let timestamp: Date

    var summary: String {
        "Memory: \(memoryFootprintMB)MB/\(totalSystemRAM_MB / 1024)GB (\(String(format: "%.2f", memoryPercent))%), System RAM: \(String(format: "%.1f", systemMemoryPressure))% used, CPU: \(String(format: "%.1f", cpuUsage))%, Threads: \(threadCount)"
    }

    func asDictionary() -> [String: Any] {
        return [
            "memory_usage_mb": memoryUsageMB,
            "memory_footprint_mb": memoryFootprintMB,
            "peak_memory_mb": peakMemoryMB,
            "memory_percent": memoryPercent,
            "total_system_ram_mb": totalSystemRAM_MB,
            "system_memory_pressure_percent": systemMemoryPressure,
            "cpu_usage_percent": cpuUsage,
            "disk_used_gb": diskUsedGB,
            "disk_free_gb": diskFreeGB,
            "thread_count": threadCount,
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
    }
}
