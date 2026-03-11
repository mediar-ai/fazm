import Foundation
import PostHog

/// Singleton manager for PostHog analytics with Session Replay
/// Tracks analytics events via PostHog
@MainActor
class PostHogManager {
    static let shared = PostHogManager()

    private var isInitialized = false

    // PostHog configuration
    private let apiKey = "phc_TWwTa7D5GcjE4PprY55tJVfPKBC7kmLGiFUDZxBbYRQ"
    private let host = "https://us.i.posthog.com"

    private init() {}

    // MARK: - Initialization

    /// Initialize PostHog with analytics
    func initialize() {
        guard !isInitialized else { return }

        let config = PostHogConfig(apiKey: apiKey, host: host)

        // Disable automatic lifecycle events — PostHog's observer calls setResourceValues(isExcludedFromBackupKey:)
        // synchronously on the main thread (via NSApplicationDidFinishLaunchingNotification), which XPCs to the
        // mds (Spotlight) daemon and can hang for 2000ms+ when the daemon is slow. We already track lifecycle
        // events manually via AnalyticsManager.shared.appLaunched() / appBecameActive() etc.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = true
        config.preloadFeatureFlags = true
        // Keep the anonymous ID across reset() so that identifyAuthUser() can properly
        // merge the anonymous person with the authenticated person. Without this, reset()
        // generates a new anonymous ID and the old events become orphaned.
        config.reuseAnonymousId = true

        PostHogSDK.shared.setup(config)

        isInitialized = true
        log("PostHog: Initialized successfully")
    }

    // MARK: - User Identification

    /// Set device properties without triggering identification.
    /// Never call PostHogSDK.identify() here — it sets isIdentified=true permanently,
    /// which blocks identifyAuthUser() from changing the distinct_id to the Firebase UID.
    /// The only place that should call PostHogSDK.identify() is identifyAuthUser().
    func identify() {
        guard isInitialized else { return }

        // If user is authenticated, identifyAuthUser() will be called shortly — skip.
        if UserDefaults.standard.string(forKey: "auth_tokenUserId")?.isEmpty == false {
            log("PostHog: Skipping device identify — authenticated user will be identified via identifyAuthUser()")
            return
        }

        // For anonymous users, just set device properties without calling identify().
        // PostHog's auto-generated anonymous ID is sufficient for pre-auth tracking.
        let properties: [String: Any] = [
            "platform": "macos",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]
        PostHogSDK.shared.capture("$set", properties: ["$set": properties])
        log("PostHog: Set device properties (anonymous)")
    }

    /// Get or create a stable device identifier
    private func getOrCreateDeviceId() -> String {
        let key = "analytics_device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }

    /// Set a specific user property without triggering identification.
    /// Uses capture($set) instead of identify() because the PostHog SDK's identify()
    /// sets isIdentified=true, which permanently locks the distinct_id and prevents
    /// the real identifyAuthUser() call from changing it to the Firebase UID.
    func setUserProperty(key: String, value: Any) {
        guard isInitialized else { return }
        PostHogSDK.shared.capture("$set", properties: ["$set": [key: value]])
    }

    /// Identify an authenticated user (links device to Firebase user).
    /// This is the ONLY method that should call PostHogSDK.identify().
    func identifyAuthUser(userId: String, properties: [String: Any]) {
        guard isInitialized else { return }

        let currentDistinctId = PostHogSDK.shared.getDistinctId()

        // If already identified as this user, just update properties.
        if currentDistinctId == userId {
            PostHogSDK.shared.capture("$set", properties: ["$set": properties])
            log("PostHog: Updated auth user properties for \(userId)")
            return
        }

        // Reset the SDK's isIdentified flag so identify() can change the distinct_id.
        // Without this, PostHog SDK silently ignores identify() calls once isIdentified=true
        // (set by any prior identify() call, including accidental ones from setUserProperty).
        // reset() clears the persisted state, allowing the anonymous→authenticated merge.
        PostHogSDK.shared.reset()
        PostHogSDK.shared.identify(userId, userProperties: properties)
        log("PostHog: Identified auth user \(userId) (was: \(currentDistinctId))")
    }

    /// Register super properties that are sent with every event
    func register(properties: [String: Any]) {
        guard isInitialized else { return }
        PostHogSDK.shared.register(properties)
    }

    // MARK: - Event Tracking

    /// Track an event with optional properties
    func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard isInitialized else { return }
        PostHogSDK.shared.capture(eventName, properties: properties)
        log("PostHog: Tracked event '\(eventName)'")
    }

    // MARK: - Screen Tracking

