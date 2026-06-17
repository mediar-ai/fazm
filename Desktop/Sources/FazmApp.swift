import SwiftUI
import Sentry
import Sparkle
import FirebaseCore

// MARK: - Sentry Noise Guard
/// Suppresses runaway-loop Sentry events (e.g. GRDB on a corrupted DB firing thousands of
/// identical errors per session). Allows the first N captures per fingerprint per process,
/// then drops the rest. Resets on relaunch — a real recurring issue still surfaces daily.
enum SentryNoiseGuard {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    private static let maxPerFingerprint = 3

    /// Returns a fingerprint for events known to fire in tight loops. nil = not gated.
    static func fingerprint(for event: Event, message: String) -> String? {
        if let exceptions = event.exceptions {
            for exc in exceptions {
                if exc.type.hasPrefix("GRDB.DatabaseError") {
                    if exc.value.contains("SQLite error 11") { return "grdb-malformed" }
                    if exc.value.contains("SQLite error 10") { return "grdb-disk-io" }
                    if exc.value.contains("SQLite error 19") { return "grdb-constraint" }
                    return "grdb-other"
                }
            }
        }
        if message.contains("consecutive I/O errors") { return "rewind-io-loop" }
        return nil
    }

    static func shouldCapture(fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let n = (counts[fingerprint] ?? 0) + 1
        counts[fingerprint] = n
        return n <= maxPerFingerprint
    }
}

// MARK: - Launch Mode
/// Determines which UI to show based on command-line arguments
enum LaunchMode: String {
    case full = "full"       // Normal app with full sidebar
    case rewind = "rewind"   // Rewind-only mode (no sidebar)

    static func fromCommandLine() -> LaunchMode {
        // Check for --mode=rewind argument
        for arg in CommandLine.arguments {
            if arg == "--mode=rewind" {
                NSLog("Fazm LaunchMode: Detected rewind mode from command line")
                return .rewind
            }
        }
        return .full
    }
}

// MARK: - Dev Flags
/// Check for --skip-onboarding flag to bypass onboarding during development
func shouldSkipOnboarding() -> Bool {
    return CommandLine.arguments.contains("--skip-onboarding")
}

// Auth state — backed by Firebase Auth via AuthService
@MainActor
class AuthState: ObservableObject {
    static let shared = AuthState()

    // UserDefaults keys
    private static let kAuthUserEmail = "auth_userEmail"
    private static let kAuthUserId = "auth_tokenUserId"
    private static let kAuthIsSignedIn = "auth_isSignedIn"
    private static let kAuthIsAnonymous = "auth_isAnonymous"

    @Published var isSignedIn: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var userEmail: String?
    /// True when the current Firebase user was created via signInAnonymously.
    /// Drives UI branches: the paywall shows a "Sign in to subscribe" step
    /// instead of going straight to Stripe, and Settings shows a "Save your
    /// account" row so anon users can upgrade outside the paywall.
    @Published var isAnonymous: Bool = false

    private init() {
        // Restore from UserDefaults — AuthService.configure() will update these
        let savedSignedIn = UserDefaults.standard.bool(forKey: Self.kAuthIsSignedIn)
        self.isSignedIn = savedSignedIn
        self.userEmail = UserDefaults.standard.string(forKey: Self.kAuthUserEmail)
        self.isAnonymous = UserDefaults.standard.bool(forKey: Self.kAuthIsAnonymous)

        NSLog("FazmApp AuthState: Initialized, savedSignedIn=%@, isAnonymous=%@, email=%@, userId=%@",
              savedSignedIn ? "true" : "false",
              self.isAnonymous ? "true" : "false",
              self.userEmail ?? "nil",
              UserDefaults.standard.string(forKey: Self.kAuthUserId) ?? "nil")
    }

    func update(isSignedIn: Bool, userEmail: String? = nil, isAnonymous: Bool = false) {
        self.isSignedIn = isSignedIn
        UserDefaults.standard.set(isSignedIn, forKey: Self.kAuthIsSignedIn)
        if let email = userEmail {
            self.userEmail = email
        }
        self.isAnonymous = isAnonymous
        UserDefaults.standard.set(isAnonymous, forKey: Self.kAuthIsAnonymous)
    }

    /// Get the user's UID from UserDefaults (set by AuthService on sign-in)
    var userId: String? {
        UserDefaults.standard.string(forKey: Self.kAuthUserId)
    }
}

/// Stores SwiftUI's `openWindow` action so AppDelegate can reopen the settings window.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openWindow: OpenWindowAction?
}

