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

    private init() {}

    /// Check the feature flag and start recording if enabled.
    /// Call this after PostHog is initialized and feature flags are loaded.
    func startIfEnabled() {
        guard !isStarted else { return }

        let enabled = PostHogManager.shared.isFeatureEnabled("session-recording-enabled")
        log("SessionRecording: feature flag session-recording-enabled = \(enabled)")
        guard enabled else { return }

        guard ScreenCaptureService.checkPermission() else {
            log("SessionRecording: no screen recording permission, skipping")
            return
        }

        let ffmpegPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        guard let ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log("SessionRecording: ffmpeg not found, skipping")
            return
        }

        let backendURL = env("FAZM_BACKEND_URL")
        let backendSecret = env("FAZM_BACKEND_SECRET")
        guard !backendURL.isEmpty, !backendSecret.isEmpty else {
            log("SessionRecording: missing FAZM_BACKEND_URL or FAZM_BACKEND_SECRET, skipping")
            return
        }

        let storageDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("session-recordings")

        let config = SessionRecorder.Configuration(
            framesPerSecond: 5.0,
            chunkDurationSeconds: 60.0,
            ffmpegPath: ffmpegPath,
            storageBaseURL: storageDir,
            deviceId: getDeviceId(),
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

    /// Stop recording (call on app termination).
    func stop() {
        guard isStarted, let recorder = recorder else { return }
        isStarted = false
        Task {
            await recorder.stop()
            log("SessionRecording: stopped")
        }
        self.recorder = nil
    }

    // MARK: - Private

    private func env(_ key: String) -> String {
        if let ptr = getenv(key) { return String(cString: ptr) }
        return ""
    }

    private func getDeviceId() -> String {
        let key = "analytics_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
