import AVFoundation
import SwiftUI
import UserNotifications
@preconcurrency import ObjectiveC

@MainActor
class AppState: ObservableObject {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false

    // Permission states for onboarding
    @Published var hasNotificationPermission = false
    @Published var notificationAlertStyle: UNAlertStyle = .none  // .none, .banner, or .alert
    @Published var hasScreenRecordingPermission = false

    // Track last notification settings for change detection (avoid duplicate analytics)
    private var lastNotificationAuthStatus: String?
    private var lastNotificationAlertStyle: String?
    private var lastNotificationSoundEnabled: Bool?
    private var lastNotificationBadgeEnabled: Bool?
    @Published var isScreenCaptureKitBroken = false  // TCC says yes but ScreenCaptureKit says no
    @Published var isScreenRecordingStale = false  // TCC says yes but capture fails (developer signing changed)
    var screenRecordingGrantAttempts = 0  // Track how many times user clicked Grant without success
    @Published var hasAccessibilityPermission = false
    @Published var isAccessibilityBroken = false  // TCC says yes but AX calls actually fail (common after macOS updates/app re-signs)
    private var lastAccessibilityApiDisabledLogged = false  // Dedup apiDisabled log spam

    /// True if notifications are enabled but won't show visual banners
    var isNotificationBannerDisabled: Bool {
        hasNotificationPermission && notificationAlertStyle == .none
    }


    /// Returns list of missing permissions that are required for full functionality
    var missingPermissions: [String] {
        var missing: [String] = []
        if !hasScreenRecordingPermission || isScreenCaptureKitBroken || isScreenRecordingStale { missing.append("Screen Recording") }
        if !hasNotificationPermission { missing.append("Notifications") }
        else if isNotificationBannerDisabled { missing.append("Notification Banners") }
        if !hasAccessibilityPermission || isAccessibilityBroken { missing.append("Accessibility") }
        return missing
    }

    /// Check if notification permission was explicitly denied
    func isNotificationPermissionDenied() -> Bool {
        // We need to check synchronously, so use a semaphore pattern
        // This is cached from checkNotificationPermission() calls
        return hasCompletedOnboarding && !hasNotificationPermission
    }

    /// Open notification preferences in System Settings (directly to Fazm's settings)
    func openNotificationPreferences() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fazm.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True if any required permissions are missing
    var hasMissingPermissions: Bool {
        !missingPermissions.isEmpty
    }

    // Periodic notification health check timer
    private var notificationHealthTimer: Timer?

    // Observers for app lifecycle
    private var willTerminateObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var screenLockedObserver: NSObjectProtocol?
    private var screenUnlockedObserver: NSObjectProtocol?
    private var screenCapturePermissionLostObserver: NSObjectProtocol?
    private var screenCaptureKitBrokenObserver: NSObjectProtocol?

    // Debounce timestamps to prevent duplicate system notifications
    private var lastScreenLockTime: Date?
    private var lastScreenUnlockTime: Date?

    init() {
        // Load API key from environment or .env file
        loadEnvironment()

        // Setup lifecycle observers
        setupLifecycleObservers()

        // Listen for screen capture permission loss notifications
        screenCapturePermissionLostObserver = NotificationCenter.default.addObserver(
            forName: .screenCapturePermissionLost,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hasScreenRecordingPermission = false
                self?.isScreenCaptureKitBroken = false  // Not broken, just lost
                log("AppState: Screen recording permission lost")
            }
        }

