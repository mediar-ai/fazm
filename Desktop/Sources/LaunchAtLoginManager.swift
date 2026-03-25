import Foundation
import ServiceManagement
import Sentry

/// Manages the app's launch at login status using SMAppService (macOS 13+)
@MainActor
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var statusDescription: String = "Checking..."
    @Published private(set) var lastError: String? = nil

    private init() {
        refreshStatus()
    }

    /// Synchronously reads SMAppService status and updates published properties
    func refreshStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        switch status {
        case .enabled:
            statusDescription = "App will start when you log in"
        case .notRegistered:
            statusDescription = "App won't start automatically"
        case .notFound:
            statusDescription = "Login item not found"
        case .requiresApproval:
            statusDescription = "Requires approval in System Settings → General → Login Items"
        @unknown default:
            statusDescription = "Unknown status"
        }
    }

    /// Enables or disables launch at login
    /// - Parameter enabled: Whether the app should launch at login
    /// - Returns: true if the operation succeeded
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log("LaunchAtLogin: Successfully registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                log("LaunchAtLogin: Successfully unregistered from launch at login")
            }
            lastError = nil
            refreshStatus()
            return true
        } catch {
            let errorMsg = error.localizedDescription
            log("LaunchAtLogin: Failed to \(enabled ? "register" : "unregister"): \(errorMsg)")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: enabled ? "register" : "unregister", key: "login_item_action")
                scope.setTag(value: "\(SMAppService.mainApp.status)", key: "sma_status")
            }
            lastError = errorMsg
            refreshStatus()
            return false
        }
    }

    /// Opens System Settings to the Login Items pane
    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
