import AppKit
import Combine
import Foundation
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

    private init() {}

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
            PostHogManager.shared.reloadFeatureFlags()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self?.checkFlagAndUpdate()
            }
        }
    }

    private func checkFlagAndUpdate() {
        let enabled = PostHogManager.shared.isFeatureEnabled("session-recording-enabled")
        log("SessionRecording: feature flag session-recording-enabled = \(enabled)")

        if enabled && !isStarted {
            startRecording()
        } else if !enabled && isStarted {
            log("SessionRecording: flag turned off remotely, stopping")
            stop()
        }
    }

    private func startRecording() {

        guard ScreenCaptureService.checkPermission() else {
            log("SessionRecording: no screen recording permission, skipping")
            return
        }

        // Check bundled ffmpeg first, then fall back to system paths
        let bundledPath = Bundle.main.resourceURL?
            .appendingPathComponent("Fazm_Fazm.bundle/ffmpeg").path
        var ffmpegPaths = [String]()
        if let bp = bundledPath { ffmpegPaths.append(bp) }
        ffmpegPaths += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        guard let ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log("SessionRecording: ffmpeg not found (checked bundled + system paths), skipping")
            return
        }
        log("SessionRecording: using ffmpeg at \(ffmpegPath)")

        let backendURL = env("FAZM_BACKEND_URL")
        let backendSecret = env("FAZM_BACKEND_SECRET")
        guard !backendURL.isEmpty, !backendSecret.isEmpty else {
            log("SessionRecording: missing FAZM_BACKEND_URL or FAZM_BACKEND_SECRET, skipping")
            return
        }

        let storageDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("session-recordings")

        guard let deviceId = getDeviceId() else {
            log("SessionRecording: no Firebase UID yet, deferring until sign-in")
            return
        }

        let config = SessionRecorder.Configuration(
            framesPerSecond: 5.0,
            chunkDurationSeconds: 60.0,
            ffmpegPath: ffmpegPath,
            storageBaseURL: storageDir,
            deviceId: deviceId,
            backendURL: backendURL,
            backendSecret: backendSecret
        )

        let recorder = SessionRecorder(configuration: config)
        self.recorder = recorder
        isStarted = true

        Task {
            do {
                try await recorder.start()
                // Start paused — activity observers will resume when user interacts
                await recorder.pause()
                let status = await recorder.getStatus()
                log("SessionRecording: started paused (session=\(status.sessionId ?? "none"))")
            } catch {
                logError("SessionRecording: failed to start", error: error)
                self.isStarted = false
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
        barState.$isVoiceListening
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
        barState.$showingAIConversation
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
            self?.isMainWindowActive = true
            self?.resumeRecording(reason: "app became active")
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMainWindowActive = false
            self?.evaluatePauseState()
        }

        log("SessionRecording: activity observers installed")
    }

    /// Resume recording if currently paused.
    private func resumeRecording(reason: String) {
        guard let recorder else { return }
        Task {
            let paused = await recorder.isPaused
            guard paused else { return }
            await recorder.resume()
            log("SessionRecording: resumed (\(reason))")
        }
    }

    /// Check if recording should be paused. Only pause when no interaction signals are active.
    private func evaluatePauseState() {
        guard let recorder else { return }

        // Don't pause if agent is working — it may be using browser, opening files, etc.
        guard !isAgentWorking else { return }

        // Don't pause if the main window (settings/onboarding) is active
        guard !isMainWindowActive else { return }

        // Don't pause if the floating bar state still indicates active interaction
        // (checked via the Combine publishers above — if we got here, none are active)

        Task {
            let paused = await recorder.isPaused
            guard !paused else { return }
            await recorder.pause()
            log("SessionRecording: paused (no active interaction)")
        }
    }

    /// Stop recording (call on app termination or when flag is turned off).
    func stop() {
        guard isStarted, let recorder = recorder else { return }
        isStarted = false
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
        activityCancellables.removeAll()
        if let obs = appActiveObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = appResignObserver { NotificationCenter.default.removeObserver(obs) }
        stop()
    }

    // MARK: - Auto-enrollment

    /// Ask the backend to auto-enroll this device for session recording.
    /// Only enrolls beta channel users, up to a server-side cap.
    /// Calls completion on the main queue when done (or on failure).
    private func requestAutoEnroll(completion: @escaping () -> Void) {
        let backendURL = env("FAZM_BACKEND_URL")
        let backendSecret = env("FAZM_BACKEND_SECRET")
        guard !backendURL.isEmpty, !backendSecret.isEmpty else {
            completion()
            return
        }
        guard let deviceId = getDeviceId() else {
            completion()
            return
        }

        let channel = UserDefaults.standard.string(forKey: "update_channel") ?? "beta"

        guard let url = URL(string: "\(backendURL)/api/session-recording/auto-enroll") else {
            completion()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(backendSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["update_channel": channel]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { DispatchQueue.main.async { completion() } }

            if let error = error {
                log("SessionRecording: auto-enroll request failed: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let enrolled = json["enrolled"] as? Bool ?? false
            let reason = json["reason"] as? String ?? "unknown"
            log("SessionRecording: auto-enroll result: enrolled=\(enrolled) reason=\(reason)")
        }.resume()
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