        // Listen for ScreenCaptureKit broken notifications (TCC granted but SCK declined)
        screenCaptureKitBrokenObserver = NotificationCenter.default.addObserver(
            forName: .screenCaptureKitBroken,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hasScreenRecordingPermission = false
                self?.isScreenCaptureKitBroken = true  // Needs reset
                log("AppState: ScreenCaptureKit broken - needs reset")
            }
        }

        // Start periodic notification health check (every 30 min)
        // Detects when macOS silently revokes notification authorization and auto-repairs
        notificationHealthTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkNotificationPermission()
            }
        }

        // Check microphone permission status on launch
        checkMicrophonePermission()
    }

    /// Setup observers for app lifecycle
    private func setupLifecycleObservers() {
        // App is about to quit
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            log("App terminating")
        }

        // Computer is about to sleep
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Flush final sync changes before sleep
                await AgentSyncService.shared.stop()
            }
        }

        // Computer woke from sleep
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            log("System woke from sleep")
            NotificationCenter.default.post(name: .systemDidWake, object: nil)
        }

        // Screen locked (debounced - macOS sometimes fires multiple times)
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let now = Date()
                if let lastTime = self?.lastScreenLockTime, now.timeIntervalSince(lastTime) < 1.0 {
                    return // Ignore duplicate within 1 second
                }
                self?.lastScreenLockTime = now
                log("Screen locked")
                NotificationCenter.default.post(name: .screenDidLock, object: nil)
            }
        }

        // Screen unlocked (debounced - macOS sometimes fires multiple times)
        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                let now = Date()
                if let lastTime = self?.lastScreenUnlockTime, now.timeIntervalSince(lastTime) < 1.0 {
                    return // Ignore duplicate within 1 second
                }
                self?.lastScreenUnlockTime = now
                log("Screen unlocked")
                NotificationCenter.default.post(name: .screenDidUnlock, object: nil)
            }
        }
    }

    deinit {
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = screenCapturePermissionLostObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = screenCaptureKitBrokenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func loadEnvironment() {
        // Try to load from .env file in various locations
        let envPaths = [
            Bundle.main.path(forResource: ".env", ofType: nil),
            FileManager.default.currentDirectoryPath + "/.env",
            NSHomeDirectory() + "/.hartford.env",
            NSHomeDirectory() + "/.fazm.env",
            // Explicit paths for development
            "/Users/matthewdi/fazm/.env"
        ].compactMap { $0 }

        for path in envPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                log("Loading environment from: \(path)")
                for line in contents.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        // Skip comments
                        guard !key.hasPrefix("#") else { continue }
                        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        setenv(key, value, 1)
                        // Log key names (not values for security)
                        if key.contains("API_KEY") || key.contains("KEY") {
                            log("  Set \(key)=***")
                        }
                    }
                }
                // Don't break - load all .env files to merge keys
            }
        }

        // Log final state of important keys
        if getenv("DEEPGRAM_API_KEY") != nil {
            log("DEEPGRAM_API_KEY is set via env")
        } else if !DeepgramKeyProvider.deobfuscate().isEmpty {
            log("DEEPGRAM_API_KEY is set via bundled key")
        } else {
            log("WARNING: DEEPGRAM_API_KEY is NOT set")
        }
    }

    func openScreenRecordingPreferences() {
        ScreenCaptureService.openScreenRecordingPreferences()
    }

    func requestNotificationPermission() {
        // First check current authorization status
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if settings.authorizationStatus == .notDetermined {
                    // First time - show the system prompt
                    NSApp.activate(ignoringOtherApps: true)
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
                        if let error = error {
                            let nsError = error as NSError
                            log("Notification permission error: \(error) (domain=\(nsError.domain) code=\(nsError.code))")

                            // UNErrorDomain code 1 = notificationsNotAllowed
                            // This happens when LaunchServices has the app marked as launch-disabled,
                            // which prevents the notification center from registering the app.
                            // Fix: unregister from LaunchServices and re-register to clear the flag, then retry.
                            if nsError.domain == "UNErrorDomain" && nsError.code == 1 {
                                DispatchQueue.main.async {
                                    AnalyticsManager.shared.notificationRepairTriggered(
                                        reason: "launch_disabled_error",
                                        previousStatus: "notDetermined",
                                        currentStatus: "error_code_1"
                                    )
                                    self?.repairNotificationRegistrationAndRetry()
                                }
                                return
                            }
                        }
                        DispatchQueue.main.async {
                            self?.checkNotificationPermission()
                        }
                    }
                } else if settings.authorizationStatus == .denied {
                    // Previously denied - open System Settings so user can enable manually
                    self.openNotificationPreferences()
                }
                // If already authorized, checkNotificationPermission() will handle it
            }
        }
    }

    /// Repair LaunchServices registration when notification authorization fails.
    /// The "launch-disabled" flag in LaunchServices prevents the notification center
    /// from registering the app. This unregisters and re-registers to clear the flag.
    private func repairNotificationRegistrationAndRetry() {
        // Use the shared repair utility (also used by ProactiveAssistantsPlugin)
        ProactiveAssistantsPlugin.repairNotificationRegistration()

        // After the repair + retry, update our permission state and open System Settings as fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    let isNowGranted = settings.authorizationStatus == .authorized
                    self?.hasNotificationPermission = isNowGranted
                    if !isNowGranted {
                        log("Notification permission still not granted after repair. Opening System Settings.")
                        self?.openNotificationPreferences()
                    }
                }
            }
        }
    }

    /// Repair notification registration via lsregister, then fall back to System Settings if still broken.
    /// Called from sidebar and settings "Fix" buttons when auth is not authorized.
    func repairNotificationAndFallback() {
        log("Fix button tapped — running lsregister repair for notifications")
        ProactiveAssistantsPlugin.repairNotificationRegistration()

        // Wait for repair + re-authorization, then check if it worked
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    let isNowGranted = settings.authorizationStatus == .authorized
                    self?.hasNotificationPermission = isNowGranted
                    self?.notificationAlertStyle = settings.alertStyle
                    if isNowGranted {
                        log("Notification repair succeeded — auth is now authorized")
                    } else {
                        log("Notification repair didn't restore auth (status=\(settings.authorizationStatus.rawValue)) — opening System Settings")
                        self?.openNotificationPreferences()
                    }
                }
            }
        }
    }

    /// Trigger screen recording permission prompt
    func triggerScreenRecordingPermission() {
        // Request both traditional TCC and ScreenCaptureKit permissions
        ScreenCaptureService.requestAllScreenCapturePermissions()
    }

    // MARK: - Permission Status Checks

    /// Check and update all permission states
    func checkAllPermissions() {
        checkNotificationPermission()
        checkScreenRecordingPermission()
        checkAccessibilityPermission()
        // One-time startup diagnostic for accessibility
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        log("ACCESSIBILITY_STARTUP: bundleId=\(bundleId), macOS=\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion), TCC=\(hasAccessibilityPermission), broken=\(isAccessibilityBroken), onboarded=\(hasCompletedOnboarding)")
    }

    /// Check notification permission status and alert style
    func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let isNowGranted = settings.authorizationStatus == .authorized
                self.hasNotificationPermission = isNowGranted
                self.notificationAlertStyle = settings.alertStyle

                // Log the current notification settings
                let authStatus = switch settings.authorizationStatus {
                    case .notDetermined: "notDetermined"
                    case .denied: "denied"
                    case .authorized: "authorized"
                    case .provisional: "provisional"
                    case .ephemeral: "ephemeral"
                    @unknown default: "unknown"
                }
                let alertStyleName = switch settings.alertStyle {
                    case .none: "NONE (no banners)"
                    case .banner: "BANNER"
                    case .alert: "ALERT"
                    @unknown default: "unknown"
                }
                // Track notification settings in analytics only when they change
                let soundEnabled = settings.soundSetting == .enabled
                let badgeEnabled = settings.badgeSetting == .enabled
                let settingsChanged = authStatus != self.lastNotificationAuthStatus ||
                                      alertStyleName != self.lastNotificationAlertStyle ||
                                      soundEnabled != self.lastNotificationSoundEnabled ||
                                      badgeEnabled != self.lastNotificationBadgeEnabled

                if settingsChanged {
                    log("Notification settings: auth=\(authStatus), alertStyle=\(alertStyleName), sound=\(settings.soundSetting.rawValue), badge=\(settings.badgeSetting.rawValue)")
                    AnalyticsManager.shared.notificationSettingsChecked(
                        authStatus: authStatus,
                        alertStyle: alertStyleName,
                        soundEnabled: soundEnabled,
                        badgeEnabled: badgeEnabled,
                        bannersDisabled: settings.alertStyle == .none
                    )

                    // Detect regression: was authorized, now reverted to notDetermined
                    // This happens on macOS 26+ where the OS silently revokes notification permission
                    if self.lastNotificationAuthStatus == "authorized" && authStatus == "notDetermined" {
                        log("Notification permission REGRESSED from authorized to notDetermined — triggering auto-repair")
                        AnalyticsManager.shared.notificationRepairTriggered(
                            reason: "auth_regression",
                            previousStatus: "authorized",
                            currentStatus: "notDetermined"
                        )
                        self.repairNotificationRegistrationAndRetry()
                    }

                    // Update last known state
                    self.lastNotificationAuthStatus = authStatus
                    self.lastNotificationAlertStyle = alertStyleName
                    self.lastNotificationSoundEnabled = soundEnabled
                    self.lastNotificationBadgeEnabled = badgeEnabled
                }

            }
        }
    }

    /// Check screen recording permission status
    func checkScreenRecordingPermission() {
        let tccGranted = CGPreflightScreenCaptureAccess()

        if !tccGranted {
            hasScreenRecordingPermission = false
            isScreenCaptureKitBroken = false
            // If user already tried Grant once and permission is still not granted,
            // the TCC entry is likely corrupted (e.g. after developer account change
            // + tccutil reset). Show stale UI with toggle off/on instructions.
            if screenRecordingGrantAttempts > 0 && !isScreenRecordingStale {
                log("Screen capture: Grant attempted but permission still denied — showing recovery instructions")
                isScreenRecordingStale = true
            }
            return
        }

        // TCC says granted. If the permission alert is currently showing (permission was
        // previously false or broken or stale), do a real capture test to verify the stale TCC case
        // (e.g. after developer account change). This avoids spawning a screencapture process
        // on every didBecomeActive when everything is fine.
        if !hasScreenRecordingPermission || isScreenCaptureKitBroken || isScreenRecordingStale {
            let realPermission = ScreenCaptureService.checkPermission()
            hasScreenRecordingPermission = realPermission

            // Stale TCC entry from old developer signing: CGPreflight says granted but
            // actual capture fails. The user must toggle OFF then ON in System Settings
            // to update the code signing requirement (csreq) stored in the TCC database.
            if !realPermission && !isScreenRecordingStale {
                log("Screen capture: stale TCC entry detected (developer signing changed)")
                isScreenRecordingStale = true
                // Try tccutil reset in case it works (it may not on macOS 15+ for system TCC)
                Task.detached {
                    ScreenCaptureService.ensureLaunchServicesRegistrationSync()
                    _ = ScreenCaptureService.resetScreenCapturePermission()
                }
            } else if realPermission {
                // Permission recovered (user toggled off/on in System Settings)
                isScreenRecordingStale = false
                screenRecordingGrantAttempts = 0
            }

            if isScreenCaptureKitBroken {
                // Re-check if SCK has recovered (user toggled permission in System Settings)
                if #available(macOS 14.0, *) {
                    Task {
                        let sckWorks = await ScreenCaptureService.testScreenCaptureKitPermission()
                        if sckWorks {
                            log("AppState: ScreenCaptureKit recovered — clearing broken flag")
                            self.isScreenCaptureKitBroken = false
                            self.hasScreenRecordingPermission = true
                        }
                    }
                }
            }
        } else {
            hasScreenRecordingPermission = true
        }
    }

    /// Track retry state for accessibility broken detection
    private var accessibilityRetryCount = 0
    private var accessibilityRetryTimer: Timer?
    private static let maxAccessibilityRetries = 3
    private static let accessibilityRetryInterval: TimeInterval = 5.0

    /// Check accessibility permission status
    /// AXIsProcessTrusted() can return stale data after macOS updates or app re-signs,
    /// so we also do a functional AX test to detect the "broken" state.
    func checkAccessibilityPermission() {
        let tccGranted = AXIsProcessTrusted()
        let previouslyGranted = hasAccessibilityPermission

        if tccGranted {
            hasAccessibilityPermission = true

            // Log transitions
            if !previouslyGranted {
                let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
                log("ACCESSIBILITY_CHECK: Permission granted (bundleId=\(bundleId))")
            }

            lastAccessibilityApiDisabledLogged = false  // Reset so we log again if it regresses
            // TCC says yes — verify with an actual AX call
            let broken = !testAccessibilityPermission()
            if broken != isAccessibilityBroken {
                isAccessibilityBroken = broken
                if broken {
                    log("ACCESSIBILITY_CHECK: TCC says granted but AX calls fail — stuck/broken state detected")
                    startAccessibilityRetryTimer()
                } else {
                    log("ACCESSIBILITY_CHECK: AX calls working normally")
                    stopAccessibilityRetryTimer()
                }
            }
        } else {
            // AXIsProcessTrusted() says not granted.
            // On macOS 26 the TCC cache can go stale — but only probe via event tap when we
            // previously had permission, to avoid triggering the "prevented from modifying apps"
            // Privacy & Security notification every polling cycle when permission was never granted.
            if previouslyGranted && probeAccessibilityViaEventTap() {
                if !previouslyGranted {
                    log("ACCESSIBILITY_CHECK: AXIsProcessTrusted() returned false but event tap succeeded — stale cache detected")
                }
                let axWorks = testAccessibilityPermission()
                hasAccessibilityPermission = true
                if !axWorks {
                    if !isAccessibilityBroken {
                        log("ACCESSIBILITY_CHECK: Event tap OK but AX calls fail — marking as broken")
                        startAccessibilityRetryTimer()
                    }
                    isAccessibilityBroken = true
                } else {
                    if isAccessibilityBroken {
                        log("ACCESSIBILITY_CHECK: Permission confirmed via event tap probe, AX calls working")
                        stopAccessibilityRetryTimer()
                    }
                    isAccessibilityBroken = false
                }
            } else {
                // Event tap also failed — permission genuinely not granted
                if previouslyGranted {
                    let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
                    log("ACCESSIBILITY_CHECK: Permission revoked (bundleId=\(bundleId))")
                }
                hasAccessibilityPermission = false
                isAccessibilityBroken = false
                stopAccessibilityRetryTimer()
            }
        }
    }

    /// Start a retry timer that re-checks AX permission every 5 seconds.
    /// After 3 failed attempts, shows an alert prompting the user to restart the app.
    private func startAccessibilityRetryTimer() {
        guard accessibilityRetryTimer == nil else { return }
        accessibilityRetryCount = 0
        log("ACCESSIBILITY_CHECK: Starting retry timer (max \(Self.maxAccessibilityRetries) attempts, every \(Self.accessibilityRetryInterval)s)")
        accessibilityRetryTimer = Timer.scheduledTimer(withTimeInterval: Self.accessibilityRetryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.accessibilityRetryCount += 1
                log("ACCESSIBILITY_CHECK: Retry \(self.accessibilityRetryCount)/\(AppState.maxAccessibilityRetries)")

                // Re-check — this will call stopAccessibilityRetryTimer() if it recovers
                self.checkAccessibilityPermission()

                if self.isAccessibilityBroken && self.accessibilityRetryCount >= AppState.maxAccessibilityRetries {
                    log("ACCESSIBILITY_CHECK: All retries exhausted, prompting user to restart")
                    self.stopAccessibilityRetryTimer()
                    self.showAccessibilityRestartAlert()
                }
            }
        }
    }

    private func stopAccessibilityRetryTimer() {
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil
        accessibilityRetryCount = 0
    }

    /// Show an alert asking the user to quit and reopen the app to fix accessibility.
    private func showAccessibilityRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Needs Restart"
        alert.informativeText = "macOS granted accessibility permission but it isn't working yet. Please quit and reopen Fazm to activate it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            log("ACCESSIBILITY_CHECK: User chose Quit & Reopen")
            relaunchApp()
        } else {
            log("ACCESSIBILITY_CHECK: User chose Later")
        }
    }

    /// Relaunch the app by spawning a delayed open command and terminating.
    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1 && open \"\(bundlePath)\""]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }

    /// Test if Accessibility API actually works by attempting a real AX call.
    /// Returns true if AX calls succeed, false if permission is stuck/broken.
    private func testAccessibilityPermission() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            // No frontmost app to test against — can't determine, assume OK
            return true
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        // .success or .noValue (app has no windows) both mean AX is working
        switch result {
        case .success, .noValue, .notImplemented, .attributeUnsupported:
            return true
        case .apiDisabled:
            // System-wide AX is disabled — unambiguous, no confirmation needed
            if !lastAccessibilityApiDisabledLogged {
                log("ACCESSIBILITY_CHECK: AXError.apiDisabled — permission stuck (tested against pid \(frontApp.processIdentifier), app: \(frontApp.localizedName ?? "unknown"))")
                lastAccessibilityApiDisabledLogged = true
            }
            return false
        case .cannotComplete:
            // cannotComplete is ambiguous: it can mean our permission is broken, OR that the
            // frontmost app doesn't implement AX (e.g. Qt, OpenGL, Python-based apps like PyMOL).
            // Confirm against Finder before concluding the permission is truly broken.
            return confirmAccessibilityBrokenViaFinder(suspectApp: frontApp.localizedName ?? "unknown")
        default:
            log("ACCESSIBILITY_CHECK: AXError code \(result.rawValue) from app \(frontApp.localizedName ?? "unknown") — not permission-related, treating as OK")
            return true
        }
    }

    /// Secondary AX check against Finder to disambiguate cannotComplete errors.
    /// If Finder (a known AX-compliant app) also fails, the permission is truly broken.
    /// If Finder succeeds, the original failure was app-specific, not a permission issue.
    private func confirmAccessibilityBrokenViaFinder(suspectApp: String) -> Bool {
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let finderElement = AXUIElementCreateApplication(finder.processIdentifier)
            var finderWindow: CFTypeRef?
            let finderResult = AXUIElementCopyAttributeValue(finderElement, kAXFocusedWindowAttribute as CFString, &finderWindow)
            if finderResult == .cannotComplete || finderResult == .apiDisabled {
                log("ACCESSIBILITY_CHECK: AXError.cannotComplete confirmed by Finder — permission is truly stuck (original app: \(suspectApp))")
                return false
            } else {
                log("ACCESSIBILITY_CHECK: AXError.cannotComplete from \(suspectApp) but Finder OK — app-specific AX incompatibility, permission is fine")
                return true
            }
        } else {
            // Finder not running — fall back to event tap probe as tie-breaker
            log("ACCESSIBILITY_CHECK: AXError.cannotComplete from \(suspectApp), Finder not running — using event tap probe")
            return probeAccessibilityViaEventTap()
        }
    }

    /// Probe accessibility permission by attempting to create a CGEvent tap.
    /// Unlike AXIsProcessTrusted(), event tap creation checks the live TCC database,
    /// bypassing the per-process cache that can go stale on macOS 26 (Tahoe).
    private func probeAccessibilityViaEventTap() -> Bool {
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        if let tap = tap {
            CFMachPortInvalidate(tap)
            return true
        }
        return false
    }

    /// Check if accessibility permission was explicitly denied
    func isAccessibilityPermissionDenied() -> Bool {
        return hasCompletedOnboarding && (!hasAccessibilityPermission || isAccessibilityBroken)
    }

    /// Trigger accessibility permission prompt
    func triggerAccessibilityPermission() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        log("ACCESSIBILITY_TRIGGER: User clicked Grant Access — bundleId=\(bundleId), macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

        // This will prompt the user if not already trusted
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            hasAccessibilityPermission = true
        }
        // Don't set hasAccessibilityPermission = false here — the API may return
        // stale data on macOS 26. Let checkAccessibilityPermission() handle detection
        // via the event tap probe on the next poll cycle.
        log("ACCESSIBILITY_TRIGGER: AXIsProcessTrustedWithOptions returned \(trusted)")

        // On macOS Sequoia+, AXIsProcessTrustedWithOptions no longer shows a visible dialog,
        // so explicitly open System Settings to the Accessibility pane
        if !trusted {
            log("ACCESSIBILITY_TRIGGER: Not trusted, opening System Settings Accessibility pane")
            openAccessibilityPreferences()
        }
    }

    /// Open Accessibility preferences in System Settings
    func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reset accessibility permission (requires terminal command)
    nonisolated func resetAccessibilityPermissionDirect(shouldRestart: Bool = false) -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fazm.app"
        log("Resetting accessibility permission for \(bundleId) via tccutil...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleId]

        do {
            try process.run()
            process.waitUntilExit()
            let success = process.terminationStatus == 0
            log("tccutil reset completed with exit code: \(process.terminationStatus)")

            if success && shouldRestart {
                restartApp()
            }

            return success
        } catch {
            log("Failed to run tccutil: \(error)")
            return false
        }
    }

    /// Reset accessibility permission via tccutil and restart the app.
    /// Mirrors ScreenCaptureService.resetScreenCapturePermissionAndRestart().
    func resetAccessibilityPermissionAndRestart() {
        if UpdaterViewModel.isUpdateInProgress {
            log("Sparkle update in progress, skipping accessibility reset restart")
            return
        }

        Task.detached { [weak self] in
            guard let self = self else { return }
            let success = self.resetAccessibilityPermissionDirect(shouldRestart: false)

            await MainActor.run {
                if success {
                    log("Accessibility permission reset, restarting app...")
                    self.restartApp()
                } else {
                    log("Accessibility permission reset failed")
                }
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = "Screen Recording permission is needed.\n\nClick 'Grant Screen Permission' in the menu, then add this app and restart."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Transcription Stubs (referenced by floating bar, onboarding, settings)

    @Published var isTranscribing = false
    @Published var isSavingConversation = false
    @Published var hasMicrophonePermission = false

    /// Toggle transcription on/off (no-op stub)
    func toggleTranscription() {}
    /// Start transcription (no-op stub)
    func startTranscription(source: AudioSource? = nil) {}
    /// Stop transcription (no-op stub)
    func stopTranscription() {}
    /// Request microphone permission
    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.hasMicrophonePermission = granted
                log("Microphone permission \(granted ? "granted" : "denied")")
            }
        }
    }
    /// Check microphone permission status
    func checkMicrophonePermission() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    /// Check if microphone permission was explicitly denied
    func isMicrophonePermissionDenied() -> Bool {
        return AudioCaptureService.isPermissionDenied()
    }

    // MARK: - Remaining Utilities

    /// Check if screen recording permission is denied (onboarding complete but permission not granted)
    func isScreenRecordingPermissionDenied() -> Bool {
        return hasCompletedOnboarding && !CGPreflightScreenCaptureAccess()
    }

    /// Restart the app by launching a new instance and terminating the current one
    nonisolated func restartApp() {
        if UpdaterViewModel.isUpdateInProgress {
            log("Sparkle update in progress, skipping independent restart (Sparkle will handle relaunch)")
            return
        }

        log("Restarting app...")

        guard let bundleURL = Bundle.main.bundleURL as URL? else {
            log("Failed to get bundle URL for restart")
            return
        }

        // Use a shell script to wait briefly, then relaunch the app
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5 && open \"\(bundleURL.path)\""]

        do {
            try task.run()
            log("Restart scheduled, terminating current instance...")

            // Terminate the current app
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            log("Failed to schedule restart: \(error)")
        }
    }

    /// Reset onboarding state and all TCC permissions, then restart the app
    /// This clears UserDefaults onboarding keys and resets permissions so the user
    /// can go through onboarding again with fresh permission prompts.
    /// Performs thorough cleanup matching reset-and-run.sh behavior.
    nonisolated func resetOnboardingAndRestart() {
        log("Resetting onboarding (full cleanup)...")

        // Clear onboarding-related UserDefaults keys (thread-safe, do first)
        let onboardingKeys = [
            "hasCompletedOnboarding",
            "onboardingStep",
            "hasSeenRewindIntro",
            "hasTriggeredNotification",
            "hasTriggeredScreenRecording",
            "hasTriggeredMicrophone",
            "hasTriggeredSystemAudio",
            "hasTriggeredAccessibility",
            "hasTriggeredBluetooth"
        ]
        for key in onboardingKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
        log("Cleared onboarding UserDefaults keys")

        // Clear mid-onboarding chat persistence (session ID, completed steps, messages)
        OnboardingChatPersistence.clear()
        log("Cleared onboarding chat persistence")

        // Also clear UserDefaults for both bundle IDs
        if let prodDefaults = UserDefaults(suiteName: "com.fazm.app") {
            for key in onboardingKeys {
                prodDefaults.removeObject(forKey: key)
            }
        }
        if let devDefaults = UserDefaults(suiteName: "com.fazm.desktop-dev") {
            for key in onboardingKeys {
                devDefaults.removeObject(forKey: key)
            }
        }

        // Run all blocking Process calls on a background thread
        DispatchQueue.global(qos: .utility).async { [self] in
            // 1. Clean conflicting app bundles from Trash, DerivedData, DMG staging
            cleanConflictingAppBundles()

            // 2. Eject any mounted Fazm DMG volumes
            ejectMountedDMGVolumes()

            // 3. Reset Launch Services database to clear stale registrations
            resetLaunchServicesDatabase()

            // 4. Ensure this app is the authoritative version in Launch Services
            ScreenCaptureService.ensureLaunchServicesRegistration()

            // 5. Reset ALL TCC permissions using tccutil for BOTH bundle IDs
            let bundleIds = [
                "com.omi.computer-macos",       // Production
                "com.omi.desktop-dev"           // Development
            ]

            for id in bundleIds {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", "All", id]

                do {
                    try process.run()
                    process.waitUntilExit()
                    log("tccutil reset All for \(id) completed with exit code: \(process.terminationStatus)")
                } catch {
                    log("Failed to run tccutil for \(id): \(error)")
                }
            }

            // 6. Also clean user TCC database directly via sqlite3
            self.cleanUserTCCDatabase()

            // 7. Restart the app
            self.restartApp()
        }
    }

    /// Clean conflicting app bundles from Trash, DerivedData, and DMG staging directories
    private nonisolated func cleanConflictingAppBundles() {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        // Clean Fazm/Omi apps from Trash (they still pollute Launch Services!)
        let trashPath = "\(homeDir)/.Trash"
        if let contents = try? fileManager.contentsOfDirectory(atPath: trashPath) {
            for item in contents where item.lowercased().contains("fazm") || item.lowercased().contains("omi") {
                let itemPath = "\(trashPath)/\(item)"
                do {
                    try fileManager.removeItem(atPath: itemPath)
                    log("Cleaned from Trash: \(item)")
                } catch {
                    log("Failed to clean from Trash: \(item) - \(error.localizedDescription)")
                }
            }
        }

        // Clean DMG staging directories
        let tmpDir = "/private/tmp"
        if let contents = try? fileManager.contentsOfDirectory(atPath: tmpDir) {
            for item in contents where item.hasPrefix("fazm-dmg-staging") || item.hasPrefix("fazm-dmg-test") || item.hasPrefix("omi-dmg-staging") || item.hasPrefix("omi-dmg-test") {
                let itemPath = "\(tmpDir)/\(item)"
                do {
                    try fileManager.removeItem(atPath: itemPath)
                    log("Cleaned DMG staging: \(item)")
                } catch {
                    log("Failed to clean DMG staging: \(item) - \(error.localizedDescription)")
                }
            }
        }

        // Clean Xcode DerivedData Fazm/Omi builds
        let derivedDataPath = "\(homeDir)/Library/Developer/Xcode/DerivedData"
        if let contents = try? fileManager.contentsOfDirectory(atPath: derivedDataPath) {
            for item in contents where item.lowercased().contains("fazm") || item.lowercased().contains("omi") {
                let buildProductsPath = "\(derivedDataPath)/\(item)/Build/Products"
                if let buildDirs = try? fileManager.contentsOfDirectory(atPath: buildProductsPath) {
                    for buildDir in buildDirs {
                        let appPath = "\(buildProductsPath)/\(buildDir)/Fazm.app"
                        let appPath2 = "\(buildProductsPath)/\(buildDir)/Fazm Dev.app"
                        let appPath3 = "\(buildProductsPath)/\(buildDir)/Omi.app"
                        let appPath4 = "\(buildProductsPath)/\(buildDir)/Omi Computer.app"
                        for path in [appPath, appPath2, appPath3, appPath4] {
                            if fileManager.fileExists(atPath: path) {
                                do {
                                    try fileManager.removeItem(atPath: path)
                                    log("Cleaned DerivedData: \(path)")
                                } catch {
                                    log("Failed to clean DerivedData: \(path) - \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Eject any mounted Fazm/Omi DMG volumes
    private nonisolated func ejectMountedDMGVolumes() {
        let fileManager = FileManager.default
        let volumesPath = "/Volumes"

        guard let contents = try? fileManager.contentsOfDirectory(atPath: volumesPath) else { return }

        for volume in contents where volume.lowercased().contains("fazm") || volume.lowercased().contains("omi") || volume.hasPrefix("dmg.") {
            let volumePath = "\(volumesPath)/\(volume)"

            // Try diskutil eject first
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["eject", volumePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    log("Ejected volume: \(volume)")
                } else {
                    // Try hdiutil detach as fallback
                    let detachProcess = Process()
                    detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detachProcess.arguments = ["detach", volumePath]
                    detachProcess.standardOutput = FileHandle.nullDevice
                    detachProcess.standardError = FileHandle.nullDevice
                    try? detachProcess.run()
                    detachProcess.waitUntilExit()
                }
            } catch {
                log("Failed to eject volume: \(volume) - \(error.localizedDescription)")
            }
        }
    }

    /// Reset Launch Services database to clear stale app registrations
    private nonisolated func resetLaunchServicesDatabase() {
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-kill", "-r", "-domain", "local", "-domain", "user"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            log("Launch Services database reset (exit code: \(process.terminationStatus))")
        } catch {
            log("Failed to reset Launch Services: \(error.localizedDescription)")
        }
    }

    /// Clean user TCC database entries for Fazm/Omi apps
    private nonisolated func cleanUserTCCDatabase() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let tccDbPath = "\(homeDir)/Library/Application Support/com.apple.TCC/TCC.db"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [tccDbPath, "DELETE FROM access WHERE client LIKE '%com.fazm.app%' OR client LIKE '%com.omi.computer-macos%';"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            log("User TCC database cleaned (exit code: \(process.terminationStatus))")
        } catch {
            log("Failed to clean user TCC database: \(error.localizedDescription)")
        }

        // Also clean entries for dev bundle IDs
        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process2.arguments = [tccDbPath, "DELETE FROM access WHERE client LIKE '%com.fazm.desktop%' OR client LIKE '%com.omi.desktop%';"]
        process2.standardOutput = FileHandle.nullDevice
        process2.standardError = FileHandle.nullDevice

        do {
            try process2.run()
            process2.waitUntilExit()
            log("User TCC database cleaned for desktop-dev (exit code: \(process2.terminationStatus))")
        } catch {
            log("Failed to clean user TCC database for desktop-dev: \(error.localizedDescription)")
        }
    }

    /// Reset microphone permission using tccutil (Option 1: Direct)
    /// Returns true if the reset command was executed successfully
    /// If shouldRestart is true, the app will restart after reset
    nonisolated func resetMicrophonePermissionDirect(shouldRestart: Bool = false) -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fazm.app"
        log("Resetting microphone permission for \(bundleId) via tccutil...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Microphone", bundleId]

        do {
            try process.run()
            process.waitUntilExit()
            let success = process.terminationStatus == 0
            log("tccutil reset completed with exit code: \(process.terminationStatus)")

            if success && shouldRestart {
                restartApp()
            }

            return success
        } catch {
            log("Failed to run tccutil: \(error)")
            return false
        }
    }

    /// Reset microphone permission via Terminal (Option 2: Visible to user)
    /// If shouldRestart is true, the app will restart after the terminal command
    func resetMicrophonePermissionViaTerminal(shouldRestart: Bool = false) {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fazm.app"
        let appPath = Bundle.main.bundleURL.path
        log("Opening Terminal to reset microphone permission for \(bundleId)...")

        // Build the shell command - escape single quotes in path for shell
        let escapedPath = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let restartCommand = shouldRestart ? " && open '\(escapedPath)'" : ""
        let shellCommand = "tccutil reset Microphone \(bundleId) && echo 'Done! Permission reset.'\(restartCommand)"

        // AppleScript to open Terminal and run the command
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(shellCommand)\"\nend tell"

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                log("AppleScript error: \(error)")
            } else if shouldRestart {
                // Terminate current app after terminal script is running
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

}

// MARK: - System Event Notification Names

extension Notification.Name {
    /// Posted when the system wakes from sleep
    static let systemDidWake = Notification.Name("systemDidWake")
    /// Posted when the screen is locked
    static let screenDidLock = Notification.Name("screenDidLock")
    /// Posted when the screen is unlocked
    static let screenDidUnlock = Notification.Name("screenDidUnlock")
    /// Posted when screen capture permission is detected as lost
    static let screenCapturePermissionLost = Notification.Name("screenCapturePermissionLost")
    /// Posted when ScreenCaptureKit is broken (TCC granted but SCK declined)
    static let screenCaptureKitBroken = Notification.Name("screenCaptureKitBroken")
    /// Posted to navigate to Rewind page (global hotkey: Cmd+Option+R)
    static let navigateToRewind = Notification.Name("navigateToRewind")
    /// Posted to navigate to Ask Fazm Floating Bar settings
    static let navigateToFloatingBarSettings = Notification.Name("navigateToFloatingBarSettings")
    /// Posted to navigate to AI Chat settings
    static let navigateToAIChatSettings = Notification.Name("navigateToAIChatSettings")
    /// Posted when a new Rewind frame is captured (for live frame count updates)
    static let rewindFrameCaptured = Notification.Name("rewindFrameCaptured")
    /// Posted when Rewind page finishes loading initial data
    static let rewindPageDidLoad = Notification.Name("rewindPageDidLoad")
    /// Posted to navigate to AI Chat page
    static let navigateToChat = Notification.Name("navigateToChat")
    /// Posted to navigate to Task Assistant settings (Developer Settings)
    static let navigateToTaskSettings = Notification.Name("navigateToTaskSettings")
    /// Posted from Settings to trigger the file indexing sheet
    static let triggerFileIndexing = Notification.Name("triggerFileIndexing")
}
