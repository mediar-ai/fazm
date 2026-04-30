@preconcurrency import Foundation
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
    func standardUserDriverWillShowReleaseNotesText(_ releaseNotesText: NSAttributedString, forUpdate update: SUAppcastItem, withBundleDisplayVersion bundleDisplayVersion: String, bundleVersion: String) -> NSAttributedString? {
        let note = "Note: macOS may ask you to allow App Management permission for Fazm to install this update.\n\n"
        let result = NSMutableAttributedString(string: note, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        result.append(releaseNotesText)
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

        // If a different (newer) version is available, clear the rollback blocklist
        if let blockedVersion = UpdateRollbackManager.blockedVersion,
           version != blockedVersion {
            logSync("Sparkle: Clearing rollback block — v\(version) available (was blocking v\(blockedVersion))")
            PostHogManager.shared.track("update_rollback_block_cleared", properties: [
                "previously_blocked_version": blockedVersion,
                "new_version": version,
            ])
            UpdateRollbackManager.clearBlockedVersion()
        }

        Task { @MainActor in
            AnalyticsManager.shared.updateAvailable(version: version)
            self.viewModel?.updateAvailable = true
            self.viewModel?.availableVersion = version
        }
    }

    /// Called before Sparkle shows the update UI. Throw to block the update dialog.
    /// We use this to show our App Management permission guide instead of Sparkle's dialog
    /// when the user hasn't granted permission yet.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        let version = updateItem.displayVersionString

        // Block versions that caused a crash loop and were rolled back
        if let blockedVersion = UpdateRollbackManager.blockedVersion,
           version == blockedVersion {
            logSync("Sparkle: Blocking rolled-back version v\(blockedVersion)")
            PostHogManager.shared.track("update_rollback_version_blocked", properties: ["blocked_version": blockedVersion])
            throw NSError(
                domain: "com.fazm.rollback",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Version \(blockedVersion) was rolled back due to crash loop"]
            )
        }

        if !UserDefaults.standard.bool(forKey: "hasSuccessfullyInstalledSparkleUpdate") {
            logSync("Sparkle: Blocking update dialog — showing App Management guide for v\(version)")
            // Delay slightly so the guide appears after the main window finishes loading
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                self.viewModel?.showAppManagementGuideIfNeeded(version: version)
            }
            throw NSError(
                domain: "com.fazm.updater",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Waiting for App Management permission"]
            )
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
        // Our own gating error from shouldProceedWithUpdate — not a real failure,
        // we throw it deliberately so we can show the App Management permission
        // guide instead of Sparkle's default dialog. Don't log or report it.
        let isAppManagementGate = nsError.domain == "com.fazm.updater" && nsError.code == 1
        if isUpToDate {
            logSync("Sparkle: Already up to date")
        } else if isAppManagementGate {
            logSync("Sparkle: Update gated, showing App Management guide instead")
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
                logSync("Sparkle: Installation failed (4005), showing App Management permission guide")
                UserDefaults.standard.set(true, forKey: "hasSeenAppManagementError")
                // Reset the success flag so the proactive guide shows again next time
                UserDefaults.standard.set(false, forKey: "hasSuccessfullyInstalledSparkleUpdate")
                // Re-surface the sidebar warning in red (a fresh error overrides
                // any previous "X" dismissal in the sidebar widget).
                UserDefaults.standard.set(false, forKey: "appManagementWarningDismissed")
                Task { @MainActor in
                    let version = self.viewModel?.availableVersion ?? "unknown"
                    AppManagementSetupWindowController.shared.show(
                        version: version,
                        onDone: { [weak self] in
                            logSync("Sparkle: User granted App Management after install error, retrying update")
                            UserDefaults.standard.set(true, forKey: "hasSuccessfullyInstalledSparkleUpdate")
                            self?.viewModel?.checkForUpdatesInBackground()
                        },
                        onDismiss: {
                            logSync("Sparkle: User dismissed App Management guide after install error")
                        }
                    )
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
            // Staging users see both staging and beta releases (whichever is newer)
            return Set(["staging", "beta"])
        }
        return Set(["beta"])
    }

    /// Called when an update will be installed (app may terminate immediately after)
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        logSync("Sparkle: Installing update v\(version)")

        // Back up the current app bundle before Sparkle replaces it.
        // If the new version crash-loops, the rollback manager will restore this backup.
        // Run on a background thread — ditto copies ~100MB+ and waitUntilExit blocks
        // the main thread for seconds (FAZM-9K).
        DispatchQueue.global(qos: .userInitiated).async {
            UpdateRollbackManager.backupCurrentApp()
        }
        // Mark that App Management permission is working — don't show the guide again
        UserDefaults.standard.set(true, forKey: "hasSuccessfullyInstalledSparkleUpdate")
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
            AnalyticsManager.shared.updateChannelChanged(channel: updateChannel.rawValue)
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
        let isDevBuild = Bundle.main.bundleIdentifier == "com.fazm.desktop-dev"

        // Initialize the updater controller with our delegate
        // Dev builds: don't start the updater — local builds have invalid code signatures
        // so Sparkle installs always fail, causing the App Management guide to loop.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !isDevBuild,
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

        // Test hook: fake an available update for UI testing (dev builds only)
        // xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testUpdateAvailable"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        if Bundle.main.bundleIdentifier == "com.fazm.desktop-dev" {
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.fazm.testUpdateAvailable"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateAvailable = true
                    self?.availableVersion = "9.9.9"
                    logSync("UpdaterViewModel: Faked update available for testing")
                }
            }
        }

        // On launch, probe App Management permission if we previously showed the guide.
        // This handles the "Quit & Reopen" flow: user grants permission → app restarts →
        // we detect permission is now granted → show "done" guide → auto-trigger update.
        // Skip for dev builds — they have invalid code signatures so Sparkle installs always
        // fail with 4005, which resets the flag and causes this guide to show on every launch.
        if Bundle.main.bundleIdentifier != "com.fazm.desktop-dev",
           !UserDefaults.standard.bool(forKey: "hasSuccessfullyInstalledSparkleUpdate"),
           let guideVersion = UserDefaults.standard.string(forKey: "appManagementGuideLastShownVersion") {
            probeAndUnlockAppManagement(guideVersion: guideVersion)
        }
    }

    /// Try writing a temp file inside the app bundle to detect if App Management permission is granted.
    /// If granted, set the success flag and show the "done" guide so the user sees the result.
    private func probeAndUnlockAppManagement(guideVersion: String) {
        let testPath = Bundle.main.bundlePath + "/Contents/.fazm-permission-test"
        let fm = FileManager.default
        if fm.createFile(atPath: testPath, contents: Data("test".utf8)) {
            try? fm.removeItem(atPath: testPath)
            logSync("UpdaterViewModel: App Management permission detected on launch — showing done guide")
            UserDefaults.standard.set(true, forKey: "hasSuccessfullyInstalledSparkleUpdate")

            // Show the guide in "done" state after a short delay (let the main window appear first)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                AppManagementSetupWindowController.shared.showDone(
                    version: guideVersion,
                    onDone: { [weak self] in
                        logSync("Sparkle: User clicked Install Update after permission grant")
                        self?.checkForUpdates()
                    },
                    onDismiss: {
                        logSync("Sparkle: User dismissed done guide")
                    }
                )
            }
        }
    }

    /// Quick check if Sparkle is mid-update (safe to call from anywhere)
    nonisolated static var isUpdateInProgress: Bool {
        _isUpdateInProgress
    }

    /// Manually check for updates
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// After the user grants App Management permission in System Settings and returns to Fazm,
    /// automatically retry the update so they don't have to trigger it manually again.
    private var appManagementRetryObserver: NSObjectProtocol?

    func scheduleRetryAfterAppManagementGrant() {
        appManagementRetryObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.appManagementRetryObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.appManagementRetryObserver = nil
                }
                logSync("Sparkle: Retrying update after App Management permission grant")
                // Small delay to let the TCC change take effect
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.checkForUpdatesInBackground()
                }
            }
        }
    }

    /// Show a one-time guide explaining App Management permission before the user tries to install.
    /// Only shown once — dismissed permanently after the user acknowledges or after a successful install.
    private var hasShownAppManagementGuide = false

    func showAppManagementGuideIfNeeded(version: String) {
        guard !hasShownAppManagementGuide else { return }
        // Don't show if user already dismissed this session or previously installed successfully
        guard !UserDefaults.standard.bool(forKey: "hasSuccessfullyInstalledSparkleUpdate") else { return }
        // Don't show more than once per app version to avoid nagging
        let lastShownVersion = UserDefaults.standard.string(forKey: "appManagementGuideLastShownVersion")
        guard lastShownVersion != version else { return }
        hasShownAppManagementGuide = true
        UserDefaults.standard.set(version, forKey: "appManagementGuideLastShownVersion")

        logSync("Sparkle: Showing App Management permission guide for v\(version)")

        AppManagementSetupWindowController.shared.show(
            version: version,
            onDone: { [weak self] in
                logSync("Sparkle: User granted App Management, retrying update")
                UserDefaults.standard.set(true, forKey: "hasSuccessfullyInstalledSparkleUpdate")
                self?.checkForUpdatesInBackground()
            },
            onDismiss: {
                logSync("Sparkle: User dismissed App Management guide")
            }
        )
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
