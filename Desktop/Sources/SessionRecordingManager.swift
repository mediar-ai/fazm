import AppKit
import Combine
import Foundation
import PostHog
import SessionReplay

/// Manages session recording lifecycle, gated by PostHog feature flag.
///
/// Captures the full display at 5 FPS, encodes to H.265 chunks, and uploads
/// to GCS via signed URLs from the Fazm backend.
///
/// Recording is paused when the user is not interacting with the app and resumed
/// when any interaction begins (PTT, floating bar focus, main window focus, active query).
@MainActor
class SessionRecordingManager {
    static let shared = SessionRecordingManager()

    // MARK: - GCS Upload Recorder (flag-gated, for user research)
    private var recorder: SessionRecorder?
    private var isStarted = false
    private var pollTimer: Timer?
    private var activityCancellables = Set<AnyCancellable>()
    private var appActiveObserver: Any?
    private var appResignObserver: Any?

    /// Tracks whether the app's main window (settings/onboarding) is in the foreground.
    private var isMainWindowActive = false
    /// Tracks whether the AI agent is actively processing a query.
    private var isAgentWorking = false
    /// Delayed pause: keep recording for 30s after last interaction so we capture
    /// the user reading the response / reacting before pausing.
    private var pauseWorkItem: DispatchWorkItem?
    private let pauseDelay: TimeInterval = 30

    // MARK: - Screen Observer Recorder (Gemini analysis, always-on, local-only, no feature flag)
    private var screenObserverRecorder: SessionRecorder?
    private var isScreenObserverStarted = false

    private init() {}

    // MARK: - Stale Recording Cleanup

    /// Reclaim disk space from stale recordings left over by prior app sessions.
    /// Call once per launch from FazmApp before starting either recorder.
    ///
    /// Two failure modes accumulate files:
    ///   1. Observer mode has no uploader, so before the moveItem fix in
    ///      GeminiAnalysisService.handleChunk, every analyzed chunk left its raw
    ///      copy under Caches/observer-recordings/.
    ///   2. Every short-lived app launch (./run.sh rebuild, Sparkle relaunch, an
    ///      accidental `Fazm --version` probe) creates a fresh `<UUID>/Videos/`
    ///      under both cache dirs and exits before producing chunks, leaving the
    ///      empty shell behind forever.
    nonisolated static func cleanupStaleRecordings() {
        DispatchQueue.global(qos: .utility).async {
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let sessions = sweepRecordingsDir(
                cachesDir.appendingPathComponent("session-recordings"),
                maxAge: 7 * 24 * 60 * 60  // research uploader; conservative to protect failed-upload retries
            )
            let observers = sweepRecordingsDir(
                cachesDir.appendingPathComponent("observer-recordings"),
                maxAge: 24 * 60 * 60  // Gemini cycle is ~1h, anything 24h old is consumed-and-orphaned
            )
            let totalBytes = sessions.bytes + observers.bytes
            let totalFiles = sessions.files + observers.files
            let totalDirs = sessions.dirs + observers.dirs
            log("SessionRecording: cleanup freed \(totalBytes / 1_048_576) MB (\(totalFiles) chunks, \(totalDirs) empty dirs)")
            if totalFiles > 0 || totalDirs > 0 {
                PostHogSDK.shared.capture("session_recording_cleanup_completed", properties: [
                    "session_bytes_freed": sessions.bytes,
                    "session_files_deleted": sessions.files,
                    "session_dirs_deleted": sessions.dirs,
                    "observer_bytes_freed": observers.bytes,
                    "observer_files_deleted": observers.files,
                    "observer_dirs_deleted": observers.dirs,
                ])
            }
        }
    }

    private struct SweepResult {
        var bytes: Int64 = 0
        var files: Int = 0
        var dirs: Int = 0
    }

    nonisolated private static func sweepRecordingsDir(_ dir: URL, maxAge: TimeInterval) -> SweepResult {
        var result = SweepResult()
        let fm = FileManager.default
        guard let uuidDirs = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return result }
        let now = Date()

        for uuidDir in uuidDirs {
            let values = try? uuidDir.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }

            // Skip directories touched in the last 5 minutes — could be the
            // active recorder for the currently-running app instance.
            if let mtime = values?.contentModificationDate, now.timeIntervalSince(mtime) < 300 {
                continue
            }

