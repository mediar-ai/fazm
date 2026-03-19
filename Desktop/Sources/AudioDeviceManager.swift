import Combine
import CoreAudio
import Foundation

/// Represents a CoreAudio input device.
struct AudioDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    let isDefault: Bool

    var id: String { uid }
}

/// Singleton that enumerates CoreAudio input devices, monitors changes,
/// and provides optional audio-level metering for Settings UI.
@MainActor
class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    // MARK: - Published State

    @Published var devices: [AudioDevice] = []
    @Published var selectedDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(selectedDeviceUID, forKey: Self.selectedDeviceUDKey)
            restartLevelMonitoringIfNeeded()
        }
    }
    @Published var currentAudioLevel: Float = 0.0

    // MARK: - Computed

    /// Returns the user-selected device UID, or nil to use the system default.
    var effectiveDeviceUID: String? {
        if let uid = selectedDeviceUID, devices.contains(where: { $0.uid == uid }) {
            return uid
        }
        return nil
    }

    // MARK: - Private

    private static let selectedDeviceUDKey = "AudioDeviceManager.selectedDeviceUID"
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.fazm.audiodevicemanager.listener")

    // Level monitoring
    private var levelCaptureService: AudioCaptureService?
    private var isMonitoringLevel = false
    private var levelMonitorRetryTask: Task<Void, Never>?
    @Published var noMicrophoneAvailable = false

    // MARK: - Init

    private init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.selectedDeviceUDKey)
        refreshDevices()
        installDeviceListListener()
    }

    nonisolated func cleanUp() {
        // Called externally if needed; listeners are managed on init/deinit is tricky with @MainActor
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        let defaultUID = getDefaultInputDeviceUID()
        var devs: [AudioDevice] = []

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else {
            devices = []
            return
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else {
            devices = []
            return
        }

        for devID in deviceIDs {
            // Only include devices that have input streams
            guard hasInputStreams(devID) else { continue }
            guard let uid = getDeviceUID(devID), let name = getDeviceName(devID) else { continue }
            devs.append(AudioDevice(uid: uid, name: name, isDefault: uid == defaultUID))
        }

        devices = devs
    }

    // MARK: - Level Monitoring (for Settings UI)

    func startLevelMonitoring() {
        guard !isMonitoringLevel else { return }
        isMonitoringLevel = true
        noMicrophoneAvailable = false
        levelMonitorRetryTask?.cancel()
        levelMonitorRetryTask = nil

        let capture = AudioCaptureService()
        levelCaptureService = capture

        Task { @MainActor in
            do {
                try await capture.startCapture(
                    deviceUID: effectiveDeviceUID,
                    onAudioChunk: { _ in },
                    onAudioLevel: { [weak self] level in
                        Task { @MainActor in
                            self?.currentAudioLevel = level
                        }
                    }
                )
                noMicrophoneAvailable = false
            } catch let error as AudioCaptureService.AudioCaptureError where error.isNoInput {
                // Expected when no mic is connected (e.g. Mac mini) — don't report to Sentry
                log("AudioDeviceManager: no microphone available for level monitoring")
                isMonitoringLevel = false
                noMicrophoneAvailable = true
                scheduleLevelMonitorRetry()
            } catch {
                log("AudioDeviceManager: level monitoring failed: \(error.localizedDescription)")
                isMonitoringLevel = false
            }
        }
    }

    /// Retry level monitoring after a delay — picks up newly connected microphones.
    private func scheduleLevelMonitorRetry() {
        levelMonitorRetryTask?.cancel()
        levelMonitorRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            guard !Task.isCancelled, let self, !self.isMonitoringLevel else { return }
            self.startLevelMonitoring()
        }
    }

    func stopLevelMonitoring() {
        levelMonitorRetryTask?.cancel()
        levelMonitorRetryTask = nil
        guard isMonitoringLevel else { return }
        levelCaptureService?.stopCapture()
        levelCaptureService = nil
        isMonitoringLevel = false
        currentAudioLevel = 0.0
        noMicrophoneAvailable = false
    }

    /// Restart level monitoring on a background thread so we can synchronously
    /// stop the old capture (releasing the device) before starting a new one.
    private func restartLevelMonitoringIfNeeded() {
        guard isMonitoringLevel else { return }

        levelMonitorRetryTask?.cancel()
        levelMonitorRetryTask = nil
        let oldCapture = levelCaptureService
        levelCaptureService = nil
        isMonitoringLevel = false
        currentAudioLevel = 0.0
        noMicrophoneAvailable = false

        let newDeviceUID = effectiveDeviceUID

        Task.detached { [weak self] in
            // Synchronously stop old capture so the device is fully released
            oldCapture?.stopCapture(sync: true)

            let capturedSelf = self
            await MainActor.run {
                guard let strongSelf = capturedSelf else { return }
                guard !strongSelf.isMonitoringLevel else { return }
                strongSelf.isMonitoringLevel = true

                let capture = AudioCaptureService()
                strongSelf.levelCaptureService = capture

                Task { @MainActor [weak capturedSelf] in
                    do {
                        try await capture.startCapture(
                            deviceUID: newDeviceUID,
                            onAudioChunk: { _ in },
                            onAudioLevel: { [weak capturedSelf] level in
                                Task { @MainActor in
                                    capturedSelf?.currentAudioLevel = level
                                }
                            }
                        )
                    } catch let error as AudioCaptureService.AudioCaptureError where error.isNoInput {
                        log("AudioDeviceManager: no microphone available after restart")
                        capturedSelf?.isMonitoringLevel = false
                        capturedSelf?.noMicrophoneAvailable = true
                        capturedSelf?.scheduleLevelMonitorRetry()
                    } catch {
                        log("AudioDeviceManager: level monitoring restart failed: \(error.localizedDescription)")
                        capturedSelf?.isMonitoringLevel = false
                    }
                }
            }
        }
    }

    // MARK: - CoreAudio Helpers

    private func getDefaultInputDeviceUID() -> String? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return getDeviceUID(deviceID)
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let cfUID = uid?.takeRetainedValue() else { return nil }
        return cfUID as String
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    private func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    // MARK: - Device List Listener

    private func installDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        deviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
    }

    private func removeDeviceListListener() {
        guard let block = deviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        deviceListenerBlock = nil
    }
}
