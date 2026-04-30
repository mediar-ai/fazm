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
    private var systemHealthTimer: Timer?
    private var isMonitoring = false
    private var memorySamples: [(timestamp: Date, memoryMB: UInt64)] = []
    private let maxSamples = 20 // Keep last 20 samples for trend analysis
    private var lastWarningTime: Date?
    private var lastCriticalTime: Date?
    private var peakMemoryObserved: UInt64 = 0 // Track peak memory manually
    private var autoRestartTriggered = false // Only auto-restart once per session

    // Minimum time between warnings (prevent spam)
    private let warningCooldown: TimeInterval = 300 // 5 minutes

    // How often to run system-health pollers (kernel panic, fseventsd RSS, iCloud, disk)
    private let systemHealthInterval: TimeInterval = 3600 // 1 hour

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

        // System-health pollers. Each writes a 'heal' card to observer_activity when a
        // fresh signal is found, deduped via UserDefaults so we never re-flag the same
        // condition. First run is delayed 60s to avoid competing with launch IO.
        Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await self?.runSystemHealthChecks()
        }
        systemHealthTimer = Timer.scheduledTimer(withTimeInterval: systemHealthInterval, repeats: true) { [weak self] _ in
            Task.detached(priority: .background) { [weak self] in
                await self?.runSystemHealthChecks()
            }
        }
    }

    /// Stop monitoring resources
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
        systemHealthTimer?.invalidate()
        systemHealthTimer = nil
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

    // MARK: - System-Health Pollers

    /// Orchestrator for periodic system-health pollers. Each poller has its own dedup
    /// cooldown via UserDefaults, so calling this hourly is safe — only fresh conditions
    /// surface heal cards. Runs on a background priority detached task; never touches
    /// MainActor state directly.
    nonisolated func runSystemHealthChecks() async {
        await checkKernelPanicReports()
        await checkFseventsdMemory()
        await checkICloudRootContamination()
        await checkICloudPendingScans()
        await checkDiskPressure()
    }

    /// Run a short-lived shell command synchronously and return stdout, or nil on failure.
    /// Caps execution at `timeout` seconds so a wedged binary cannot stall the poller.
    nonisolated private func runShellCommand(_ executablePath: String, args: [String], timeout: TimeInterval = 5.0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Payload for a heal-category observer activity row. Used by every system-health
    /// poller so heal cards have consistent shape (and consistent PostHog props).
    private struct HealCardPayload {
        let source: String                  // "kernel_panic" | "fseventsd_memory" | "icloud_root_contamination" | etc.
        let task: String                    // user-facing one-liner shown on the card
        let description: String             // 1-2 sentence explanation under the task
        let document: String                // full diagnostic markdown handed to the AI on Investigate
        let metadata: [String: Any]         // extra props (counts, paths, sizes) merged into both DB content and PostHog
    }

    /// Insert a heal-category row into observer_activity, fire `discovered_task_created`
    /// on PostHog, and surface the floating overlay if the bar is visible. Shared by
    /// every system-health poller so they all behave the same way as the original
    /// kernel-panic detector.
    nonisolated private func writeHealCard(_ payload: HealCardPayload) async {
        var contentJson: [String: Any] = [
            "task": payload.task,
            "category": "heal",
            "description": payload.description,
            "document": payload.document,
            "source": payload.source,
        ]
        for (k, v) in payload.metadata {
            contentJson[k] = v
        }

        guard let dbQueue = await AppDatabase.shared.getDatabaseQueue() else { return }
        do {
            let contentString = String(data: try JSONSerialization.data(withJSONObject: contentJson), encoding: .utf8) ?? payload.task
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
            log("ResourceMonitor: persisted heal card source=\(payload.source) id=\(activityId)")

            let savedId = activityId
            let savedTask = payload.task
            let savedDesc = payload.description
            let savedDoc = payload.document
            let source = payload.source
            let extraProps = payload.metadata

            await MainActor.run {
                var props: [String: Any] = [
                    "task_id": savedId,
                    "task_category": "heal",
                    "task_title": String(savedTask.prefix(100)),
                    "source": source,
                    "type": "system_signal",
                ]
                for (k, v) in extraProps { props[k] = v }
                PostHogManager.shared.track("discovered_task_created", properties: props)

                if let barFrame = FloatingControlBarManager.shared.barWindowFrame {
                    AnalysisOverlayWindow.shared.show(below: barFrame, task: savedTask, category: "heal", description: savedDesc, document: savedDoc, activityId: savedId)
                }
            }
        } catch {
            log("ResourceMonitor: failed to persist heal card source=\(payload.source): \(error)")
        }
    }

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

    /// Build a heal-card payload for a kernel panic and hand it to the shared writer.
    /// Schema mirrors what GeminiAnalysisService writes for visual heal signals.
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

        await writeHealCard(HealCardPayload(
            source: "kernel_panic",
            task: task,
            description: description,
            document: document,
            metadata: [
                "panic_path": panicURL.path,
                "panic_mtime": ISO8601DateFormatter().string(from: mtime),
                "panic_count_7d": totalCount,
            ]
        ))
    }

    // MARK: fseventsd memory leak

    /// Surface a heal card when fseventsd has been running >24h with >1GB RSS. This is
    /// a documented recurring pattern on this user's machine; the daemon enters a retry
    /// loop watching a contaminated directory and leaks memory until killed.
    nonisolated func checkFseventsdMemory() async {
        let cooldownKey = "lastFlaggedFseventsdMemory"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: cooldownKey)
        guard now - last > 86400 else { return }

        guard let stats = readFseventsdStats() else { return }
        let rssMB = stats.rssBytes / 1024 / 1024
        let uptimeHours = Int(stats.uptimeSeconds / 3600)

        // Threshold: >1024 MB RSS AND running >24h. Both conditions must hold — fresh
        // fseventsd processes can briefly spike high during reindex and recover.
        guard rssMB > 1024, stats.uptimeSeconds > 86400 else { return }

        UserDefaults.standard.set(now, forKey: cooldownKey)
        log("ResourceMonitor: fseventsd RSS=\(rssMB)MB uptime=\(uptimeHours)h, surfacing heal card")

        let task = "fseventsd is using \(rssMB) MB RAM after \(uptimeHours) hours, this often indicates a leak"
        let description = "fseventsd is the macOS file-events daemon. When it grows past 1 GB after running for many hours it usually means it is stuck in a retry loop watching a corrupted or contaminated directory. Restarting it clears the leak (file events resume in ~3 seconds), but Fazm can investigate the trigger first so the leak does not return."
        let document = """
        ## What Was Observed

        The system file-events daemon `fseventsd` (PID \(stats.pid)) is using \(rssMB) MB of RAM and has been running for \(uptimeHours) hours.

        ## Why This Happens

        fseventsd watches the filesystem for changes. If a directory it monitors becomes corrupted or contains thousands of churning artifacts (Rust `target/`, Next.js `.next/`, node_modules, build outputs synced to iCloud), fseventsd ends up in a retry loop and its memory grows without bound.

        ## Recommended Approach (read-only first)

        1. Run `brctl status` to check whether iCloud Drive has a stuck pending-scan queue (a high count is the usual trigger).
        2. Inspect `~/Library/Mobile Documents/com~apple~CloudDocs/` root for unexpected build artifacts. Normal iCloud root has fewer than 30 entries.
        3. If contamination is found, recommend the user move the artifacts out of iCloud (set `CARGO_TARGET_DIR` outside iCloud, exclude `.next/`, etc.).
        4. Restarting fseventsd requires `sudo killall fseventsd`. Never run sudo without explicit user approval.
        """

        await writeHealCard(HealCardPayload(
            source: "fseventsd_memory",
            task: task,
            description: description,
            document: document,
            metadata: [
                "fseventsd_pid": stats.pid,
                "fseventsd_rss_mb": rssMB,
                "fseventsd_uptime_hours": uptimeHours,
            ]
        ))
    }

    /// Parse `ps -axo pid,rss,etimes,comm` and return the fseventsd row if present.
    /// fseventsd runs as root with a stable command name; only one instance exists.
    nonisolated private func readFseventsdStats() -> (pid: Int, rssBytes: UInt64, uptimeSeconds: TimeInterval)? {
        guard let out = runShellCommand("/bin/ps", args: ["-axo", "pid,rss,etimes,comm"]) else { return nil }
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("PID") { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4 else { continue }
            let comm = parts[parts.count - 1]
            guard comm.hasSuffix("fseventsd") else { continue }
            guard let pid = Int(parts[0]),
                  let rssKB = UInt64(parts[1]),
                  let etimes = Int(parts[2]) else { continue }
            return (pid, rssKB * 1024, TimeInterval(etimes))
        }
        return nil
    }

    // MARK: iCloud root contamination

    /// Documented as the user's 5-day freeze cycle root cause (Mar 9 2026): dev tools
    /// dump build artifacts (Rust `target/`, Next.js `.next/`) into iCloud root, fseventsd
    /// and fileproviderd enter a permanent retry loop. Normal iCloud root has <30 items;
    /// >50 means something is contaminating it.
    nonisolated func checkICloudRootContamination() async {
        let cooldownKey = "lastFlaggedICloudRootContamination"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: cooldownKey)
        guard now - last > 86400 else { return }

        let path = NSString(string: "~/Library/Mobile Documents/com~apple~CloudDocs").expandingTildeInPath
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let count = entries.count

        // Threshold: >50 entries. Below that, even noisy users sit comfortably; above
        // is almost always a sync explosion in progress.
        guard count > 50 else { return }

        let suspiciousNames: Set<String> = ["target", ".next", "node_modules", "build", "dist", ".swiftpm", ".git", ".turbo", ".cache"]
        let suspicious = entries.compactMap { entry -> String? in
            let name = entry.lastPathComponent
            return suspiciousNames.contains(name.lowercased()) ? name : nil
        }.prefix(10).map { $0 }

        UserDefaults.standard.set(now, forKey: cooldownKey)
        log("ResourceMonitor: iCloud root has \(count) items (suspicious=\(suspicious)), surfacing heal card")

        let task = "iCloud Drive root has \(count) items (normal is fewer than 30), dev artifacts may be leaking in"
        let description = "Your iCloud Drive root contains \(count) entries. Normal usage keeps this under 30. Excess entries usually mean a dev tool is dumping build output (Rust `target/`, Next.js `.next/`, node_modules) into iCloud, which causes fseventsd / fileproviderd / cloudd to spin permanently and triggers the recurring slowdowns."
        let document = """
        ## What Was Observed

        `~/Library/Mobile Documents/com~apple~CloudDocs/` contains \(count) top-level entries (normal is fewer than 30).
        \(suspicious.isEmpty ? "" : "\nSuspicious build-artifact entries detected: \(suspicious.joined(separator: ", "))")

        ## Why This Matters

        iCloud syncs every file in this directory. When a dev tool writes a `target/` (thousands of Rust object files) or a `.next/` directory to iCloud root, every change forces a sync attempt. fseventsd, fileproviderd, and cloudd then enter a retry loop, leaking memory and burning CPU until reboot. This is a documented multi-day freeze cycle root cause on this machine.

        ## Recommended Approach

        1. List the iCloud root with `ls -la "~/Library/Mobile Documents/com~apple~CloudDocs/"` to see all entries with sizes.
        2. Identify entries that look like build artifacts (`target`, `.next`, `node_modules`, `build`, `dist`) or test scratch directories.
        3. Move them out of iCloud (they should never be synced). For Rust set `CARGO_TARGET_DIR` outside iCloud; for Node add the build directory to `.gitignore`-equivalent exclusions.
        4. If `~/scripts/cleanup-icloud-dev-artifacts.sh` exists on this machine, recommend running it; otherwise build a one-off cleanup plan with the user.

        Read-only first. Never delete files in iCloud without explicit user approval.
        """

        await writeHealCard(HealCardPayload(
            source: "icloud_root_contamination",
            task: task,
            description: description,
            document: document,
            metadata: [
                "icloud_root_count": count,
                "icloud_suspicious_names": Array(suspicious),
            ]
        ))
    }

    // MARK: iCloud pending-scan queue stuck

    /// `brctl status` reports per-document sync state; pending-scan entries that are
    /// hours old indicate cloudd / fileproviderd are wedged and the user is bleeding
    /// CPU until they reboot or kill the daemons.
    nonisolated func checkICloudPendingScans() async {
        let cooldownKey = "lastFlaggedICloudPendingScans"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: cooldownKey)
        guard now - last > 43200 else { return } // 12h

        guard let out = runShellCommand("/usr/bin/brctl", args: ["status"], timeout: 10.0) else { return }
        var pendingCount = 0
        for line in out.split(separator: "\n") {
            if line.contains("pending-scan") { pendingCount += 1 }
        }

        // Threshold: >100 pending-scan entries. A handful is normal during active sync.
        guard pendingCount > 100 else { return }

        UserDefaults.standard.set(now, forKey: cooldownKey)
        log("ResourceMonitor: iCloud pending-scan count=\(pendingCount), surfacing heal card")

        let task = "iCloud Drive has \(pendingCount) items stuck in the pending-scan queue, sync may be wedged"
        let description = "`brctl status` shows \(pendingCount) entries in the pending-scan state. When this count is large and persistent, cloudd / fileproviderd are stuck in a retry loop, burning CPU and stalling iCloud sync until they are restarted or the underlying contamination is cleaned up."
        let document = """
        ## What Was Observed

        `brctl status` reports \(pendingCount) entries in the pending-scan state.

        ## Why This Matters

        A small pending-scan count is normal during active sync. A persistent large count means the iCloud daemons (cloudd, fileproviderd, bird) are unable to make progress on these items and are retrying in a loop. This burns CPU and blocks the rest of iCloud sync.

        ## Recommended Approach (read-only first)

        1. Re-run `brctl status` and inspect which paths are stuck — they often share a common parent (a contaminated directory in iCloud root).
        2. Cross-check against `~/Library/Mobile Documents/com~apple~CloudDocs/` for build artifacts that should not be there.
        3. Recommended fix is `sudo killall fseventsd bird cloudd fileproviderd` (all four simultaneously). The daemons respawn and start fresh. Requires explicit user approval — never run sudo silently.
        4. If still stuck after restart, deleting `~/Library/Application Support/CloudDocs/session/db` is safe (files are server-side) and forces a fresh session, but again requires user approval.
        """

        await writeHealCard(HealCardPayload(
            source: "icloud_pending_scans",
            task: task,
            description: description,
            document: document,
            metadata: [
                "icloud_pending_count": pendingCount,
            ]
        ))
    }

    // MARK: Disk pressure

    /// Below 5% free or 5 GB free on `/`, macOS starts failing to launch apps, killing
    /// background processes, and corrupting iCloud sync. Surface early so the user can
    /// clean up before the system degrades.
    nonisolated func checkDiskPressure() async {
        let cooldownKey = "lastFlaggedDiskPressure"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: cooldownKey)
        guard now - last > 86400 else { return }

        let path = "/"
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let totalBytes = (attrs[.systemSize] as? NSNumber)?.uint64Value,
              let freeBytes = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value,
              totalBytes > 0 else { return }

        let freeGB = Double(freeBytes) / 1_073_741_824.0
        let totalGB = Double(totalBytes) / 1_073_741_824.0
        let freePercent = Double(freeBytes) / Double(totalBytes) * 100.0

        // Threshold: <5 GB free OR <5% free. Either alone is uncomfortable.
        guard freeGB < 5.0 || freePercent < 5.0 else { return }

        UserDefaults.standard.set(now, forKey: cooldownKey)
        log("ResourceMonitor: disk free=\(String(format: "%.1f", freeGB))GB (\(String(format: "%.1f", freePercent))%), surfacing heal card")

        let task = "Startup disk has only \(String(format: "%.1f", freeGB)) GB free (\(String(format: "%.1f", freePercent))%), low-disk failures imminent"
        let description = "macOS uses free disk space for swap, APFS snapshots, and Time Machine local copies. Below 5% free, you will see apps refusing to launch, background services killed, and iCloud sync corrupted. Cleaning out caches, downloads, or stuck snapshots restores headroom."
        let document = """
        ## What Was Observed

        Disk `/` has \(String(format: "%.1f", freeGB)) GB free out of \(String(format: "%.1f", totalGB)) GB total (\(String(format: "%.1f", freePercent))% free).

        ## Why This Matters

        macOS reserves disk for swap and APFS snapshots. Below 5% free, the system can fail to launch apps, kill background processes, and corrupt iCloud sync. Below 1% free, the entire system can hang.

        ## Recommended Approach (read-only first)

        1. Run `du -sh ~/Library/Caches ~/Library/Containers/*/Data/Library/Caches 2>/dev/null | sort -h | tail -10` to find the biggest cache offenders.
        2. Check `tmutil listlocalsnapshots /` for stuck Time Machine local snapshots that are eating space.
        3. Identify the largest files in the user's home with `du -sh ~/* 2>/dev/null | sort -h | tail -20`.
        4. Suggest specific cleanups (clearing caches, removing old downloads, deleting old build artifacts). Never delete files without explicit user approval.
        """

        await writeHealCard(HealCardPayload(
            source: "disk_pressure",
            task: task,
            description: description,
            document: document,
            metadata: [
                "disk_free_gb": Int(freeGB),
                "disk_free_percent": Int(freePercent),
                "disk_total_gb": Int(totalGB),
            ]
        ))
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