            var hasRemainingChunk = false
            if let enumerator = fm.enumerator(
                at: uuidDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    guard url.pathExtension == "mp4" else { continue }
                    let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let age = now.timeIntervalSince(attrs?.contentModificationDate ?? now)
                    if age > maxAge {
                        let size = Int64(attrs?.fileSize ?? 0)
                        do {
                            try fm.removeItem(at: url)
                            result.bytes += size
                            result.files += 1
                        } catch {
                            hasRemainingChunk = true
                        }
                    } else {
                        hasRemainingChunk = true
                    }
                }
            }

            if !hasRemainingChunk {
                if (try? fm.removeItem(at: uuidDir)) != nil {
                    result.dirs += 1
                }
            }
        }
        return result
    }

    /// Check the feature flag and start/stop recording accordingly.
    /// Call this after PostHog is initialized. Polls every 5 minutes for flag changes.
    func startIfEnabled() {
        // Force reload flags from server, then check after a short delay
        PostHogManager.shared.reloadFeatureFlags()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkFlagAndUpdate()
            self?.startPolling()
        }
    }

    // MARK: - Screen Observer (Gemini analysis, always-on, local-only)

    /// Start the screen observer recorder for Gemini analysis.
    /// Runs continuously while the app is open, no feature flag needed.
    /// Only requires screen recording permission and a Gemini API key.
    func startScreenObserver() {
        guard !isScreenObserverStarted else { return }

        guard ScreenCaptureService.checkPermission() else {
            log("Screen observer: no screen recording permission, skipping")
            return
        }

        guard let ffmpegPath = findFfmpeg() else {
            log("Screen observer: ffmpeg not found, skipping")
            return
        }

        let storageDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("observer-recordings")

        // Use a stable device identifier (hardware UUID) — no auth required
        let deviceId = getHardwareUUID() ?? "unknown"

        Task {
            let config = SessionRecorder.Configuration(
                framesPerSecond: 2.0,  // Lower FPS than research recorder to save CPU
                chunkDurationSeconds: 60.0,
                ffmpegPath: ffmpegPath,
                storageBaseURL: storageDir,
                deviceId: deviceId,
                // No backendURL/backendSecret → local-only mode
                captureMode: .activeWindow  // Only capture the frontmost app for task analysis
            )

            let recorder = SessionRecorder(configuration: config)
            self.screenObserverRecorder = recorder
            self.isScreenObserverStarted = true
            ResourceCounters.shared.set("sessionRecording_observerActive", true)

            // Wire up Gemini analysis
            await recorder.setOnChunkReady { info in
                let chunkInfo = GeminiAnalysisService.ChunkInfo(
                    localURL: info.localURL,
                    chunkIndex: info.chunkIndex,
                    startTimestamp: info.startTimestamp,
                    endTimestamp: info.endTimestamp,
                    activeApps: info.activeApps.map { app in
                        GeminiAnalysisService.ActiveAppInfo(
                            appName: app.appName,
                            windowTitle: app.windowTitle,
                            frameCount: app.frameCount
                        )
                    }
                )
                await GeminiAnalysisService.shared.handleChunk(chunkInfo)
            }

            do {
                try await recorder.start()
                log("Screen observer: started (local-only, 2 FPS)")
            } catch {
                logError("Screen observer: failed to start", error: error)
                self.isScreenObserverStarted = false
                ResourceCounters.shared.set("sessionRecording_observerActive", false)
                self.screenObserverRecorder = nil
            }
        }
    }

    /// Stop the screen observer recorder.
    func stopScreenObserver() {
        guard isScreenObserverStarted, let recorder = screenObserverRecorder else { return }
        isScreenObserverStarted = false
        ResourceCounters.shared.set("sessionRecording_observerActive", false)
        Task {
            await recorder.stop()
            log("Screen observer: stopped")
        }
        self.screenObserverRecorder = nil
    }

    private func getHardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let key = kIOPlatformUUIDKey as CFString
        guard let uuid = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
        return uuid
    }

    /// Re-check the feature flag after sign-in (distinct_id changes to Firebase UID).
    /// Also attempts auto-enrollment for beta channel users.
    func recheckAfterSignIn() {
        log("SessionRecording: re-checking flag after sign-in")

        // Try auto-enrollment first, then reload flags after enrollment completes.
        // The completion handler reloads flags with a delay to let PostHog propagate.
        requestAutoEnroll { [weak self] in
            PostHogManager.shared.reloadFeatureFlags()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self?.checkFlagAndUpdate()
            }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                PostHogManager.shared.reloadFeatureFlags()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self?.checkFlagAndUpdate()
                }
            }
        }
    }

    func checkFlagAndUpdate() {
        let enabled = PostHogManager.shared.isFeatureEnabled("session-recording-enabled")
        log("SessionRecording: feature flag session-recording-enabled = \(enabled)")

        if enabled && !isStarted {
            startRecording()
        } else if !enabled && isStarted {
            log("SessionRecording: flag turned off remotely, stopping")
            stop()
        }
    }

    private func findFfmpeg() -> String? {
        let bundledPath = Bundle.main.resourceURL?
            .appendingPathComponent("Fazm_Fazm.bundle/ffmpeg").path
        var paths = [String]()
        if let bp = bundledPath { paths.append(bp) }
        paths += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return paths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func startRecording() {

        guard ScreenCaptureService.checkPermission() else {
            log("SessionRecording: no screen recording permission, skipping (user can grant via Settings > Permissions)")
            return
        }

        guard let ffmpegPath = findFfmpeg() else {
            log("SessionRecording: ffmpeg not found (checked bundled + system paths), skipping")
            return
        }
        log("SessionRecording: using ffmpeg at \(ffmpegPath)")

        let backendURL = env("FAZM_BACKEND_URL")
        guard !backendURL.isEmpty else {
            log("SessionRecording: missing FAZM_BACKEND_URL, skipping")
            return
        }
        guard AuthService.shared.isSignedIn else {
            log("SessionRecording: user not signed in, skipping")
            return
        }

        let storageDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("session-recordings")

        guard let deviceId = getDeviceId() else {
            log("SessionRecording: no Firebase UID yet, deferring until sign-in")
            return
        }

        Task {
            // Get the current Firebase ID token to pass to the session replay library.
            // The library expects a static backendSecret string; we pass the current token
            // as a temporary measure. The backend accepts both Firebase tokens and the old secret.
            let currentToken: String
            do {
                let authHeader = try await AuthService.shared.getAuthHeader()
                // Strip "Bearer " prefix — the library adds its own
                let prefix = "Bearer "
                currentToken = authHeader.hasPrefix(prefix) ? String(authHeader.dropFirst(prefix.count)) : authHeader
            } catch {
                log("SessionRecording: failed to get auth token, skipping: \(error.localizedDescription)")
                return
            }

            let config = SessionRecorder.Configuration(
                framesPerSecond: 5.0,
                chunkDurationSeconds: 60.0,
                ffmpegPath: ffmpegPath,
                storageBaseURL: storageDir,
                deviceId: deviceId,
                backendURL: backendURL,
                backendSecret: currentToken,  // Temporary: passing Firebase ID token as secret
                captureMode: .fullDisplay  // Capture entire desktop for analytics
            )

            let recorder = SessionRecorder(configuration: config)
            self.recorder = recorder
            self.isStarted = true
            ResourceCounters.shared.set("sessionRecording_active", true)

            do {
                try await recorder.start()
                // Start paused — activity observers will resume when user interacts
                await recorder.pause()
                let status = await recorder.getStatus()
                log("SessionRecording: started paused (session=\(status.sessionId ?? "none"))")
            } catch {
                logError("SessionRecording: failed to start", error: error)
                self.isStarted = false
                ResourceCounters.shared.set("sessionRecording_active", false)
                self.recorder = nil
            }
        }
    }

    // MARK: - Activity-Aware Pause/Resume

    /// Wire up observers for user interaction signals.
    /// Call after the floating bar and chat provider are available.
    func observeActivity(barState: FloatingControlBarState, chatProvider: ChatProvider) {
        activityCancellables.removeAll()

        // 1. PTT / voice listening → resume immediately
        barState.voice.$isVoiceListening
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] listening in
                if listening { self?.resumeRecording(reason: "PTT started") }
                else { self?.evaluatePauseState() }
            }
            .store(in: &activityCancellables)

        // 2. AI conversation collapsed (user clicked away) → evaluate pause
        //    Expanded from collapsed (user clicked back) → resume
        barState.$isCollapsed
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] collapsed in
                if collapsed { self?.evaluatePauseState() }
                else { self?.resumeRecording(reason: "bar expanded") }
            }
            .store(in: &activityCancellables)

        // 3. AI conversation opened → resume
        barState.streaming.$showingAIConversation
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showing in
                if showing { self?.resumeRecording(reason: "AI conversation opened") }
                else { self?.evaluatePauseState() }
            }
            .store(in: &activityCancellables)

        // 4. Agent actively working → keep recording even if user tabs away
        chatProvider.$isSending
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sending in
                self?.isAgentWorking = sending
                if sending { self?.resumeRecording(reason: "agent started") }
                else { self?.evaluatePauseState() }
            }
            .store(in: &activityCancellables)

        // 5. App activation (main window / settings / onboarding comes to front)
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isMainWindowActive = true
                self?.resumeRecording(reason: "app became active")
            }
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isMainWindowActive = false
                self?.evaluatePauseState()
            }
        }

        log("SessionRecording: activity observers installed")
    }

    /// Resume recording if currently paused.
    private func resumeRecording(reason: String) {
        // Cancel any pending delayed pause
        pauseWorkItem?.cancel()
        pauseWorkItem = nil

        // Touch the interaction marker so the run.sh watchdog knows the user is active
        touchInteractionMarker()

        guard let recorder else { return }
        Task {
            let paused = await recorder.isPaused
            guard paused else { return }
            await recorder.resume()
            log("SessionRecording: resumed (\(reason))")
        }
    }

    /// Touch a marker file that run.sh's watchdog uses to detect user interaction.
    /// Separate from the main log which gets written by background tasks constantly.
    private func touchInteractionMarker() {
        let path = "/tmp/fazm-dev-interaction"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        } else {
            // Update modification time
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: path
            )
        }
    }

    /// Schedule a pause after `pauseDelay` seconds. If any interaction happens before
    /// the delay expires, the pause is cancelled by `resumeRecording`.
    private func evaluatePauseState() {
        // Don't even schedule if agent is working or main window is active
        guard !isAgentWorking, !isMainWindowActive else {
            pauseWorkItem?.cancel()
            pauseWorkItem = nil
            return
        }

        // Already have a pending pause scheduled — let it run
        guard pauseWorkItem == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let recorder = self.recorder else { return }
            self.pauseWorkItem = nil
            // Re-check: conditions may have changed during the delay
            guard !self.isAgentWorking, !self.isMainWindowActive else { return }
            Task {
                let paused = await recorder.isPaused
                guard !paused else { return }
                await recorder.pause()
                log("SessionRecording: paused (no interaction for \(Int(self.pauseDelay))s)")
            }
        }
        pauseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseDelay, execute: work)
    }

    /// Stop recording (call on app termination or when flag is turned off).
    func stop() {
        guard isStarted, let recorder = recorder else { return }
        isStarted = false
        ResourceCounters.shared.set("sessionRecording_active", false)
        Task {
            await recorder.stop()
            log("SessionRecording: stopped")
        }
        self.recorder = nil
    }

    /// Stop recording and polling (call on app termination).
    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        pauseWorkItem?.cancel()
        pauseWorkItem = nil
        activityCancellables.removeAll()
        if let obs = appActiveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = appResignObserver { NotificationCenter.default.removeObserver(obs) }
        stop()
        stopScreenObserver()
    }

    // MARK: - Auto-enrollment

    /// Ask the backend to auto-enroll this device for session recording.
    /// Only enrolls beta channel users, up to a server-side cap.
    /// Calls completion on the main queue when done (or on failure).
    private func requestAutoEnroll(completion: @escaping () -> Void) {
        let backendURL = env("FAZM_BACKEND_URL")
        guard !backendURL.isEmpty, AuthService.shared.isSignedIn else {
            completion()
            return
        }
        guard let deviceId = getDeviceId() else {
            completion()
            return
        }

        Task {
            defer { completion() }

            do {
                let authHeader = try await AuthService.shared.getAuthHeader()
                let channel = UserDefaults.standard.string(forKey: "update_channel") ?? "beta"

                guard let url = URL(string: "\(backendURL)/api/session-recording/auto-enroll") else {
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: String] = ["update_channel": channel]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                let enrolled = json["enrolled"] as? Bool ?? false
                let reason = json["reason"] as? String ?? "unknown"
                log("SessionRecording: auto-enroll result: enrolled=\(enrolled) reason=\(reason)")
            } catch {
                log("SessionRecording: auto-enroll request failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    private func env(_ key: String) -> String {
        if let ptr = getenv(key) { return String(cString: ptr) }
        return ""
    }

    private func getDeviceId() -> String? {
        // Require Firebase UID so recordings are always tagged with the user's identity.
        // If auth hasn't completed yet, return nil to defer recording start.
        if let firebaseUid = AuthService.shared.userId, !firebaseUid.isEmpty {
            return firebaseUid
        }
        return nil
    }
}
