import Foundation
import SwiftUI
import Sparkle

/// Update channel — beta (default for all users) or staging (pre-release testing)
enum UpdateChannel: String, CaseIterable {
    case beta = "beta"
    case staging = "staging"

    var displayName: String {
        switch self {
        case .beta: return "Beta"
        case .staging: return "Staging"
        }
    }

    var description: String {
        switch self {
        case .beta: return "Default channel for all users"
        case .staging: return "Pre-release builds for testing"
        }
    }
}

/// Delegate to customize Sparkle's standard user driver (update popup)
final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Prepend an App Management permission note to Sparkle's release notes
    func standardUserDriverWillShowReleaseNotesText(_ text: NSAttributedString) -> NSAttributedString {
        let note = "Note: macOS may ask you to allow App Management permission for Fazm to install this update.\n\n"
        let result = NSMutableAttributedString(string: note, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        result.append(text)
        return result
    }
}

/// Delegate to track Sparkle update events for analytics
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {

    /// Back-reference to the view model (set after init)
    weak var viewModel: UpdaterViewModel?

    // NOTE: All delegate methods use logSync() to write synchronously to disk.
    // Sparkle may terminate the app immediately after willInstallUpdate / didAbortWithError,
    // so async logging (Task + logQueue.async) would be lost.

    /// Called when Sparkle is about to check for updates (permission gate)
    func updater(_ updater: SPUUpdater, mayPerform check: SPUUpdateCheck) throws {
        logSync("Sparkle: Starting update check")
        Task { @MainActor in
            AnalyticsManager.shared.updateCheckStarted()
        }
    }

    /// Called when Sparkle finishes loading the appcast
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        logSync("Sparkle: Appcast loaded (\(appcast.items.count) items)")
    }

    /// Called when Sparkle finds a valid update
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        logSync("Sparkle: Found update v\(version)")
        Task { @MainActor in
            AnalyticsManager.shared.updateAvailable(version: version)
            self.viewModel?.updateAvailable = true
            self.viewModel?.availableVersion = version
        }
    }

    /// Called when no update is available
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        logSync("Sparkle: No update available")
        Task { @MainActor in
            AnalyticsManager.shared.updateNotFound()
            self.viewModel?.updateAvailable = false
        }
    }

    /// Called when the update driver aborts with an error
    /// Note: Sparkle also calls this with "You're up to date!" when no update is found,
    /// which is not an actual error — updaterDidNotFindUpdate handles that case.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        let nsError = error as NSError
        let isUpToDate = nsError.domain == SUSparkleErrorDomain
            && nsError.code == 1001 /* SUNoUpdateError */
        if isUpToDate {
            logSync("Sparkle: Already up to date")
        } else {
            logSync("Sparkle: Update check failed - \(message) [domain=\(nsError.domain) code=\(nsError.code)]")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                logSync("Sparkle: Underlying error - \(underlying.localizedDescription) [domain=\(underlying.domain) code=\(underlying.code)]")
            }
            for (key, value) in nsError.userInfo where key != NSUnderlyingErrorKey {
                logSync("Sparkle: Error info [\(key)] = \(value)")
            }
            // Build diagnostic properties for analytics
            let errorDomain = nsError.domain
            let errorCode = nsError.code
            var underlyingMessage: String? = nil
            var underlyingDomain: String? = nil
            var underlyingCode: Int? = nil

            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                underlyingMessage = underlying.localizedDescription
                underlyingDomain = underlying.domain
                underlyingCode = underlying.code
            }

            Task { @MainActor in
                AnalyticsManager.shared.updateCheckFailed(
                    error: message,
                    errorDomain: errorDomain,
                    errorCode: errorCode,
                    underlyingError: underlyingMessage,
                    underlyingDomain: underlyingDomain,
                    underlyingCode: underlyingCode
                )
            }

            // SUInstallationError (4005): Sparkle's installer failed to launch.
            // On macOS 26, AuthorizationCreate/SMJobSubmit can fail due to stricter
            // code signature validation or on-demand-only launchd mode.
            // Show an alert guiding the user to enable App Management permission.
            let isInstallationError = nsError.domain == SUSparkleErrorDomain && nsError.code == 4005
            if isInstallationError {
                logSync("Sparkle: Installation failed (4005), showing App Management permission alert")
                UserDefaults.standard.set(true, forKey: "hasSeenAppManagementError")
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Update requires permission"
                    alert.informativeText = "macOS blocked the update because Fazm needs App Management permission. To enable auto-updates:\n\n1. Open System Settings → Privacy & Security → App Management\n2. Toggle Fazm on\n3. Try updating again"
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Download Manually")
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        if let url = URL(string: "https://github.com/m13v/fazm/releases") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    /// Called after Sparkle has launched the installer and submitted launchd jobs.
    /// On macOS 26+, launchd may be in "on-demand-only mode" which prevents RunAtLoad
    /// services from starting. We force-start them via launchctl kickstart as a backup
    /// to Sparkle 2.9.0's built-in probe (PR #2852).
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        logSync("Sparkle: Installer launched for v\(item.displayVersionString), kickstarting services")
        kickstartSparkleServices()
    }

    /// Force-start Sparkle's launchd services to work around macOS 26 on-demand-only mode.
    /// Services submitted via SMJobSubmit with RunAtLoad=YES may not start immediately.
    /// Using `launchctl kickstart` forces launchd to spawn them right away.
    private func kickstartSparkleServices() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let updaterLabel = "\(bundleID)-sparkle-updater"
        let progressLabel = "\(bundleID)-sparkle-progress"
        let uid = getuid()

        // Try multiple times to handle timing variance
        for delay in [0.5, 2.0, 5.0] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                for label in [progressLabel, updaterLabel] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    process.arguments = ["kickstart", "-p", "gui/\(uid)/\(label)"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice

                    do {
                        try process.run()
                        process.waitUntilExit()
                        if process.terminationStatus == 0 {
                            logSync("Sparkle kickstart: started \(label) (delay=\(delay)s)")
                        }
                    } catch {
                        // Best effort — service may not exist yet or already running
                    }
                }
            }
        }
    }

    /// Tell Sparkle which channels this user is subscribed to.
    /// Empty set = production only (items with no channel tag).
    /// ["staging"] = production + staging items.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let saved = UserDefaults.standard.string(forKey: "update_channel") ?? "beta"
        if saved == "staging" {
            return Set(["staging"])
        }
        return Set()
    }

    /// Called when an update will be installed (app may terminate immediately after)
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        logSync("Sparkle: Installing update v\(version)")
        Task { @MainActor in
            AnalyticsManager.shared.updateInstalled(version: version)
            self.viewModel?.updateAvailable = false
        }
    }
}

