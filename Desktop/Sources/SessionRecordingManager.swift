import Foundation
import SessionReplay

/// Manages session recording lifecycle, gated by PostHog feature flag.
///
/// Captures the full display at 5 FPS, encodes to H.265 chunks, and uploads
/// to GCS via signed URLs from the Fazm backend.
@MainActor
class SessionRecordingManager {
    static let shared = SessionRecordingManager()

    private var recorder: SessionRecorder?
    private var isStarted = false
    private var pollTimer: Timer?

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
                let status = await recorder.getStatus()
                log("SessionRecording: started (session=\(status.sessionId ?? "none"))")
            } catch {
                logError("SessionRecording: failed to start", error: error)
                self.isStarted = false
                self.recorder = nil
            }
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