    /// Track a screen view
    func screen(_ screenName: String, properties: [String: Any]? = nil) {
        guard isInitialized else { return }
        PostHogSDK.shared.screen(screenName, properties: properties)
    }

    // MARK: - Opt In/Out

    /// Opt in to tracking
    func optIn() {
        guard isInitialized else { return }
        PostHogSDK.shared.optIn()
    }

    /// Opt out of tracking
    func optOut() {
        guard isInitialized else { return }
        PostHogSDK.shared.optOut()
    }

    /// Check if tracking is opted out
    var hasOptedOut: Bool {
        guard isInitialized else { return true }
        return !PostHogSDK.shared.isOptOut()
    }

    // MARK: - Reset

    /// Reset the user (call on sign out)
    func reset() {
        guard isInitialized else { return }
        PostHogSDK.shared.reset()
        log("PostHog: Reset user")
    }

    // MARK: - Feature Flags

    /// Check if a feature flag is enabled
    func isFeatureEnabled(_ flag: String) -> Bool {
        guard isInitialized else { return false }
        return PostHogSDK.shared.isFeatureEnabled(flag)
    }

    /// Get feature flag value
    func getFeatureFlag(_ flag: String) -> Any? {
        guard isInitialized else { return nil }
        return PostHogSDK.shared.getFeatureFlag(flag)
    }

    /// Reload feature flags
    func reloadFeatureFlags() {
        guard isInitialized else { return }
        PostHogSDK.shared.reloadFeatureFlags()
    }
}

// MARK: - Analytics Events

extension PostHogManager {

    // MARK: - Onboarding Events

    func onboardingStepCompleted(step: Int, stepName: String) {
        track("Onboarding Step \(stepName) Completed", properties: [
            "step": step
        ])
    }

    func onboardingCompleted() {
        track("Onboarding Completed")
    }

    // MARK: - Authentication Events

    func signInStarted(provider: String) {
        track("Sign In Started", properties: [
            "provider": provider
        ])
    }

    func signInCompleted(provider: String) {
        track("Sign In Completed", properties: [
            "provider": provider
        ])
    }

    func signInFailed(provider: String, error: String) {
        track("Sign In Failed", properties: [
            "provider": provider,
            "error": error
        ])
    }

    func signedOut() {
        track("Signed Out")
    }

    // MARK: - Monitoring Events

    func monitoringStarted() {
        track("Monitoring Started")
    }

    func monitoringStopped() {
        track("Monitoring Stopped")
    }

    func distractionDetected(app: String, windowTitle: String?) {
        var properties: [String: Any] = [
            "app": app
        ]
        if let title = windowTitle {
            properties["window_title"] = title
        }
        track("Distraction Detected", properties: properties)
    }

    func focusRestored(app: String) {
        track("Focus Restored", properties: [
            "app": app
        ])
    }

    // MARK: - Recording Events

    func transcriptionStarted() {
        track("Phone Mic Recording Started")
    }

    func transcriptionStopped(wordCount: Int) {
        track("Phone Mic Recording Stopped", properties: [
            "word_count": wordCount
        ])
    }

    func recordingError(error: String) {
        track("Phone Mic Recording Error", properties: [
            "error": error
        ])
    }

    // MARK: - Permission Events

    func permissionRequested(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Requested", properties: props)
    }

    func permissionGranted(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Granted", properties: props)
    }

    func permissionDenied(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Denied", properties: props)
    }

    func permissionSkipped(permission: String, extraProperties: [String: Any] = [:]) {
        var props: [String: Any] = ["permission": permission]
        for (key, value) in extraProperties {
            props[key] = value
        }
        track("Permission Skipped", properties: props)
    }

    /// Track when ScreenCaptureKit broken state is detected
    func screenCaptureBrokenDetected() {
        track("Screen Capture Broken Detected", properties: [:])
    }

    /// Track when user clicks reset button or notification
    func screenCaptureResetClicked(source: String) {
        track("Screen Capture Reset Clicked", properties: [
            "source": source
        ])
    }

    /// Track when screen capture reset completes
    func screenCaptureResetCompleted(success: Bool) {
        track("Screen Capture Reset Completed", properties: [
            "success": success
        ])
    }

    func notificationRepairTriggered(reason: String, previousStatus: String, currentStatus: String) {
        track("Notification Repair Triggered", properties: [
            "reason": reason,
            "previous_status": previousStatus,
            "current_status": currentStatus
        ])
    }

    func notificationSettingsChecked(
        authStatus: String,
        alertStyle: String,
        soundEnabled: Bool,
        badgeEnabled: Bool,
        bannersDisabled: Bool
    ) {
        track("Notification Settings Checked", properties: [
            "auth_status": authStatus,
            "alert_style": alertStyle,
            "sound_enabled": soundEnabled,
            "badge_enabled": badgeEnabled,
            "banners_disabled": bannersDisabled
        ])
    }