/// View model for managing Sparkle auto-updates
/// Provides SwiftUI bindings for the updater UI
@MainActor
final class UpdaterViewModel: ObservableObject {
    static let shared = UpdaterViewModel()

    private let updaterController: SPUStandardUpdaterController
    private let updaterDelegate = UpdaterDelegate()
    private let userDriverDelegate = UserDriverDelegate()
    private var isInitialized = false

    /// Whether automatic update checks are enabled
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            if isInitialized {
                AnalyticsManager.shared.settingToggled(setting: "automatic_update_checks", enabled: automaticallyChecksForUpdates)
            }
        }
    }

    /// Whether updates are automatically downloaded and installed
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            updaterController.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            if isInitialized {
                AnalyticsManager.shared.settingToggled(setting: "auto_install_updates", enabled: automaticallyDownloadsUpdates)
            }
        }
    }

    /// Whether the updater can check for updates (e.g., not already checking)
    @Published private(set) var canCheckForUpdates: Bool = true

    /// Whether Sparkle has an active update session (downloading, installing, etc.)
    @Published private(set) var updateSessionInProgress: Bool = false {
        didSet { UpdaterViewModel._isUpdateInProgress = updateSessionInProgress }
    }

    /// Nonisolated snapshot for cross-actor reads
    private nonisolated(unsafe) static var _isUpdateInProgress: Bool = false

    /// Update channel — persisted to UserDefaults "update_channel"
    @Published var updateChannel: UpdateChannel = .beta {
        didSet {
            guard isInitialized else { return }
            UserDefaults.standard.set(updateChannel.rawValue, forKey: "update_channel")
            activeChannelLabel = updateChannel == .beta ? "" : updateChannel.displayName
            logSync("UpdaterViewModel: Channel changed to \(updateChannel.rawValue)")
            checkForUpdatesInBackground()
        }
    }

    /// Channel label for display (empty when beta — only shown for non-default channels)
    @Published var activeChannelLabel: String = ""

    /// Whether a new update is available (set by delegate callbacks)
    @Published var updateAvailable: Bool = false

    /// Version string of the available update
    @Published var availableVersion: String = ""

    /// The date of the last update check
    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }

    private init() {
        // Initialize the updater controller with our delegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )

        // Initialize published properties from updater state (must be before using `self`)
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updaterController.updater.automaticallyDownloadsUpdates

        // Wire up delegate back-reference
        updaterDelegate.viewModel = self

        // Check for updates every 10 minutes
        updaterController.updater.updateCheckInterval = 600

        // Observe updater state changes
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        updaterController.updater.publisher(for: \.sessionInProgress)
            .receive(on: DispatchQueue.main)
            .assign(to: &$updateSessionInProgress)

        // Load saved channel preference (migrate old "stable" → "beta")
        if let saved = UserDefaults.standard.string(forKey: "update_channel") {
            let migrated = saved == "stable" ? "beta" : saved
            if let channel = UpdateChannel(rawValue: migrated) {
                updateChannel = channel
                activeChannelLabel = channel == .beta ? "" : channel.displayName
                if saved == "stable" {
                    UserDefaults.standard.set("beta", forKey: "update_channel")
                }
            }
        }

        isInitialized = true
    }

    /// Quick check if Sparkle is mid-update (safe to call from anywhere)
    nonisolated static var isUpdateInProgress: Bool {
        _isUpdateInProgress
    }

    /// Manually check for updates
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Background update check (no UI). Used after channel changes.
    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }

    /// Get the current app version string
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    /// Get the current build number
    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

}
