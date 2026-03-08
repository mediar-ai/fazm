import Foundation
import AppKit

/// Unified analytics manager that sends events to PostHog
@MainActor
class AnalyticsManager {
    static let shared = AnalyticsManager()

    /// Returns true if this is a development build (bundle ID ends with "-dev")
    /// Development builds don't send analytics to avoid polluting production data
    nonisolated static var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix("-dev") == true
    }

    private var lastTranscriptionStartedAt: Date?
    private var sessionHeartbeatTimer: Timer?
    private var sessionStartTime: Date?

    private init() {}

    // MARK: - Initialization

    func initialize() {
        // Skip analytics in development builds
        guard !Self.isDevBuild else {
            log("Analytics: Skipping initialization (development build)")
            return
        }
        PostHogManager.shared.initialize()
    }

    // MARK: - User Identification

    func identify() {
        PostHogManager.shared.identify()
    }

    func reset() {
        PostHogManager.shared.reset()
    }

    // MARK: - Opt In/Out

    func optInTracking() {
        PostHogManager.shared.optIn()
    }

    func optOutTracking() {
        PostHogManager.shared.optOut()
    }

    // MARK: - Session Heartbeat

    /// Start a periodic heartbeat (every 60s) to measure session duration in PostHog
    func startSessionHeartbeat() {
        guard !Self.isDevBuild else { return }
        sessionStartTime = Date()
        sessionHeartbeatTimer?.invalidate()
        sessionHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.sessionStartTime else { return }
                let sessionMinutes = Int(Date().timeIntervalSince(start) / 60)
                PostHogManager.shared.track("session_heartbeat", properties: [
                    "session_duration_minutes": sessionMinutes
                ])
            }
        }
    }

    func stopSessionHeartbeat() {
        sessionHeartbeatTimer?.invalidate()
        sessionHeartbeatTimer = nil
        if let start = sessionStartTime {
            let sessionMinutes = Int(Date().timeIntervalSince(start) / 60)
            PostHogManager.shared.track("session_ended", properties: [
                "session_duration_minutes": sessionMinutes
            ])
        }
        sessionStartTime = nil
    }

    // MARK: - Onboarding Events

    func onboardingStarted() {
        PostHogManager.shared.track("Onboarding Started")
    }

    func onboardingStepCompleted(step: Int, stepName: String) {
        PostHogManager.shared.onboardingStepCompleted(step: step, stepName: stepName)
    }

    func onboardingCompleted() {
        PostHogManager.shared.onboardingCompleted()
    }

    func onboardingChatToolUsed(tool: String, properties: [String: Any] = [:]) {
        var props = properties
        props["tool"] = tool
        PostHogManager.shared.track("Onboarding Chat Tool Used", properties: props)
    }

    func onboardingChatMessage(role: String, step: String) {
        let props: [String: Any] = ["role": role, "step": step]
        PostHogManager.shared.track("Onboarding Chat Message", properties: props)
    }

    // MARK: - Authentication Events

    func signInStarted(provider: String) {
        PostHogManager.shared.signInStarted(provider: provider)
    }

    func signInCompleted(provider: String) {
        PostHogManager.shared.signInCompleted(provider: provider)
    }

    func signInFailed(provider: String, error: String) {
        PostHogManager.shared.signInFailed(provider: provider, error: error)
    }

    func signedOut() {
        PostHogManager.shared.signedOut()
    }

    // MARK: - Monitoring Events

    func monitoringStarted() {
        PostHogManager.shared.monitoringStarted()
    }

    func monitoringStopped() {
        PostHogManager.shared.monitoringStopped()
    }

    func distractionDetected(app: String, windowTitle: String?) {
        PostHogManager.shared.distractionDetected(app: app, windowTitle: windowTitle)
    }

    func focusRestored(app: String) {
        PostHogManager.shared.focusRestored(app: app)
    }

    // MARK: - Recording Events

    func transcriptionStarted() {
        // Debounce: skip if called within 5 seconds (catches rapid wake/reconnect double-fires)
        if let last = lastTranscriptionStartedAt, Date().timeIntervalSince(last) < 5 {
            return
        }
        lastTranscriptionStartedAt = Date()
        PostHogManager.shared.transcriptionStarted()
    }

    func transcriptionStopped(wordCount: Int) {
        PostHogManager.shared.transcriptionStopped(wordCount: wordCount)
    }

    func recordingError(error: String) {
        PostHogManager.shared.recordingError(error: error)
    }

    // MARK: - Permission Events

    func permissionRequested(permission: String, extraProperties: [String: Any] = [:]) {
        PostHogManager.shared.permissionRequested(permission: permission, extraProperties: extraProperties)
    }

    func permissionGranted(permission: String, extraProperties: [String: Any] = [:]) {
        PostHogManager.shared.permissionGranted(permission: permission, extraProperties: extraProperties)
    }

    func permissionDenied(permission: String, extraProperties: [String: Any] = [:]) {
        PostHogManager.shared.permissionDenied(permission: permission, extraProperties: extraProperties)
    }

    func permissionSkipped(permission: String, extraProperties: [String: Any] = [:]) {
        PostHogManager.shared.permissionSkipped(permission: permission, extraProperties: extraProperties)
    }

    /// Track Bluetooth state changes for debugging
    func bluetoothStateChanged(oldState: String, newState: String, oldStateRaw: Int, newStateRaw: Int, authorization: String, authorizationRaw: Int) {
        let properties: [String: Any] = [
            "old_state": oldState,
            "new_state": newState,
            "old_state_raw": oldStateRaw,
            "new_state_raw": newStateRaw,
            "authorization": authorization,
            "authorization_raw": authorizationRaw
        ]
        PostHogManager.shared.track("Bluetooth State Changed", properties: properties)
    }

    /// Track when ScreenCaptureKit broken state is detected (TCC granted but capture failing)
    func screenCaptureBrokenDetected() {
        PostHogManager.shared.screenCaptureBrokenDetected()
    }

    /// Track when user clicks reset button or notification to reset screen capture
    func screenCaptureResetClicked(source: String) {
        PostHogManager.shared.screenCaptureResetClicked(source: source)
    }

    /// Track when screen capture reset completes (success or failure)
    func screenCaptureResetCompleted(success: Bool) {
        PostHogManager.shared.screenCaptureResetCompleted(success: success)
    }

    /// Track when notification repair is triggered (auto-repair or error-triggered)
    func notificationRepairTriggered(reason: String, previousStatus: String, currentStatus: String) {
        PostHogManager.shared.notificationRepairTriggered(reason: reason, previousStatus: previousStatus, currentStatus: currentStatus)
    }

    /// Track notification settings status (auth, alertStyle, sound, badge)
    func notificationSettingsChecked(
        authStatus: String,
        alertStyle: String,
        soundEnabled: Bool,
        badgeEnabled: Bool,
        bannersDisabled: Bool
    ) {
        PostHogManager.shared.notificationSettingsChecked(
            authStatus: authStatus,
            alertStyle: alertStyle,
            soundEnabled: soundEnabled,
            badgeEnabled: badgeEnabled,
            bannersDisabled: bannersDisabled
        )
    }

    // MARK: - App Lifecycle Events

    func appLaunched() {
        PostHogManager.shared.appLaunched()
    }

    func trackStartupTiming(dbInitMs: Double, timeToInteractiveMs: Double, hadUncleanShutdown: Bool, databaseInitFailed: Bool) {
        guard !Self.isDevBuild else { return }
        let properties: [String: Any] = [
            "db_init_ms": round(dbInitMs),
            "time_to_interactive_ms": round(timeToInteractiveMs),
            "had_unclean_shutdown": hadUncleanShutdown,
            "database_init_failed": databaseInitFailed
        ]
        PostHogManager.shared.track("App Startup Timing", properties: properties)
    }

    /// Track first launch with comprehensive system diagnostics
    /// This only fires once per installation
    func trackFirstLaunchIfNeeded() {
        // Skip in dev builds
        guard !Self.isDevBuild else { return }

        let defaults = UserDefaults.standard
        let hasLaunchedKey = "hasLaunchedBefore"

        // Check if this is the first launch
        guard !defaults.bool(forKey: hasLaunchedKey) else {
            return
        }

        // Mark as launched so this only fires once
        defaults.set(true, forKey: hasLaunchedKey)

        // Collect system diagnostics
        let diagnostics = collectSystemDiagnostics()

        // Track in analytics
        PostHogManager.shared.firstLaunch(diagnostics: diagnostics)

        log("Analytics: First launch diagnostics tracked")
    }

    /// Collect comprehensive system diagnostics for first launch event
    private func collectSystemDiagnostics() -> [String: Any] {
        var diagnostics: [String: Any] = [:]

        // App version
        diagnostics["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        diagnostics["build_number"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

        // macOS version (detailed)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        diagnostics["os_version"] = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        diagnostics["os_major_version"] = osVersion.majorVersion
        diagnostics["os_minor_version"] = osVersion.minorVersion
        diagnostics["os_patch_version"] = osVersion.patchVersion
        diagnostics["os_version_string"] = ProcessInfo.processInfo.operatingSystemVersionString

        // Architecture (Apple Silicon vs Intel)
        #if arch(arm64)
        diagnostics["architecture"] = "arm64"
        diagnostics["is_apple_silicon"] = true
        #elseif arch(x86_64)
        diagnostics["architecture"] = "x86_64"
        diagnostics["is_apple_silicon"] = false
        #else
        diagnostics["architecture"] = "unknown"
        diagnostics["is_apple_silicon"] = false
        #endif

        // App bundle location - helps diagnose installation issues
        if let bundlePath = Bundle.main.bundlePath as String? {
            diagnostics["bundle_path"] = bundlePath

            // Categorize the installation location
            if bundlePath.hasPrefix("/Volumes/") {
                diagnostics["install_location"] = "dmg_mounted"
            } else if bundlePath.contains("/Downloads/") {
                diagnostics["install_location"] = "downloads_folder"
            } else if bundlePath.hasPrefix("/Applications/") {
                diagnostics["install_location"] = "applications_system"
            } else if bundlePath.contains("/Applications/") {
                diagnostics["install_location"] = "applications_user"
            } else if bundlePath.contains("DerivedData") || bundlePath.contains("Xcode") {
                diagnostics["install_location"] = "xcode_build"
            } else {
                diagnostics["install_location"] = "other"
            }
        }

        // Device info
        diagnostics["processor_count"] = ProcessInfo.processInfo.processorCount
        diagnostics["physical_memory_gb"] = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

        // Locale info
        diagnostics["locale"] = Locale.current.identifier
        diagnostics["timezone"] = TimeZone.current.identifier

        return diagnostics
    }

    func appBecameActive() {
        PostHogManager.shared.appBecameActive()
    }

    func appResignedActive() {
        PostHogManager.shared.appResignedActive()
    }

    // MARK: - Conversation Events

    func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {
        PostHogManager.shared.conversationCreated(conversationId: conversationId, source: source, durationSeconds: durationSeconds)
    }

    func memoryDeleted(conversationId: String) {
        PostHogManager.shared.memoryDeleted(conversationId: conversationId)
    }

    func memoryShareButtonClicked(conversationId: String) {
        PostHogManager.shared.memoryShareButtonClicked(conversationId: conversationId)
    }

    func memoryListItemClicked(conversationId: String) {
        PostHogManager.shared.memoryListItemClicked(conversationId: conversationId)
    }

    // MARK: - Chat Events

    func chatMessageSent(messageLength: Int, hasContext: Bool = false, source: String) {
        PostHogManager.shared.chatMessageSent(messageLength: messageLength, hasContext: hasContext, source: source)
    }

    // MARK: - Search Events

    func searchQueryEntered(query: String) {
        PostHogManager.shared.searchQueryEntered(query: query)
    }

    func searchBarFocused() {
        PostHogManager.shared.searchBarFocused()
    }

    // MARK: - Settings Events

    func settingsPageOpened() {
        PostHogManager.shared.settingsPageOpened()
    }

    // MARK: - Page/Screen Views

    func pageViewed(_ pageName: String) {
        PostHogManager.shared.pageViewed(pageName)
    }

    // MARK: - Account Events

    func deleteAccountClicked() {
        PostHogManager.shared.deleteAccountClicked()
    }

    func deleteAccountConfirmed() {
        PostHogManager.shared.deleteAccountConfirmed()
    }

    func deleteAccountCancelled() {
        PostHogManager.shared.deleteAccountCancelled()
    }

    // MARK: - Navigation Events

    func tabChanged(tabName: String) {
        PostHogManager.shared.tabChanged(tabName: tabName)
    }

    func conversationDetailOpened(conversationId: String) {
        PostHogManager.shared.conversationDetailOpened(conversationId: conversationId)
    }

    // MARK: - Chat Events (Additional)

    func chatAppSelected(appId: String?, appName: String?) {
        PostHogManager.shared.chatAppSelected(appId: appId, appName: appName)
    }

    func chatCleared() {
        PostHogManager.shared.chatCleared()
    }

    func chatSessionCreated() {
        PostHogManager.shared.track("chat_session_created", properties: [:])
    }

    func chatSessionDeleted() {
        PostHogManager.shared.track("chat_session_deleted", properties: [:])
    }

    func messageRated(rating: Int) {
        let ratingString = rating == 1 ? "thumbs_up" : "thumbs_down"
        PostHogManager.shared.track("message_rated", properties: ["rating": ratingString])
    }

    func initialMessageGenerated(hasApp: Bool) {
        PostHogManager.shared.track("initial_message_generated", properties: ["has_app": hasApp])
    }

    func sessionTitleGenerated() {
        PostHogManager.shared.track("session_title_generated", properties: [:])
    }

    func chatStarredFilterToggled(enabled: Bool) {
        PostHogManager.shared.track("chat_starred_filter_toggled", properties: ["enabled": enabled])
    }

    func sessionRenamed() {
        PostHogManager.shared.track("session_renamed", properties: [:])
    }

    // MARK: - Claude Agent Events

    func chatAgentQueryCompleted(
        durationMs: Int,
        toolCallCount: Int,
        toolNames: [String],
        costUsd: Double,
        messageLength: Int,
        bridgeMode: String
    ) {
        let props: [String: Any] = [
            "duration_ms": durationMs,
            "tool_call_count": toolCallCount,
            "tool_names": toolNames.joined(separator: ","),
            "cost_usd": costUsd,
            "response_length": messageLength,
            "bridge_mode": bridgeMode
        ]
        PostHogManager.shared.track("chat_agent_query_completed", properties: props)
    }

    func chatToolCallCompleted(toolName: String, durationMs: Int, success: Bool = true, error: String? = nil) {
        let cleanName: String
        if toolName.hasPrefix("mcp__") {
            cleanName = String(toolName.split(separator: "__").last ?? Substring(toolName))
        } else {
            cleanName = toolName
        }
        var props: [String: Any] = [
            "tool_name": cleanName,
            "duration_ms": durationMs,
            "success": success
        ]
        if let error = error {
            props["error"] = String(error.prefix(200))
        }
        PostHogManager.shared.track("chat_tool_call_completed", properties: props)
    }

    func chatAgentError(error: String) {
        let props: [String: Any] = ["error": error]
        PostHogManager.shared.track("chat_agent_error", properties: props)
    }

    // MARK: - Conversation Events (Additional)

    func conversationReprocessed(conversationId: String, appId: String) {
        PostHogManager.shared.conversationReprocessed(conversationId: conversationId, appId: appId)
    }

    // MARK: - Settings Events (Additional)

    func settingToggled(setting: String, enabled: Bool) {
        PostHogManager.shared.settingToggled(setting: setting, enabled: enabled)
    }

    func languageChanged(language: String) {
        PostHogManager.shared.languageChanged(language: language)
    }

    // MARK: - Launch At Login Events

    func launchAtLoginStatusChecked(enabled: Bool) {
        PostHogManager.shared.launchAtLoginStatusChecked(enabled: enabled)
    }

    func launchAtLoginChanged(enabled: Bool, source: String) {
        PostHogManager.shared.launchAtLoginChanged(enabled: enabled, source: source)
    }

    // MARK: - Feedback Events

    func feedbackOpened() {
        PostHogManager.shared.feedbackOpened()
    }

    func feedbackSubmitted(feedbackLength: Int) {
        PostHogManager.shared.feedbackSubmitted(feedbackLength: feedbackLength)
    }

    // MARK: - Proactive Assistant Events (Desktop-specific)

    func focusAlertShown(app: String) {
        PostHogManager.shared.focusAlertShown(app: app)
    }

    func focusAlertDismissed(app: String, action: String) {
        PostHogManager.shared.focusAlertDismissed(app: app, action: action)
    }

    func taskExtracted(taskCount: Int) {
        PostHogManager.shared.taskExtracted(taskCount: taskCount)
    }

    func taskPromoted(taskCount: Int) {
        PostHogManager.shared.taskPromoted(taskCount: taskCount)
    }

    func taskCompleted(source: String?) {
        PostHogManager.shared.taskCompleted(source: source)
    }

    func taskDeleted(source: String?) {
        PostHogManager.shared.taskDeleted(source: source)
    }

    func taskAdded() {
        PostHogManager.shared.taskAdded()
    }

    func memoryExtracted(memoryCount: Int) {
        PostHogManager.shared.memoryExtracted(memoryCount: memoryCount)
    }

    func adviceGenerated(category: String?) {
        PostHogManager.shared.adviceGenerated(category: category)
    }

    // MARK: - Apps Events

    func appEnabled(appId: String, appName: String) {
        PostHogManager.shared.appEnabled(appId: appId, appName: appName)
    }

    func appDisabled(appId: String, appName: String) {
        PostHogManager.shared.appDisabled(appId: appId, appName: appName)
    }

    func appDetailViewed(appId: String, appName: String) {
        PostHogManager.shared.appDetailViewed(appId: appId, appName: appName)
    }

    // MARK: - Update Events

    func updateCheckStarted() {
        PostHogManager.shared.updateCheckStarted()
    }

    func updateAvailable(version: String) {
        PostHogManager.shared.updateAvailable(version: version)
    }

    func updateInstalled(version: String) {
        PostHogManager.shared.updateInstalled(version: version)
    }

    func updateNotFound() {
        PostHogManager.shared.updateNotFound()
    }

    func updateCheckFailed(error: String, errorDomain: String, errorCode: Int, underlyingError: String? = nil, underlyingDomain: String? = nil, underlyingCode: Int? = nil) {
        PostHogManager.shared.updateCheckFailed(error: error, errorDomain: errorDomain, errorCode: errorCode, underlyingError: underlyingError, underlyingDomain: underlyingDomain, underlyingCode: underlyingCode)
    }

    // MARK: - Notification Events

    func notificationSent(notificationId: String, title: String, assistantId: String) {
        PostHogManager.shared.notificationSent(notificationId: notificationId, title: title, assistantId: assistantId)
    }

    func notificationClicked(notificationId: String, title: String, assistantId: String) {
        PostHogManager.shared.notificationClicked(notificationId: notificationId, title: title, assistantId: assistantId)
    }

    func notificationDismissed(notificationId: String, title: String, assistantId: String) {
        PostHogManager.shared.notificationDismissed(notificationId: notificationId, title: title, assistantId: assistantId)
    }

    func notificationWillPresent(notificationId: String, title: String) {
        PostHogManager.shared.notificationWillPresent(notificationId: notificationId, title: title)
    }

    func notificationDelegateReady() {
        PostHogManager.shared.notificationDelegateReady()
    }

    // MARK: - Menu Bar Events

    func menuBarOpened() {
        PostHogManager.shared.menuBarOpened()
    }

    func menuBarActionClicked(action: String) {
        PostHogManager.shared.menuBarActionClicked(action: action)
    }

    // MARK: - Tier Events

    func tierChanged(tier: Int, reason: String) {
        PostHogManager.shared.tierChanged(tier: tier, reason: reason)
    }

    func chatBridgeModeChanged(from oldMode: String, to newMode: String) {
        PostHogManager.shared.chatBridgeModeChanged(from: oldMode, to: newMode)
    }

    // MARK: - Settings State

    func trackSettingsState(screenshotsEnabled: Bool, memoryExtractionEnabled: Bool, memoryNotificationsEnabled: Bool) {
        PostHogManager.shared.settingsStateTracked(screenshotsEnabled: screenshotsEnabled, memoryExtractionEnabled: memoryExtractionEnabled, memoryNotificationsEnabled: memoryNotificationsEnabled)
    }

    // MARK: - All Settings State (Comprehensive daily report)

    private let lastAllSettingsReportKey = "lastAllSettingsReportDate"

    func reportAllSettingsIfNeeded() {
        guard !Self.isDevBuild else { return }

        let defaults = UserDefaults.standard
        let lastReport = defaults.object(forKey: lastAllSettingsReportKey) as? Date ?? .distantPast
        guard !Calendar.current.isDateInToday(lastReport) else {
            log("Analytics: All settings already reported today, skipping")
            return
        }

        defaults.set(Date(), forKey: lastAllSettingsReportKey)

        let properties = collectAllSettings()

        PostHogManager.shared.allSettingsStateTracked(properties: properties)

        log("Analytics: All settings state reported (\(properties.count) properties)")
    }

    private func collectAllSettings() -> [String: Any] {
        var props: [String: Any] = [:]

        let ud = UserDefaults.standard

        // -- AI Chat Mode --
        props["chat_bridge_mode"] = ud.string(forKey: "chatBridgeMode") ?? "agentSDK"

        // -- UI Preferences --
        props["multi_chat_enabled"] = ud.bool(forKey: "multiChatEnabled")

        // -- Launch at Login --
        props["launch_at_login_enabled"] = LaunchAtLoginManager.shared.isEnabled

        // -- Dev Mode --
        props["dev_mode_enabled"] = ud.bool(forKey: "devModeEnabled")

        return props
    }

    // MARK: - Floating Bar Events

    func floatingBarToggled(visible: Bool, source: String) {
        let props: [String: Any] = [
            "visible": visible,
            "source": source
        ]
        PostHogManager.shared.track("floating_bar_toggled", properties: props)
    }

    func floatingBarAskFazmOpened(source: String) {
        let props: [String: Any] = ["source": source]
        PostHogManager.shared.track("floating_bar_ask_fazm_opened", properties: props)
    }

    func floatingBarAskFazmClosed() {
        PostHogManager.shared.track("floating_bar_ask_fazm_closed")
    }

    func floatingBarQuerySent(messageLength: Int, hasScreenshot: Bool) {
        let props: [String: Any] = [
            "message_length": messageLength,
            "has_screenshot": hasScreenshot
        ]
        PostHogManager.shared.track("floating_bar_query_sent", properties: props)
    }

    func floatingBarPTTStarted(mode: String) {
        let props: [String: Any] = ["mode": mode]
        PostHogManager.shared.track("floating_bar_ptt_started", properties: props)
    }

    func floatingBarPTTEnded(mode: String, hadTranscript: Bool, transcriptLength: Int) {
        let props: [String: Any] = [
            "mode": mode,
            "had_transcript": hadTranscript,
            "transcript_length": transcriptLength
        ]
        PostHogManager.shared.track("floating_bar_ptt_ended", properties: props)
    }

    // MARK: - Knowledge Graph Events

    func knowledgeGraphBuildStarted(filesIndexed: Int, hadExistingGraph: Bool) {
        let props: [String: Any] = [
            "files_indexed": filesIndexed,
            "had_existing_graph": hadExistingGraph
        ]
        PostHogManager.shared.track("knowledge_graph_build_started", properties: props)
    }

    func knowledgeGraphBuildCompleted(nodeCount: Int, edgeCount: Int, pollAttempts: Int, hadExistingGraph: Bool) {
        let props: [String: Any] = [
            "node_count": nodeCount,
            "edge_count": edgeCount,
            "poll_attempts": pollAttempts,
            "had_existing_graph": hadExistingGraph
        ]
        PostHogManager.shared.track("knowledge_graph_build_completed", properties: props)
    }

    func knowledgeGraphBuildFailed(reason: String, pollAttempts: Int, filesIndexed: Int) {
        let props: [String: Any] = [
            "reason": reason,
            "poll_attempts": pollAttempts,
            "files_indexed": filesIndexed
        ]
        PostHogManager.shared.track("knowledge_graph_build_failed", properties: props)
    }

    // MARK: - Floating Bar Response Metrics

    func floatingBarResponseReceived(durationMs: Int, responseLength: Int, toolCount: Int) {
        let props: [String: Any] = [
            "duration_ms": durationMs,
            "response_length": responseLength,
            "tool_count": toolCount
        ]
        PostHogManager.shared.track("floating_bar_response_received", properties: props)
    }

    // MARK: - Chat Conversation Depth

    func chatConversationDepth(messageCount: Int, sessionId: String?) {
        var props: [String: Any] = [
            "message_count": messageCount
        ]
        if let sid = sessionId {
            props["session_id"] = sid
        }
        PostHogManager.shared.track("chat_conversation_depth", properties: props)
    }

    // MARK: - Credit Exhaustion

    func creditExhausted(previousMode: String) {
        let props: [String: Any] = [
            "previous_mode": previousMode
        ]
        PostHogManager.shared.track("credit_exhausted", properties: props)
    }

    // MARK: - Display Info

    func trackDisplayInfo() {
        guard let screen = NSScreen.main else { return }

        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let safeAreaInsets = screen.safeAreaInsets

        let hasNotch = safeAreaInsets.top > 0
        let menuBarHeight = frame.height - visibleFrame.height - visibleFrame.origin.y

        let displayInfo: [String: Any] = [
            "screen_width": Int(frame.width),
            "screen_height": Int(frame.height),
            "has_notch": hasNotch,
            "safe_area_top": Int(safeAreaInsets.top),
            "menu_bar_height": Int(menuBarHeight),
            "scale_factor": screen.backingScaleFactor
        ]

        PostHogManager.shared.displayInfoTracked(info: displayInfo)
    }
}