    // MARK: - App Lifecycle Events

    func appLaunched() {
        track("App Launched", properties: [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }

    /// Track first launch with comprehensive system diagnostics
    func firstLaunch(diagnostics: [String: Any]) {
        track("First Launch", properties: diagnostics)
    }

    func appBecameActive() {
        track("App Became Active")
    }

    func appResignedActive() {
        track("App Resigned Active")
    }

    // MARK: - Page/Screen Views (PostHog specific)

    func pageViewed(_ pageName: String) {
        screen(pageName)
        track("Page Viewed", properties: ["page": pageName])
    }

    // MARK: - Conversation Events
    // Note: The event is named "Memory Created" in analytics for historical reasons,
    // but it actually tracks when a conversation/recording is created, not a "memory".
    // This matches Flutter's naming for analytics consistency.

    func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {
        var properties: [String: Any] = [
            "conversation_id": conversationId,
            "source": source
        ]
        if let duration = durationSeconds {
            properties["duration_seconds"] = duration
        }
        track("Memory Created", properties: properties)
    }

    func memoryDeleted(conversationId: String) {
        track("Memory Deleted", properties: [
            "conversation_id": conversationId
        ])
    }

    func memoryShareButtonClicked(conversationId: String) {
        track("Memory Share Button Clicked", properties: [
            "conversation_id": conversationId
        ])
    }

    func memoryListItemClicked(conversationId: String) {
        track("Memory List Item Clicked", properties: [
            "conversation_id": conversationId
        ])
    }

    // MARK: - Chat Events

    func chatMessageSent(messageLength: Int, hasContext: Bool = false, source: String) {
        track("Chat Message Sent", properties: [
            "message_length": messageLength,
            "has_context": hasContext,
            "source": source
        ])
    }

    // MARK: - Search Events

    func searchQueryEntered(query: String) {
        track("Search Query Entered", properties: [
            "query_length": query.count
        ])
    }

    func searchBarFocused() {
        track("Search Bar Focused")
    }

    // MARK: - Settings Events

    func settingsPageOpened() {
        track("Settings Page Opened")
    }

    // MARK: - Account Events

    func deleteAccountClicked() {
        track("Delete Account Clicked")
    }

    func deleteAccountConfirmed() {
        track("Delete Account Confirmed")
    }

    func deleteAccountCancelled() {
        track("Delete Account Cancelled")
    }

    // MARK: - Navigation Events

    func tabChanged(tabName: String) {
        track("Tab Changed", properties: [
            "tab_name": tabName
        ])
    }

    func conversationDetailOpened(conversationId: String) {
        track("Conversation Detail Opened", properties: [
            "conversation_id": conversationId
        ])
    }

    // MARK: - Chat Events (Additional)

    func chatAppSelected(appId: String?, appName: String?) {
        var properties: [String: Any] = [:]
        if let id = appId { properties["app_id"] = id }
        if let name = appName { properties["app_name"] = name }
        track("Chat App Selected", properties: properties.isEmpty ? nil : properties)
    }

    func chatCleared() {
        track("Chat Cleared")
    }

    // MARK: - Conversation Events (Additional)

    func conversationReprocessed(conversationId: String, appId: String) {
        track("Conversation Reprocessed", properties: [
            "conversation_id": conversationId,
            "app_id": appId
        ])
    }

    // MARK: - Settings Events (Additional)

    func settingToggled(setting: String, enabled: Bool) {
        track("Setting Toggled", properties: [
            "setting": setting,
            "enabled": enabled
        ])
    }

    func languageChanged(language: String) {
        track("Language Changed", properties: [
            "language": language
        ])
    }

    // MARK: - Launch At Login Events

    func launchAtLoginStatusChecked(enabled: Bool) {
        track("Launch At Login Status", properties: [
            "enabled": enabled
        ])
    }

    func launchAtLoginChanged(enabled: Bool, source: String) {
        track("Launch At Login Changed", properties: [
            "enabled": enabled,
            "source": source
        ])
    }

    // MARK: - Feedback Events

    func feedbackOpened() {
        track("Feedback Opened")
    }

    func feedbackSubmitted(feedbackLength: Int) {
        track("Feedback Submitted", properties: [
            "feedback_length": feedbackLength
        ])
    }

    // MARK: - Proactive Assistant Events (Desktop-specific)

    func focusAlertShown(app: String) {
        track("Focus Alert Shown", properties: [
            "app": app
        ])
    }

    func focusAlertDismissed(app: String, action: String) {
        track("Focus Alert Dismissed", properties: [
            "app": app,
            "action": action
        ])
    }

    func taskExtracted(taskCount: Int) {
        track("Task Extracted", properties: [
            "task_count": taskCount
        ])
    }

    func taskPromoted(taskCount: Int) {
        track("Task Promoted", properties: [
            "task_count": taskCount
        ])
    }

    func taskCompleted(source: String?) {
        track("Task Completed", properties: [
            "source": source ?? "unknown"
        ])
    }

    func taskDeleted(source: String?) {
        track("Task Deleted", properties: [
            "source": source ?? "unknown"
        ])
    }

    func taskAdded() {
        track("Task Added")
    }

    func memoryExtracted(memoryCount: Int) {
        track("Memory Extracted", properties: [
            "memory_count": memoryCount
        ])
    }

    func adviceGenerated(category: String?) {
        var properties: [String: Any] = [:]
        if let cat = category { properties["category"] = cat }
        track("Advice Generated", properties: properties.isEmpty ? nil : properties)
    }

    // MARK: - Apps Events

    func appEnabled(appId: String, appName: String) {
        track("App Enabled", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    func appDisabled(appId: String, appName: String) {
        track("App Disabled", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    func appDetailViewed(appId: String, appName: String) {
        track("App Detail Viewed", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    // MARK: - Update Events

    func updateCheckStarted() {
        track("Update Check Started")
    }

    func updateAvailable(version: String) {
        track("Update Available", properties: [
            "version": version
        ])
    }

    func updateInstalled(version: String) {
        track("Update Installed", properties: [
            "version": version
        ])
    }

    func updateNotFound() {
        track("Update Not Found")
    }

    func updateCheckFailed(error: String, errorDomain: String, errorCode: Int, underlyingError: String? = nil, underlyingDomain: String? = nil, underlyingCode: Int? = nil) {
        var props: [String: Any] = [
            "error": error,
            "error_domain": errorDomain,
            "error_code": errorCode
        ]
        if let underlyingError { props["underlying_error"] = underlyingError }
        if let underlyingDomain { props["underlying_domain"] = underlyingDomain }
        if let underlyingCode { props["underlying_code"] = underlyingCode }
        track("Update Check Failed", properties: props)
    }

    // MARK: - Notification Events

    func notificationSent(notificationId: String, title: String, assistantId: String) {
        track("Notification Sent", properties: [
            "notification_id": notificationId,
            "title": title,
            "assistant_id": assistantId
        ])
    }

    func notificationClicked(notificationId: String, title: String, assistantId: String) {
        track("Notification Clicked", properties: [
            "notification_id": notificationId,
            "title": title,
            "assistant_id": assistantId
        ])
    }

    func notificationDismissed(notificationId: String, title: String, assistantId: String) {
        track("Notification Dismissed", properties: [
            "notification_id": notificationId,
            "title": title,
            "assistant_id": assistantId
        ])
    }

    func notificationWillPresent(notificationId: String, title: String) {
        track("Notification Will Present", properties: [
            "notification_id": notificationId,
            "title": title
        ])
    }

    func notificationDelegateReady() {
        track("Notification Delegate Ready")
    }

    // MARK: - Menu Bar Events

    func menuBarOpened() {
        track("Menu Bar Opened")
    }

    func menuBarActionClicked(action: String) {
        track("Menu Bar Action Clicked", properties: [
            "action": action
        ])
    }

    // MARK: - Tier Events

    func tierChanged(tier: Int, reason: String) {
        track("Tier Changed", properties: [
            "tier": tier,
            "reason": reason
        ])
    }

    func chatBridgeModeChanged(from oldMode: String, to newMode: String) {
        track("chat_bridge_mode_changed", properties: [
            "from": oldMode,
            "to": newMode
        ])
    }

    // MARK: - Settings State

    func settingsStateTracked(screenshotsEnabled: Bool, memoryExtractionEnabled: Bool, memoryNotificationsEnabled: Bool) {
        track("Settings State", properties: [
            "screenshots_enabled": screenshotsEnabled,
            "memory_extraction_enabled": memoryExtractionEnabled,
            "memory_notifications_enabled": memoryNotificationsEnabled
        ])
    }

    /// Comprehensive all-settings snapshot (fired on app launch, at most once per day)
    func allSettingsStateTracked(properties: [String: Any]) {
        track("All Settings State", properties: properties)
    }

    // MARK: - Display Info

    func displayInfoTracked(info: [String: Any]) {
        track("Display Info", properties: info)
    }
}