@main
struct FazmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    /// Launch mode determined at startup from command-line arguments
    static let launchMode = LaunchMode.fromCommandLine()

    /// Window title with version number (different for rewind mode)
    private var windowTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Fazm"
        let baseName = Self.launchMode == .rewind ? "Fazm Rewind" : displayName
        return version.isEmpty ? baseName : "\(baseName) v\(version)"
    }

    /// Window size based on launch mode
    private var defaultWindowSize: CGSize {
        Self.launchMode == .rewind ? CGSize(width: 1000, height: 700) : CGSize(width: 1200, height: 800)
    }

    var body: some Scene {
        // Main desktop window — auth gate is inside DesktopHomeView (not here)
        // to avoid AttributeGraph crashes from view hierarchy swaps at the Scene level.
        Window(windowTitle, id: "main") {
            DesktopHomeView()
                .withFontScaling()
                .trackWindowVisibility()
                .onAppear {
                    log("FazmApp: Main window content appeared (mode: \(Self.launchMode.rawValue))")
                }
                .task {
                    // Store openWindow action globally so AppDelegate can reopen the window
                    WindowOpener.shared.openWindow = openWindow
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        // Menu commands (font size, help) are managed via AppDelegate.setupAppMenus()
        // instead of SwiftUI .commands {} to avoid AttributeGraph crashes during menu rendering.
        // SwiftUI's menu rendering re-evaluates the entire scene view graph, and if any @Published
        // state mutation is in flight (e.g. ViewModelContainer init), AG::Graph::value_set crashes.

        // Note: Menu bar is now handled by NSStatusBar in AppDelegate.setupMenuBar()
        // for better reliability on macOS Sequoia (SwiftUI MenuBarExtra had rendering issues)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var sentryHeartbeatTimer: Timer?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var statusBarItem: NSStatusItem?
    private var toggleBarObserver: NSObjectProtocol?
    private var newPopOutChatObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single-instance lock for production. If another prod Fazm is running,
        // this hands off focus and exits BEFORE we touch SQLite, the ACP bridge,
        // or the global hotkey monitor (all of which break under concurrent use).
        // Dev builds skip the check so multiple dev instances can coexist.
        InstanceLock.acquireOrHandoff()

        // Crash-loop detection must run before ANY other init.
        // If 3+ rapid crashes are detected, this will restore the previous version and terminate.
        UpdateRollbackManager.checkForCrashLoop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE so broken-pipe writes return errors instead of crashing the app.
        // Without this, writing to a dead FFmpeg stdin or agent-bridge pipe kills the process.
        signal(SIGPIPE, SIG_IGN)

        // Log uncaught NSExceptions to fazm.log + Sentry. The .ips report omits the reason
        // string, so when AppKit throws (e.g. _postWindowNeedsUpdateConstraints during a
        // SwiftUI representable update on a torn-down window) we previously had no signal.
        // 2026-05-21 prod crash repro: 5+ streaming popouts + context compaction.
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "<nil>"
            let stack = exception.callStackSymbols.joined(separator: "\n")
            log("FATAL NSException [\(name)]: \(reason)\n\(stack)")
            SentrySDK.capture(exception: exception)
        }

        // Seed UserDefaults defaults for keys whose SwiftUI `@AppStorage` default is `true`.
        // `@AppStorage` only supplies the fallback inside the property wrapper; raw
        // `UserDefaults.standard.bool(forKey:)` returns `false` until the key is written.
        // On fresh install this caused the ACP bridge to launch with FAZM_VOICE_RESPONSE
        // unset, so the `speak_response` MCP tool was never registered and voice stayed silent.
        UserDefaults.standard.register(defaults: [
            "voiceResponseEnabled": true,
        ])

        // Disable App Nap — the floating bar relies on global event monitors and timers
        // that stop firing when macOS naps the process.
        ProcessInfo.processInfo.disableAutomaticTermination("Floating bar active")
        ProcessInfo.processInfo.disableSuddenTermination()
        _ = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Push-to-talk event monitors must stay active"
        )

        // FAZM-20 mitigation: disable AppKit auto touch bar + window tabbing globally.
        // Crash signature is EXC_BAD_ACCESS in NSConcreteMapTable dealloc inside the
        // NSTouchBarFinder update path. Fazm has no TouchBar code; the heavy
        // floating-bar/popout window churn is hitting an AppKit weak-ref bug.
        NSWindow.applyAppGlobalCrashWorkarounds()

        // Configure Firebase and AuthService
        AuthService.shared.configure()

        // Initialize subscription service early to fetch account creation date
        _ = SubscriptionService.shared

        log("AppDelegate: applicationDidFinishLaunching started (mode: \(FazmApp.launchMode.rawValue))")
        log("AppDelegate: AuthState.isSignedIn=\(AuthState.shared.isSignedIn)")

        // Cap URLCache.shared. The default macOS cap (~512 MB disk + ~20 MB memory) lets
        // CFNetwork dirty multi-GB of file-backed memory writing to ~/Library/Caches/com.fazm.app/Cache.db,
        // which trips the OS disk-write resource limit (`Action taken: none` warnings in
        // /Library/Logs/DiagnosticReports/Fazm_*.diag — heaviest stack is __CFURLCache::CreateAndStoreCacheNode).
        // 50 MB disk / 16 MB memory is enough for normal HTTP caching and keeps us well under any limit.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity:   50 * 1024 * 1024,
                                   diskPath: nil)

        // Clean Python __pycache__ directories left inside the bundle by older builds.
        // Future invocations honor PYTHONDONTWRITEBYTECODE/PYTHONPYCACHEPREFIX (set in
        // ChatPrompts.bundledPythonPath and acp-bridge), but already-installed bundles still
        // carry the .pyc files that broke the code-signing seal.
        Self.cleanBundledPycaches()

        // Apply user's appearance preference (light/dark/system)
        AppearanceManager.shared.applyAppearance()

        // Force macOS to use the correct app icon (bypasses icon cache).
        // Apply squircle mask with proper margins because NSApp.applicationIconImage
        // renders the raw image without macOS auto-masking.
        // Do NOT call NSWorkspace.setIcon(forFile:) — it writes a resource fork onto
        // the .app bundle, which breaks the code signature and prevents Sparkle
        // auto-updates from working ("An error occurred while running the updater").
        if let iconURL = Bundle.resourceBundle.url(forResource: "fazm_app_icon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            let size = icon.size
            let maskedIcon = NSImage(size: size)
            maskedIcon.lockFocus()
            // Scale content to ~88% with 6% margin on each side (matches macOS Dock icon sizing)
            let margin = size.width * 0.06
            let contentRect = NSRect(x: margin, y: margin,
                                     width: size.width - margin * 2,
                                     height: size.height - margin * 2)
            // Corner radius ≈ 22.37% of content size
            let radius = contentRect.width * 0.2237
            let path = NSBezierPath(roundedRect: contentRect, xRadius: radius, yRadius: radius)
            path.addClip()
            icon.draw(in: contentRect)
            maskedIcon.unlockFocus()
            NSApp.applicationIconImage = maskedIcon
            if let cfURL = Bundle.main.bundleURL as CFURL? {
                LSRegisterURL(cfURL, true)
            }
            log("AppDelegate: Set application icon with squircle mask")
        }

        // One-time icon cache reset: forces macOS to pick up the new squircle icon.
        // Without this, users who had the old square icon see it cached indefinitely
        // in the Dock, notifications, and Sparkle updater.
        resetIconCacheIfNeeded()

        // Initialize Sparkle auto-updater early so the 10-minute check timer starts at launch
        // Without this, the updater only starts when the user opens Settings or clicks "Check for Updates"
        _ = UpdaterViewModel.shared

        // Initialize Sentry for crash reporting and error tracking (including dev builds)
        let isDev = AnalyticsManager.isDevBuild
        SentrySDK.start { options in
            options.dsn = "https://47b23bc65deb3c58b0c7314e7b648110@o4507617161314304.ingest.us.sentry.io/4510989741326336"
            options.debug = false
            options.enableAutoSessionTracking = true
            options.environment = isDev ? "development" : "production"
            // Disable automatic HTTP client error capture — the SDK creates noisy events
            // for every 4xx/5xx response (e.g. Cloud Run 503 cold starts on /v1/crisp/unread).
            // App code already handles HTTP errors and reports meaningful ones explicitly.
            options.enableCaptureFailedRequests = false
            options.maxBreadcrumbs = 1000
            // Filter noisy breadcrumbs that fill up the buffer with useless data
            options.beforeBreadcrumb = { breadcrumb in
                let msg = breadcrumb.message ?? ""
                // ResourceMonitor fires every 30s — 86% of all breadcrumbs
                if msg.contains("ResourceMonitor:") { return nil }
                // PostHog/Sentry heartbeats every 60s
                if msg.contains("session_heartbeat") || msg.contains("Session Heartbeat") { return nil }
                // Session recording flag checks every 5min
                if msg.contains("session-recording-enabled") { return nil }
                // Empty HTTP breadcrumbs (auto-captured, no useful info)
                if breadcrumb.category == "http" && msg.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
                return breadcrumb
            }
            options.beforeSend = { event in
                // Allow user feedback through from all builds (dev + prod)
                if event.message?.formatted.hasPrefix("User Report") == true { return event }
                // Never send other events from dev builds — they pollute production Sentry data
                if isDev { return nil }
                // Filter out HTTP errors targeting the dev tunnel — noise when the tunnel is down
                if let urlTag = event.tags?["url"], urlTag.contains("m13v.com") {
                    return nil
                }
                // Filter out NSURLErrorCancelled (-999) — these are intentional cancellations
                // (e.g. proactive assistants cancelling in-flight Gemini requests on context switch)
                if let exceptions = event.exceptions, exceptions.contains(where: { exc in
                    exc.type == "NSURLErrorDomain" && exc.value.contains("Code=-999") ||
                    exc.type == "NSURLErrorDomain" && exc.value.contains("Code: -999")
                }) {
                    return nil
                }
                // Filter out AuthError.notSignedIn — this is thrown when token refresh transiently
                // fails (network blip, expired token mid-refresh). The user is still signed in per
                // UserDefaults; the 30s refresh timer will retry. Not actionable as a Sentry error.
                if let exceptions = event.exceptions, exceptions.contains(where: { exc in
                    exc.type == "Fazm.AuthError" && exc.value.contains("notSignedIn")
                }) {
                    return nil
                }
                let msg = event.message?.formatted ?? ""
                // AuthService token-refresh retry loop fires every ~12s for users with bad refresh
                // tokens — 5 users generated 104k events in 14 days (95% of all error volume).
                // The permanent-failure branch already signs out and is captured separately.
                if msg.contains("AuthService: Token refresh failed") { return nil }
                // Session Heartbeat is a breadcrumb category, not an error condition.
                if msg.hasPrefix("Session Heartbeat") { return nil }
                // GRDB SQLite corruption / I/O errors retry forever from inside the DB layer.
                // Capture once per process per fingerprint so we still see the issue without
                // burning the entire error quota on one user's broken disk.
                let fp = SentryNoiseGuard.fingerprint(for: event, message: msg)
                if let fp = fp, !SentryNoiseGuard.shouldCapture(fingerprint: fp) {
                    return nil
                }
                return event
            }
        }
        log("Sentry initialized (environment: \(isDev ? "development" : "production"))")

        // Log code signature and install origin for KERN_CODESIGN_ERROR debugging
        logCodeSignatureStatus()

        // Initialize analytics (MixPanel + PostHog)
        AnalyticsManager.shared.initialize()
        AnalyticsManager.shared.appLaunched()
        AnalyticsManager.shared.trackDisplayInfo()

        AnalyticsManager.shared.trackFirstLaunchIfNeeded()

        // Download A/B test attribution: the website writes "fazm:vid=<id>" to
        // the clipboard when the user clicks the direct-download CTA (treatment
        // arm). Read it exactly once per install so PostHog can stitch this
        // anonymous device to the signup that follows. Treatment-arm users
        // never give their email on the site, so without this handoff the
        // paid-conversion attribution for that arm is blind.
        if !UserDefaults.standard.bool(forKey: "didCaptureVisitorIdFromClipboard") {
            UserDefaults.standard.set(true, forKey: "didCaptureVisitorIdFromClipboard")
            if let pasted = NSPasteboard.general.string(forType: .string),
               pasted.hasPrefix("fazm:vid=") {
                let vid = String(pasted.dropFirst("fazm:vid=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let isValid = vid.count >= 8 && vid.count <= 64 &&
                    vid.allSatisfy { $0.isLetter || $0.isNumber }
                if isValid {
                    log("FazmApp: Captured visitor_id=\(vid) from clipboard")
                    PostHogManager.shared.setUserProperty(key: "visitor_id", value: vid)
                    NSPasteboard.general.clearContents()
                }
            }
        }

        // Set per-user database path before any async tasks can trigger DB initialization.
        // This is synchronous and must happen before TierManager / TranscriptionRetryService.
        let userId = UserDefaults.standard.string(forKey: "auth_tokenUserId")
        AppDatabase.currentUserId = (userId?.isEmpty == false) ? userId : "anonymous"

        // Start resource monitoring (memory, CPU, disk)
        ResourceMonitor.shared.start()

        // Start the in-app routine scheduler. This is what actually fires user routines
        // (cron_jobs) on end-user machines — every 60s it spawns cron-runner.mjs for due
        // jobs while the app runs. Without it, routines save to the DB but never execute
        // (the only other scheduler is a dev-machine launchd job).
        RoutineScheduler.shared.start()

        // Identify analytics
        AnalyticsManager.shared.identify()
        AnalyticsManager.shared.reportAllSettingsIfNeeded()

        // Re-identify authenticated user with PostHog now that the SDK is initialized.
        // restoreAuthState() (called at line 170, before PostHog initializes) calls
        // setPostHogUserContext() too early — PostHogManager silently drops it.
        // Calling it here ensures email/firebase_uid are linked to the device UUID.
        AuthService.shared.setPostHogUserContext()

        // Reclaim disk from stale recordings left by prior launches (failed uploads,
        // empty shells from --version probes / run.sh rebuilds, observer originals
        // from before the moveItem fix). Runs async on a background queue, so it
        // does not block startup. Skips dirs touched in the last 5 minutes to avoid
        // the active recorder's session.
        SessionRecordingManager.cleanupStaleRecordings()

        // EXPERIMENT 2026-05-28: disable session recording + screen observer.
        // Sample of prod 2.9.47 showed thread-0/5/10 all near 100% CPU and the
        // ACPBridge being OOM-killed; the dominant Fazm symbols across threads
        // were `SessionRecorder.captureFrame` / `ScreenCaptureService.captureActiveWindow`
        // / `VideoChunkEncoder.writeFrame`. Memory file
        // `bug_fazm_screen_observer_tcc_dialog.md` flags the always-on
        // observer as unfixed: it runs unconditionally and burns 7×/sec
        // SCShareableContent calls. Disabling both calls as the experiment
        // to confirm this is the root cause of the chat-window lag.
        // If responsive, restore behind a UserDefaults opt-in gate.
        if UserDefaults.standard.bool(forKey: "fazm_enable_session_recording_2028") {
            SessionRecordingManager.shared.startIfEnabled()
            SessionRecordingManager.shared.startScreenObserver()
        } else {
            log("SessionRecording: DISABLED at startup (experiment; set UserDefault 'fazm_enable_session_recording_2028' to re-enable)")
        }

        // Test trigger: show session recording permission prompt.
        // Legacy: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testSessionRecordingPermission"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        // Bundle-scoped: replace `com.fazm.testSessionRecordingPermission` with `com.fazm.desktop-dev.testSessionRecordingPermission` (dev) or `com.fazm.app.testSessionRecordingPermission` (prod).
        DistributedNotificationCenter.default().addFazmObserver(
            "testSessionRecordingPermission"
        ) { _ in
            SessionRecordingPermissionWindowController.shared.showForTesting()
        }

        // Test trigger: re-enter onboarding without signing out or resetting permissions.
        // Lightweight reset — keeps sign-in + permissions, just flips hasCompletedOnboarding
        // and clears persisted onboarding chat state so the user sees OnboardingView again.
        // Legacy: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testOnboarding"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        // Bundle-scoped: replace `com.fazm.testOnboarding` with `com.fazm.desktop-dev.testOnboarding` (dev) or `com.fazm.app.testOnboarding` (prod).
        DistributedNotificationCenter.default().addFazmObserver(
            "testOnboarding"
        ) { _ in
            Task { @MainActor in
                log("FazmApp: testOnboarding triggered — resetting hasCompletedOnboarding")
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                UserDefaults.standard.removeObject(forKey: "onboardingWasSkipped")
                OnboardingChatPersistence.clear()
                // Bring the main Fazm window to the front so the user actually sees it.
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        // Test trigger: open the founder chat sheet inside onboarding.
        // The distributed notification is registered here once at launch; it
        // rebroadcasts as a local NotificationCenter event that OnboardingView
        // observes via .onReceive (avoids leaking an observer per OnboardingView mount).
        // Legacy: xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.openFounderChatInOnboarding"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
        // Bundle-scoped: replace `com.fazm.openFounderChatInOnboarding` with `com.fazm.desktop-dev.openFounderChatInOnboarding` (dev) or `com.fazm.app.openFounderChatInOnboarding` (prod).
        DistributedNotificationCenter.default().addFazmObserver(
            "openFounderChatInOnboarding"
        ) { _ in
            Task { @MainActor in
                log("FazmApp: openFounderChatInOnboarding triggered")
                NotificationCenter.default.post(name: .openFounderChatInOnboarding, object: nil)
            }
        }

        // One-time migration: Switch existing users from personal OAuth to bundled built-in
        migrateBridgeModeToBuiltin()

        // One-time migration: Enable launch at login for existing users who haven't set it
        migrateLaunchAtLoginDefault()

        // Pre-set browser profile flag if user already has extraction data
        BrowserProfileMigrationManager.shared.markCompleteIfAlreadyExtracted()

        // Install any newly-bundled skills that existing users don't have yet.
        // `install()` is a no-op for skills already on disk — safe to call every launch.
        // Skipped for users mid-onboarding; the onboarding flow handles initial install.
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            DispatchQueue.global(qos: .utility).async {
                let result = SkillInstaller.install()
                log("AppDelegate: SkillInstaller on launch: \(result)")
                SkillInstaller.checkNpmSkillUpdates()
            }
        }

        // Track launch at login status once per app launch
        Task { @MainActor in
            let isEnabled = LaunchAtLoginManager.shared.isEnabled
            AnalyticsManager.shared.launchAtLoginStatusChecked(enabled: isEnabled)
        }

        // Register for Apple Events to handle URL scheme (e.g. deep links)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Register global hotkey for Rewind (Cmd+Shift+Space)
        setupGlobalHotkeys()

        // Register Carbon-based global shortcuts for floating control bar (Cmd+\)
        GlobalShortcutManager.shared.registerShortcuts()
        toggleBarObserver = NotificationCenter.default.addObserver(
            forName: GlobalShortcutManager.toggleFloatingBarNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                FloatingControlBarManager.shared.toggle()
            }
        }

        newPopOutChatObserver = NotificationCenter.default.addObserver(
            forName: GlobalShortcutManager.newPopOutChatNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                FloatingControlBarManager.shared.popOutNewChat()
            }
        }

        // Ensure app always shows in dock as a regular app
        NSApp.setActivationPolicy(.regular)

        // Set up app menus (Format, Help) via AppKit instead of SwiftUI .commands {}
        // to avoid AttributeGraph crashes during menu rendering.
        setupAppMenus()
        // SwiftUI rebuilds the app menu dynamically, so we inject "Settings…" via delegate
        DispatchQueue.main.async { [weak self] in
            if let appMenu = NSApp.mainMenu?.items.first?.submenu {
                appMenu.delegate = self
            }
        }

        // Cmd+, to open settings — local monitor catches it even when no window is open
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
                Task { @MainActor in self?.openFazmFromMenu() }
                return nil // consume the event
            }
            return event
        }

        // Set up menu bar icon with NSStatusBar (more reliable than SwiftUI MenuBarExtra)
        // Called synchronously on main thread to ensure status item is created before app finishes launching
        Task { @MainActor in
            self.setupMenuBar()
        }

        // Periodic health check: verify menu bar icon is still visible every 30 seconds.
        // Safety net for any edge case (macOS Sequoia bugs, activation policy races) that
        // causes the status bar item to vanish while the process keeps running.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let item = self.statusBarItem
                let button = item?.button
                let isPhantom = button != nil && button!.frame.width == 0
                if item?.isVisible != true || button == nil || isPhantom {
                    log("AppDelegate: [MENUBAR] Health check: icon missing or phantom (visible=\(item?.isVisible ?? false), button=\(button != nil), frame=\(button?.frame ?? .zero)), recreating")
                    self.setupMenuBar()
                }
            }
        }

        // Start Sentry heartbeat timer (every 5 minutes) to capture breadcrumbs periodically
        startSentryHeartbeat()

        // Start PostHog session heartbeat (every 60s) for session duration tracking
        AnalyticsManager.shared.startSessionHeartbeat()

        // Activate app and show main window after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            log("AppDelegate: Checking windows after 0.2s delay, count=\(NSApp.windows.count)")
            NSApp.activate(ignoringOtherApps: true)
            var foundFazmWindow = false
            for window in NSApp.windows {
                log("AppDelegate: Window title='\(window.title)', isVisible=\(window.isVisible)")
                if window.title.hasPrefix("Fazm") {
                    foundFazmWindow = true
                    window.makeKeyAndOrderFront(nil)
                    // Ensure fullscreen always creates a dedicated Space
                    window.collectionBehavior.insert(.fullScreenPrimary)
                    log("AppDelegate: Main window shown on launch")
                }
            }
            if !foundFazmWindow {
                log("AppDelegate: WARNING - 'Fazm' window not found!")
            }
        }

        // Clean up old screenshots in the background
        Task.detached { ScreenCaptureManager.cleanupOldScreenshots() }

        // Mark successful launch — resets the crash-loop counter.
        // Must be at the END of applicationDidFinishLaunching so that crashes during
        // any of the above init still count toward the crash-loop threshold.
        UpdateRollbackManager.markSuccessfulLaunch()

        // If we just rolled back from a bad update, show a notification and track analytics.
        UpdateRollbackManager.handlePostRollbackIfNeeded()

        log("AppDelegate: applicationDidFinishLaunching completed")
    }

    /// Start a timer that sends Sentry session snapshots every 5 minutes
    /// This ensures we have breadcrumbs captured even without errors
    private func startSentryHeartbeat() {
        // Now runs in dev builds too since Sentry is always initialized.
        // Only add breadcrumbs (no event) — sending events every 5 min wastes Sentry quota
        // and drowns out real issues (was 3500+ events/week).
        sentryHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            let crumb = Breadcrumb(level: .info, category: "heartbeat")
            crumb.message = "Session Heartbeat"
            SentrySDK.addBreadcrumb(crumb)
            log("Sentry: Session heartbeat captured")
        }
    }


    /// Removes Python __pycache__ directories from the bundled google-workspace-mcp venv.
    /// Bytecode files written next to imported sources break the bundle's code-signing seal
    /// (codesign verify=FAILED → "a sealed resource is missing or invalid"), which interferes
    /// with Sparkle and notarization-aware paths. Runs async on a utility queue so it never
    /// blocks launch; failures are silent (e.g. no write access to /Applications).
    static func cleanBundledPycaches() {
        // Every bundled Python venv can have runtime-written __pycache__ left over from a
        // pre-fix build. Any one of them breaks the bundle's code-signing seal and the broken
        // seal survives Sparkle updates, so we must scan ALL of them, not just google-workspace-mcp.
        // (browser-harness + ai-browser-profile venvs were added to the bundle in e59009f2.)
        let resources = Bundle.main.bundlePath + "/Contents/Resources"
        let venvRoots = [
            resources + "/google-workspace-mcp/.venv",
            resources + "/browser-harness/.venv",
            resources + "/ai-browser-profile/.venv",
        ]
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            var removed = 0
            for venvRoot in venvRoots {
                guard fm.fileExists(atPath: venvRoot),
                      let enumerator = fm.enumerator(atPath: venvRoot) else { continue }
                var dirs: [String] = []
                for case let relPath as String in enumerator where (relPath as NSString).lastPathComponent == "__pycache__" {
                    dirs.append(venvRoot + "/" + relPath)
                }
                for path in dirs {
                    if (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
                }
            }
            if removed > 0 {
                NSLog("AppDelegate: cleaned %d __pycache__ dir(s) from bundle to restore code-signing seal", removed)
            }
        }
    }

    /// One-time icon cache reset to force macOS to pick up the new squircle icon.
    /// Runs lsregister unregister/register + kills iconservicesagent (auto-restarts).
    /// Includes a safety net to restart the Dock if it crashes during the reset.
    private func resetIconCacheIfNeeded() {
        let key = "hasResetIconCache_v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        log("AppDelegate: Running one-time icon cache reset")

        let appPath = Bundle.main.bundlePath
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

        DispatchQueue.global(qos: .utility).async {
            // Unregister to clear stale icon entries
            let unregister = Process()
            unregister.executableURL = URL(fileURLWithPath: lsregister)
            unregister.arguments = ["-u", appPath]
            unregister.standardOutput = FileHandle.nullDevice
            unregister.standardError = FileHandle.nullDevice
            try? unregister.run()
            unregister.waitUntilExit()

            // Force re-register with updated icon
            let register = Process()
            register.executableURL = URL(fileURLWithPath: lsregister)
            register.arguments = ["-f", appPath]
            register.standardOutput = FileHandle.nullDevice
            register.standardError = FileHandle.nullDevice
            try? register.run()
            register.waitUntilExit()

            // Kill iconservicesagent to flush the icon cache (auto-restarts in <1s)
            let killIcons = Process()
            killIcons.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killIcons.arguments = ["iconservicesagent"]
            killIcons.standardOutput = FileHandle.nullDevice
            killIcons.standardError = FileHandle.nullDevice
            try? killIcons.run()
            killIcons.waitUntilExit()

            // Safety net: verify the Dock is still running after 2 seconds.
            // iconservicesagent restart can occasionally crash the Dock.
            Thread.sleep(forTimeInterval: 2.0)
            let dockCheck = Process()
            dockCheck.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            dockCheck.arguments = ["-x", "Dock"]
            dockCheck.standardOutput = FileHandle.nullDevice
            dockCheck.standardError = FileHandle.nullDevice
            try? dockCheck.run()
            dockCheck.waitUntilExit()

            if dockCheck.terminationStatus != 0 {
                // Dock is not running — restart it
                log("AppDelegate: Dock not running after icon cache reset, restarting")
                let restartDock = Process()
                restartDock.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                restartDock.arguments = ["-a", "Dock"]
                restartDock.standardOutput = FileHandle.nullDevice
                restartDock.standardError = FileHandle.nullDevice
                try? restartDock.run()
                restartDock.waitUntilExit()
            }

            log("AppDelegate: Icon cache reset complete")
        }
    }

    /// Set up global keyboard shortcuts
    private func setupGlobalHotkeys() {
        // Handler for Ctrl+Option+R -> Open Rewind
        let hotkeyHandler: (NSEvent) -> NSEvent? = { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = event.keyCode

            // Log modifier key presses for debugging
            if modifiers.contains(.control) || modifiers.contains(.option) {
                log("AppDelegate: [HOTKEY] keyCode=\(keyCode), modifiers=\(modifiers.rawValue) (ctrl=\(modifiers.contains(.control)), opt=\(modifiers.contains(.option)))")
            }

            // Check for Ctrl+Option+R (less likely to conflict with system shortcuts)
            let isCtrlOption = modifiers.contains(.control) && modifiers.contains(.option)
            let isR = keyCode == 15 // R key

            if isCtrlOption && isR {
                log("AppDelegate: [HOTKEY] Rewind hotkey MATCHED (Ctrl+Option+R)")
                DispatchQueue.main.async {
                    log("AppDelegate: [HOTKEY] Activating app and posting notification")
                    // Bring app to front
                    NSApp.activate(ignoringOtherApps: true)
                    // Find and show main window
                    for window in NSApp.windows {
                        if window.title.hasPrefix("Fazm") {
                            window.makeKeyAndOrderFront(nil)
                            break
                        }
                    }
                    // Post notification to navigate to Rewind
                    NotificationCenter.default.post(name: .navigateToRewind, object: nil)
                    log("AppDelegate: [HOTKEY] Posted navigateToRewind notification")
                }
            }
            return event
        }

        // Ask Fazm shortcut is registered via Carbon RegisterEventHotKey in
        // GlobalShortcutManager (works regardless of accessibility permission state).

        // Global monitor - for when OTHER apps are focused (Ctrl+Option+R only)
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = hotkeyHandler(event)
        }

        // Local monitor - for when THIS app is focused (Ctrl+Option+R only)
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return hotkeyHandler(event)
        }

        log("AppDelegate: Hotkey monitors registered - global=\(globalHotkeyMonitor != nil), local=\(localHotkeyMonitor != nil)")
        log("AppDelegate: Hotkey is Ctrl+Option+R (⌃⌥R), Ask Fazm + Cmd+\\ via Carbon hotkeys")
    }

    // Dock icon is always visible — LSUIElement=false and activation policy stays .regular

    /// Force-refresh the menu bar icon after activation policy changes.
    /// Works around a macOS Sequoia bug where NSStatusBar items vanish
    /// when switching to .accessory activation policy.
    @MainActor private func refreshMenuBarIcon() {
        guard let item = statusBarItem else {
            // Status bar item was lost — recreate it
            log("AppDelegate: [MENUBAR] refreshMenuBarIcon: statusBarItem is nil, recreating")
            setupMenuBar()
            return
        }
        // Re-assert visibility synchronously
        item.isVisible = true
        // Re-apply the icon to force the system to redraw
        if let button = item.button {
            if FazmApp.launchMode == .rewind {
                if let icon = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Fazm Rewind") {
                    icon.isTemplate = true
                    button.image = icon
                }
            } else if let iconURL = Bundle.resourceBundle.url(forResource: "fazm_text_logo", withExtension: "png"),
                      let icon = NSImage(contentsOf: iconURL) {
                icon.isTemplate = true
                let aspect = icon.size.width / icon.size.height
                icon.size = NSSize(width: 16 * aspect, height: 16)
                button.image = icon
            }
        }
        // Safety net: verify again after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let button = self?.statusBarItem?.button
            let isPhantom = button != nil && button!.frame.width == 0
            if self?.statusBarItem?.isVisible != true || isPhantom {
                log("AppDelegate: [MENUBAR] Icon still not visible/phantom after refresh (frame=\(button?.frame ?? .zero)), recreating")
                self?.setupMenuBar()
            }
        }
        log("AppDelegate: [MENUBAR] Refreshed status bar item after policy change")
    }

    /// Set up menu bar icon using NSStatusBar (more reliable than SwiftUI MenuBarExtra)
    @MainActor private func setupMenuBar() {
        log("AppDelegate: [MENUBAR] Setting up NSStatusBar menu (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        log("AppDelegate: [MENUBAR] Thread: \(Thread.isMainThread ? "main" : "background"), statusBar items: \(NSStatusBar.system.thickness)")

        // Explicitly remove old status item before creating a new one.
        // Relying on ARC deallocation alone can leave "phantom" items that exist
        // in memory but never render on screen.
        if let old = statusBarItem {
            NSStatusBar.system.removeStatusItem(old)
            statusBarItem = nil
            log("AppDelegate: [MENUBAR] Removed old status bar item before recreating")
        }

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let statusBarItem = statusBarItem else {
            log("AppDelegate: [MENUBAR] ERROR - Failed to create status bar item")
            SentrySDK.capture(message: "Failed to create NSStatusItem") { scope in
                scope.setLevel(.error)
                scope.setTag(value: "menu_bar", key: "component")
            }
            return
        }

        log("AppDelegate: [MENUBAR] NSStatusItem created successfully")

        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Fazm"

        // Set up the button with icon — use "fazm" text logo (not a circle)
        if let button = statusBarItem.button {
            if FazmApp.launchMode == .rewind {
                // Rewind mode uses SF Symbol
                if let icon = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Fazm Rewind") {
                    icon.isTemplate = true
                    button.image = icon
                    log("AppDelegate: [MENUBAR] Rewind icon set successfully")
                }
            } else if let iconURL = Bundle.resourceBundle.url(forResource: "fazm_text_logo", withExtension: "png"),
                      let icon = NSImage(contentsOf: iconURL) {
                icon.isTemplate = true
                // Scale to menu bar height (16pt) with proportional width
                let aspect = icon.size.width / icon.size.height
                icon.size = NSSize(width: 16 * aspect, height: 16)
                button.image = icon
                button.imagePosition = .imageOnly
                log("AppDelegate: [MENUBAR] Fazm text logo set successfully (size: \(icon.size))")
            } else {
                // Fallback to SF Symbol
                if let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Fazm") {
                    icon.isTemplate = true
                    button.image = icon
                }
                log("AppDelegate: [MENUBAR] WARNING - Failed to load fazm_text_logo, using fallback")
            }
            button.toolTip = FazmApp.launchMode == .rewind ? "Fazm Rewind" : displayName
        } else {
            log("AppDelegate: [MENUBAR] WARNING - statusBarItem.button is nil")
        }

        // Create menu
        let menu = NSMenu()

        // Version item (non-clickable header)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "Fazm v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(NSMenuItem.separator())

        // Open app item
        let openItem = NSMenuItem(title: "Open Settings", action: #selector(openFazmFromMenu), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        // Sign Out item (shown when signed in; updated dynamically in menuWillOpen)
        let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(signOutFromMenu), keyEquivalent: "")
        signOutItem.target = self
        signOutItem.tag = 1001 // tag for dynamic updates
        signOutItem.isHidden = !AuthState.shared.isSignedIn
        menu.addItem(signOutItem)

        menu.addItem(NSMenuItem.separator())

        // Check for Updates
        let updatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())

        // Report Issue
        let reportItem = NSMenuItem(title: "Report Issue...", action: #selector(reportIssue), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        // Reset Onboarding
        let resetItem = NSMenuItem(title: "Reset Onboarding...", action: #selector(resetOnboarding), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())

        // Quit item
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusBarItem.menu = menu
        menu.delegate = self
        log("AppDelegate: [MENUBAR] Menu bar setup completed - icon visible in status bar")

        // Verify the status item is valid
        if let button = statusBarItem.button {
            log("AppDelegate: [MENUBAR] VERIFY - button exists, frame: \(button.frame), isHidden: \(button.isHidden)")
        } else {
            log("AppDelegate: [MENUBAR] VERIFY - WARNING: button is nil after setup!")
        }
    }

    @MainActor @objc private func openFazmFromMenu() {
        AnalyticsManager.shared.menuBarActionClicked(action: "open_fazm")
        NSApp.activate(ignoringOtherApps: true)
        var foundWindow = false
        for window in NSApp.windows {
            if window.title.hasPrefix("Fazm") {
                foundWindow = true
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if !foundWindow {
            log("AppDelegate: [MENUBAR] No Fazm window found — recreating via WindowOpener")
            WindowOpener.shared.openWindow?(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            // Same fallback as applicationShouldHandleReopen: WindowOpener may not
            // be bound yet at cold-boot, so guarantee the floating bar is visible.
            FloatingControlBarManager.shared.show()
        }
    }

    @MainActor @objc private func checkForUpdates() {
        AnalyticsManager.shared.menuBarActionClicked(action: "check_updates")
        UpdaterViewModel.shared.checkForUpdates()
    }

    @MainActor @objc private func reportIssue() {
        AnalyticsManager.shared.menuBarActionClicked(action: "report_issue")
        FeedbackWindow.show(userEmail: AuthState.shared.userEmail)
    }

    @MainActor @objc private func resetOnboarding() {
        AnalyticsManager.shared.menuBarActionClicked(action: "reset_onboarding")
        AppState().resetOnboardingAndRestart()
    }

    @MainActor @objc private func quitApp() {
        AnalyticsManager.shared.menuBarActionClicked(action: "quit")
        NSApplication.shared.terminate(nil)
    }

    @MainActor @objc private func signOutFromMenu() {
        AnalyticsManager.shared.menuBarActionClicked(action: "sign_out")
        AuthService.shared.signOut()
    }

    // MARK: - App Menus (Format / Help)

    /// Replace SwiftUI-generated Format and Help menus with AppKit equivalents.
    /// SwiftUI's .commands {} shares the scene view graph and can crash with
    /// AG::Graph::value_set if any @Published state mutates during menu rendering.
    @MainActor @objc private func openSettings() {
        openFazmFromMenu()
    }

    /// Add "Settings…" (Cmd+,) to the app menu. Called via NSMenuDelegate right before
    /// the menu opens, because SwiftUI rebuilds the app menu on each display.
    @MainActor private func addSettingsMenuItem(to appMenu: NSMenu) {
        // Avoid duplicates
        guard !appMenu.items.contains(where: { $0.title == "Settings…" }) else { return }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        // Insert after "About" item (index 0) + separator (index 1)
        let insertIndex = min(2, appMenu.items.count)
        appMenu.insertItem(NSMenuItem.separator(), at: insertIndex)
        appMenu.insertItem(settingsItem, at: insertIndex + 1)
    }

    private func setupAppMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // -- Format menu: add font size controls (replacing SwiftUI's default text formatting) --
        // Create from scratch since SwiftUI no longer generates this menu.
        let formatMenu = NSMenu(title: "Format")

        let increaseItem = NSMenuItem(title: "Increase Font Size", action: #selector(increaseFontSize), keyEquivalent: "+")
        increaseItem.keyEquivalentModifierMask = .command
        increaseItem.target = self
        formatMenu.addItem(increaseItem)

        let decreaseItem = NSMenuItem(title: "Decrease Font Size", action: #selector(decreaseFontSize), keyEquivalent: "-")
        decreaseItem.keyEquivalentModifierMask = .command
        decreaseItem.target = self
        formatMenu.addItem(decreaseItem)

        let resetItem = NSMenuItem(title: "Reset Font Size", action: #selector(resetFontSize), keyEquivalent: "0")
        resetItem.keyEquivalentModifierMask = .command
        resetItem.target = self
        formatMenu.addItem(resetItem)

        formatMenu.addItem(NSMenuItem.separator())

        let resetWindowItem = NSMenuItem(title: "Reset Window Size", action: #selector(resetWindowSize), keyEquivalent: "")
        resetWindowItem.target = self
        formatMenu.addItem(resetWindowItem)

        let formatMenuItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatMenuItem.submenu = formatMenu

        // Insert after Edit (or at end if Edit isn't found)
        let editIndex = mainMenu.indexOfItem(withTitle: "Edit")
        if editIndex >= 0 {
            mainMenu.insertItem(formatMenuItem, at: editIndex + 1)
        } else {
            mainMenu.addItem(formatMenuItem)
        }

        // -- Help menu: remove it (macOS help search is irrelevant for Fazm) --
        let helpIndex = mainMenu.indexOfItem(withTitle: "Help")
        if helpIndex >= 0 {
            mainMenu.removeItem(at: helpIndex)
        }
    }

    @objc private func increaseFontSize() {
        let s = FontScaleSettings.shared
        s.scale = min(2.0, round((s.scale + 0.05) * 20) / 20)
    }

    @objc private func decreaseFontSize() {
        let s = FontScaleSettings.shared
        s.scale = max(0.5, round((s.scale - 0.05) * 20) / 20)
    }

    @objc private func resetFontSize() {
        FontScaleSettings.shared.resetToDefault()
    }

    @objc private func resetWindowSize() {
        resetWindowToDefaultSize()
    }

    // MARK: - NSMenuDelegate
    func menuWillOpen(_ menu: NSMenu) {
        // Status bar menu — update sign-out item
        if let signOutItem = menu.item(withTag: 1001) {
            log("AppDelegate: [MENUBAR] Menu opened by user")
            AnalyticsManager.shared.menuBarOpened()
            let isSignedIn = AuthState.shared.isSignedIn
            signOutItem.isHidden = !isSignedIn
            if let email = AuthState.shared.userEmail, !email.isEmpty {
                signOutItem.title = "Sign Out (\(email))"
            } else {
                signOutItem.title = "Sign Out"
            }
        }

        // App menu — inject "Settings…" (SwiftUI rebuilds this menu each time)
        if menu == NSApp.mainMenu?.items.first?.submenu {
            addSettingsMenuItem(to: menu)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running in menu bar when all windows are closed
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If this terminate was scheduled by `restartApp()` / `relaunchApp()`, honor it
        // and let the spawned `sleep && open` helper bring the app back. Otherwise this
        // is a user-initiated quit (Cmd-Q, menu Quit, dock Quit) — kill any pending
        // relaunch helpers so the user actually gets to quit.
        if !RelaunchSupervisor.consumeProgrammaticTerminateFlag() {
            let killed = RelaunchSupervisor.cancelPendingHelpers()
            if killed > 0 {
                log("AppDelegate: User quit — cancelled \(killed) pending relaunch helper(s)")
            }
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Always try to show the main Fazm window when dock icon is clicked
        for window in sender.windows where window.title.hasPrefix("Fazm") {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            log("AppDelegate: Restored Fazm window from dock click (wasVisible=\(flag))")
            return false
        }
        // Window was deallocated — ask SwiftUI to recreate it
        log("AppDelegate: No Fazm window found on dock click — recreating via WindowOpener")
        WindowOpener.shared.openWindow?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        // Fallback: at cold-boot via SMAppService, WindowOpener.openWindow can still
        // be nil (the SwiftUI scene hasn't bound it yet), so the optional-chain above
        // silently no-ops. Surface the floating bar so the user is never stranded
        // with a running menu-bar icon and no way in.
        FloatingControlBarManager.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release the single-instance lock first so a relaunch can acquire it
        // even if downstream cleanup hangs. Idempotent + guarded by PID check.
        InstanceLock.release()

        // Freeze detached window registry before windows tear down
        DetachedChatWindowController.shared.prepareForTermination()

        // Persist the floating bar's unsent draft so it survives a relaunch.
        // Read either the live input (user mid-typing) or the stashed draft
        // (user opened bar, typed, dismissed without sending) — whichever is
        // non-empty. Empty value clears any stale saved draft.
        if let inputState = FloatingControlBarManager.shared.barState?.input {
            let liveDraft = inputState.aiInputText
            let stashedDraft = inputState.draftInputText
            let pending = liveDraft.isEmpty ? stashedDraft : liveDraft
            if pending.isEmpty {
                UserDefaults.standard.removeObject(forKey: FloatingControlBarManager.floatingDraftKey)
            } else {
                UserDefaults.standard.set(pending, forKey: FloatingControlBarManager.floatingDraftKey)
            }
        }

        // Stop ACP bridge and all child processes (MCP servers) to prevent orphans
        FloatingControlBarManager.shared.chatProvider?.stopBridge()

        // Stop session recording
        SessionRecordingManager.shared.shutdown()

        // Stop session heartbeat and record final session duration
        AnalyticsManager.shared.stopSessionHeartbeat()

        // Remove window observers
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        // Remove hotkey monitors
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalHotkeyMonitor = nil
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotkeyMonitor = nil
        }
        // Remove floating bar observers and shortcuts
        if let observer = toggleBarObserver {
            NotificationCenter.default.removeObserver(observer)
            toggleBarObserver = nil
        }
        GlobalShortcutManager.shared.unregisterShortcuts()

        // Stop push-to-talk
        PushToTalkManager.shared.cleanup()

        // Stop heartbeat timer
        sentryHeartbeatTimer?.invalidate()
        sentryHeartbeatTimer = nil

        // Stop the routine scheduler (in-flight cron-runner subprocesses keep their own
        // timeout and finish independently of the app).
        RoutineScheduler.shared.stop()

        // Mark clean shutdown so next launch skips expensive DB integrity check
        AppDatabase.markCleanShutdown()

        // Report final resources before termination
        ResourceMonitor.shared.reportResourcesNow(context: "app_terminating")
        ResourceMonitor.shared.stop()

        // Capture final session snapshot before termination (now enabled for dev builds too)
        SentrySDK.capture(message: "App Terminating") { scope in
            scope.setLevel(.info)
            scope.setTag(value: "lifecycle", key: "event_type")
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        log("FazmApp AppDelegate: URL event received: \(urlString)")

        switch url.host {
        case "auth-success":
            // Bring the app and main window to front after successful browser sign-in
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                window.makeKeyAndOrderFront(nil)
            }
        case "auth-failed":
            // Bring the app and main window to front so user can retry
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                window.makeKeyAndOrderFront(nil)
            }
        case "subscription":
            // Handle subscription success/cancel redirects from Stripe Checkout
            let path = url.path
            log("FazmApp: Subscription URL callback: \(path)")
            NSApp.activate(ignoringOtherApps: true)
            if path == "/success" {
                // Refresh subscription status, dismiss paywall, and notify user
                Task {
                    let active = await SubscriptionService.shared.refreshStatus()
                    await MainActor.run {
                        PaywallWindowController.shared.close()
                        if active {
                            ToastManager.shared.show("You're on Fazm Pro!", icon: "checkmark.circle.fill")
                        }
                    }
                }
            }
        case "referral":
            // Handle referral code from referral link: fazm://referral/{code}
            let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !code.isEmpty {
                log("FazmApp: Referral code received: \(code)")
                NSApp.activate(ignoringOtherApps: true)
                Task {
                    await ReferralService.shared.trackReferralSignup(code: code)
                    await MainActor.run {
                        ToastManager.shared.show("Referral applied!", icon: "checkmark.circle.fill")
                    }
                }
            }
        case "settings":
            // Deep link to a specific settings page, e.g. fazm://settings/tool-timeouts
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                window.makeKeyAndOrderFront(nil)
            }
            let settingPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !settingPath.isEmpty {
                // Map URL path to settingId for scroll-to-highlight
                let settingId: String
                switch settingPath {
                case "tool-timeouts", "tool-timeout":
                    settingId = "advanced.preferences.tooltimeout"
                default:
                    settingId = settingPath
                }
                // Post after a short delay so the settings window has time to appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("navigateToSetting"),
                        object: nil,
                        userInfo: ["settingId": settingId]
                    )
                }
            }
        default:
            log("FazmApp AppDelegate: Unhandled URL path: \(url.host ?? "nil")")
        }
    }

    /// One-time migration: switch bridgeMode from "personal" to "builtin" (bundled Anthropic API key)
    /// Existing installs had "personal" as default, which shows "Connect your Claude account"
    private func migrateBridgeModeToBuiltin() {
        let migrationKey = "didMigrateBridgeModeToBuiltinV1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationKey)

        let current = UserDefaults.standard.string(forKey: "bridgeMode") ?? "personal"
        if current == "personal" {
            UserDefaults.standard.set("builtin", forKey: "bridgeMode")
            log("BridgeMode migration: Switched from personal to builtin")
        } else {
            log("BridgeMode migration: Already \(current), skipping")
        }
    }

    /// One-time migration to enable launch at login for existing users
    /// Only runs once, and only enables if user hasn't explicitly set a preference
    private func migrateLaunchAtLoginDefault() {
        let migrationKey = "didMigrateLaunchAtLoginV1"

        // Skip if migration already done
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        // Mark migration as done (do this first to ensure it only runs once)
        UserDefaults.standard.set(true, forKey: migrationKey)

        // Only enable for users who have completed onboarding (existing users)
        // New users will get this enabled at the end of onboarding
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        guard hasCompletedOnboarding else {
            log("LaunchAtLogin migration: Skipped - user hasn't completed onboarding yet")
            return
        }

        // Check current status - only enable if not already registered
        // This respects users who may have explicitly disabled it via System Settings
        Task { @MainActor in
            let manager = LaunchAtLoginManager.shared
            if !manager.isEnabled {
                let success = manager.setEnabled(true)
                log("LaunchAtLogin migration: Enabled for existing user (success: \(success))")
                if success {
                    AnalyticsManager.shared.launchAtLoginChanged(enabled: true, source: "migration")
                }
            } else {
                log("LaunchAtLogin migration: Already enabled, skipping")
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AnalyticsManager.shared.appBecameActive()
        Task { @MainActor in AuthService.shared.reconcileAuthState() }
    }

    func applicationWillResignActive(_ notification: Notification) {
        AnalyticsManager.shared.appResignedActive()
    }

    // MARK: - Code Signature Diagnostics

    /// Log code signature verification and install origin at startup.
    /// Helps diagnose KERN_CODESIGN_ERROR crashes by capturing the signature state
    /// and whether the app was delivered via Sparkle update or fresh DMG install.
    private func logCodeSignatureStatus() {
        DispatchQueue.global(qos: .utility).async {
            let appPath = Bundle.main.bundlePath

            // 1. Verify code signature
            let verifyProcess = Process()
            verifyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verifyProcess.arguments = ["--verify", "--deep", "--strict", appPath]
            let verifyPipe = Pipe()
            verifyProcess.standardError = verifyPipe
            verifyProcess.standardOutput = verifyPipe
            do {
                try verifyProcess.run()
                verifyProcess.waitUntilExit()
            } catch {
                log("CodeSign: Failed to run codesign: \(error)")
                return
            }

            let verifyOutput = String(data: verifyPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let verifyOK = verifyProcess.terminationStatus == 0

            // 2. Get page size of main binary
            let infoProcess = Process()
            infoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            let mainBinary = Bundle.main.executablePath ?? "\(appPath)/Contents/MacOS/Fazm"
            infoProcess.arguments = ["-d", "--verbose=4", "--arch", "arm64", mainBinary]
            let infoPipe = Pipe()
            infoProcess.standardError = infoPipe
            infoProcess.standardOutput = infoPipe
            do {
                try infoProcess.run()
                infoProcess.waitUntilExit()
            } catch {
                log("CodeSign: Failed to get signing info: \(error)")
                return
            }

            let infoOutput = String(data: infoPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let pageSize = infoOutput.split(separator: "\n")
                .first(where: { $0.contains("Page size=") })
                .flatMap { line in
                    line.split(separator: "=").last.map { String($0) }
                } ?? "unknown"

            // 3. Detect install origin
            let hadSparkleUpdate = UserDefaults.standard.bool(forKey: "hasSuccessfullyInstalledSparkleUpdate")
            let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            let previousVersion = UserDefaults.standard.string(forKey: "fazm_previousVersion")
            let previousBuild = UserDefaults.standard.string(forKey: "fazm_previousBuild")
            let isVersionChange = previousVersion != nil && (previousVersion != currentVersion || previousBuild != currentBuild)

            // Persist current version for next launch comparison
            UserDefaults.standard.set(currentVersion, forKey: "fazm_previousVersion")
            UserDefaults.standard.set(currentBuild, forKey: "fazm_previousBuild")

            // Check for quarantine xattr (present on DMG downloads, cleared by Sparkle updates)
            let xattrProcess = Process()
            xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProcess.arguments = ["-p", "com.apple.quarantine", appPath]
            let xattrPipe = Pipe()
            xattrProcess.standardOutput = xattrPipe
            xattrProcess.standardError = Pipe()
            do {
                try xattrProcess.run()
                xattrProcess.waitUntilExit()
            } catch { /* ignore */ }
            let hasQuarantine = xattrProcess.terminationStatus == 0
            let quarantineValue = hasQuarantine
                ? (String(data: xattrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "present")
                : "none"

            // Determine install method
            let installMethod: String
            if hasQuarantine {
                installMethod = "dmg-download"
            } else if hadSparkleUpdate && isVersionChange {
                installMethod = "sparkle-update (just updated)"
            } else if hadSparkleUpdate {
                installMethod = "sparkle-managed"
            } else if previousVersion == nil {
                installMethod = "first-launch"
            } else {
                installMethod = "unknown"
            }

            // 4. Check app bundle modification time vs binary modification time
            let fm = FileManager.default
            let appModDate = (try? fm.attributesOfItem(atPath: appPath)[.modificationDate] as? Date)?.description ?? "?"
            let binModDate = (try? fm.attributesOfItem(atPath: mainBinary)[.modificationDate] as? Date)?.description ?? "?"

            // 5. List all loaded Mach-O images (for matching crash addresses to binaries)
            var imageList = ""
            let imageCount = _dyld_image_count()
            for i in 0..<min(imageCount, 50) {
                if let name = _dyld_get_image_name(i) {
                    let path = String(cString: name)
                    let header = _dyld_get_image_header(i)
                    // Only log non-system images (our app + embedded binaries)
                    if path.contains("Fazm") || path.contains("fazm") || path.contains("Sparkle") {
                        let addr = UInt(bitPattern: header)
                        imageList += " \(path.split(separator: "/").last ?? Substring(path))@\(String(addr, radix: 16))"
                    }
                }
            }

            let prevStr = previousVersion.map { "\($0)+\(previousBuild ?? "?")" } ?? "none"
            log("CodeSign: verify=\(verifyOK ? "OK" : "FAILED") pageSize=\(pageSize) version=\(currentVersion)+\(currentBuild) prevVersion=\(prevStr) install=\(installMethod) quarantine=\(quarantineValue) appMod=\(appModDate) binMod=\(binModDate)\(imageList.isEmpty ? "" : " images=[\(imageList.trimmingCharacters(in: .whitespaces))]")\(verifyOK ? "" : " error=\(verifyOutput)")")

            // Set Sentry tags so we can filter crashes by install method and codesign status
            SentrySDK.configureScope { scope in
                scope.setTag(value: installMethod, key: "install_method")
                scope.setTag(value: verifyOK ? "valid" : "invalid", key: "codesign_status")
                scope.setTag(value: pageSize, key: "codesign_page_size")
                if isVersionChange {
                    scope.setTag(value: prevStr, key: "previous_version")
                }
            }

            // Report codesign failures to PostHog for tracking across all users
            if !verifyOK {
                Task { @MainActor in
                    PostHogManager.shared.track("codesign_verification_failed", properties: [
                        "version": "\(currentVersion)+\(currentBuild)",
                        "install_method": installMethod,
                        "error": verifyOutput,
                        "previous_version": prevStr,
                    ])
                }
            }
        }
    }
}
