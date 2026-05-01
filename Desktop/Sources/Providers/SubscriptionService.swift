import Foundation
import IOKit
import AppKit

/// Manages Stripe subscription state — checkout, status polling, and local caching.
final class SubscriptionService {
    static let shared = SubscriptionService()

    private(set) var isActive: Bool {
        didSet { UserDefaults.standard.set(isActive, forKey: "fazm_sub_active") }
    }
    private(set) var status: String { // "active", "trialing", "past_due", "canceled", "none"
        didSet { UserDefaults.standard.set(status, forKey: "fazm_sub_status") }
    }
    private(set) var currentPeriodEnd: Date? {
        didSet { UserDefaults.standard.set(currentPeriodEnd, forKey: "fazm_sub_period_end") }
    }

    private let backendUrl: String
    private let deviceId: String

    // MARK: - Trial & Paywall

    let trialDays = 0
    let freeMessagesPerDay = 0

    /// Date the user's trial started — uses Firebase account creation date (actual signup).
    /// Returns cached value if available; otherwise falls back to now (fetchAccountCreationDate
    /// will correct it asynchronously on launch).
    var trialStartDate: Date {
        let key = "fazm_trial_start_date"
        if let stored = UserDefaults.standard.object(forKey: key) as? Date {
            return stored
        }
        // Fallback: set to now; fetchAccountCreationDate() will correct it shortly
        let now = Date()
        UserDefaults.standard.set(now, forKey: key)
        return now
    }

    /// Fetches the user's Firebase account creation date via REST API and updates trial start.
    /// Called on every launch to ensure trial start reflects the actual signup date.
    func fetchAccountCreationDate() async {
        let key = "fazm_trial_start_date"

        // Get the ID token and Firebase API key
        guard let idToken = try? await AuthService.shared.getIdToken(forceRefresh: false) else {
            log("SubscriptionService: fetchAccountCreationDate skipped — no ID token")
            return
        }
        let firebaseApiKey = Self.env("FIREBASE_API_KEY")
        guard !firebaseApiKey.isEmpty else {
            log("SubscriptionService: fetchAccountCreationDate skipped — no FIREBASE_API_KEY")
            return
        }

        // Query Firebase Auth REST API for user info
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=\(firebaseApiKey)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["idToken": idToken])
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                log("SubscriptionService: fetchAccountCreationDate failed — HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let users = json["users"] as? [[String: Any]],
                  let user = users.first,
                  let createdAtMs = user["createdAt"] as? String,
                  let createdAtMsInt = Double(createdAtMs) else {
                log("SubscriptionService: fetchAccountCreationDate — could not parse response")
                return
            }

            let creationDate = Date(timeIntervalSince1970: createdAtMsInt / 1000.0)
            let current = UserDefaults.standard.object(forKey: key) as? Date

            // Update if no stored date or Firebase date is earlier
            if current == nil || creationDate < current! {
                UserDefaults.standard.set(creationDate, forKey: key)
                log("SubscriptionService: trial start set to account creation date: \(creationDate)")
            } else {
                log("SubscriptionService: trial start already correct (\(current!))")
            }
        } catch {
            log("SubscriptionService: fetchAccountCreationDate error: \(error.localizedDescription)")
        }
    }

    /// Whether the free trial period has expired.
    var isTrialExpired: Bool {
        let elapsed = Calendar.current.dateComponents([.day], from: trialStartDate, to: Date()).day ?? 0
        return elapsed >= trialDays
    }

    /// Number of messages sent today (resets daily).
    var dailyMessageCount: Int {
        get {
            let today = Calendar.current.startOfDay(for: Date())
            let storedDay = UserDefaults.standard.object(forKey: "fazm_msg_count_day") as? Date ?? .distantPast
            if Calendar.current.isDate(storedDay, inSameDayAs: today) {
                return UserDefaults.standard.integer(forKey: "fazm_msg_count")
            }
            return 0
        }
        set {
            let today = Calendar.current.startOfDay(for: Date())
            UserDefaults.standard.set(today, forKey: "fazm_msg_count_day")
            UserDefaults.standard.set(newValue, forKey: "fazm_msg_count")
        }
    }

    /// Increment the daily message counter. Call this when the user sends a message.
    func incrementMessageCount() {
        dailyMessageCount += 1
    }

    /// Whether the paywall should be shown right now.
    /// Hard paywall: any user without an active Stripe subscription is gated immediately.
    /// No free trial, no free daily messages.
    func shouldShowPaywall() -> Bool {
        return !isActive
    }

    private init() {
        self.backendUrl = Self.env("FAZM_BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.deviceId = Self.getDeviceId()
        // Restore cached subscription state
        self.isActive = UserDefaults.standard.bool(forKey: "fazm_sub_active")
        self.status = UserDefaults.standard.string(forKey: "fazm_sub_status") ?? "none"
        self.currentPeriodEnd = UserDefaults.standard.object(forKey: "fazm_sub_period_end") as? Date
        // Touch trialStartDate to ensure it's set on first run
        _ = trialStartDate
        // Fetch account creation date and refresh subscription in background
        Task {
            await fetchAccountCreationDate()
            await refreshStatus()
        }
    }

    // MARK: - Open Checkout

    /// Creates a Stripe Checkout Session via the backend and opens it in the user's browser.
    func openCheckout() async throws {
        guard !backendUrl.isEmpty else {
            log("SubscriptionService: missing FAZM_BACKEND_URL")
            throw SubscriptionError.notConfigured
        }

        let token = try await AuthService.shared.getIdToken(forceRefresh: false)
        let url = URL(string: "\(backendUrl)/api/stripe/create-checkout-session")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // The backend constructs the actual success/cancel URLs using its own
        // redirect endpoint, so we don't need to send them from the client.
        let body: [String: String] = [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            log("SubscriptionService: checkout failed (\(statusCode)): \(msg)")
            throw SubscriptionError.serverError(msg)
        }

        struct CheckoutResponse: Decodable {
            let checkout_url: String
            let session_id: String
        }

        let checkout = try JSONDecoder().decode(CheckoutResponse.self, from: data)
        log("SubscriptionService: opening checkout \(checkout.session_id)")
        Task { @MainActor in AnalyticsManager.shared.subscriptionCheckoutOpened(sessionId: checkout.session_id) }

        if let checkoutURL = URL(string: checkout.checkout_url) {
            _ = await MainActor.run {
                NSWorkspace.shared.open(checkoutURL)
            }
        }

        // Poll for subscription activation after checkout opens
        startPostCheckoutPolling()
    }

    // MARK: - Billing Portal

    /// Opens the Stripe Billing Portal so the user can manage their subscription.
    func openBillingPortal() async throws {
        guard !backendUrl.isEmpty else {
            log("SubscriptionService: missing FAZM_BACKEND_URL")
            throw SubscriptionError.notConfigured
        }

        let token = try await AuthService.shared.getIdToken(forceRefresh: false)
        let url = URL(string: "\(backendUrl)/api/stripe/create-portal-session")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            log("SubscriptionService: portal session failed (\(statusCode)): \(msg)")
            throw SubscriptionError.serverError(msg)
        }

        struct PortalResponse: Decodable {
            let portal_url: String
        }

        let portal = try JSONDecoder().decode(PortalResponse.self, from: data)
        log("SubscriptionService: opening billing portal")

        if let portalURL = URL(string: portal.portal_url) {
            _ = await MainActor.run {
                NSWorkspace.shared.open(portalURL)
            }
        }
    }

    /// Polls subscription status every 5 seconds after checkout opens.
    /// Stops when active or after 5 minutes.
    private func startPostCheckoutPolling() {
        Task {
            let maxAttempts = 60 // 5 minutes at 5-second intervals
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let active = await refreshStatus()
                if active {
                    log("SubscriptionService: subscription activated after checkout")
                    return
                }
            }
            log("SubscriptionService: post-checkout polling timed out")
        }
    }

    // MARK: - Check Status

    /// Fetches subscription status from the backend.
    @discardableResult
    func refreshStatus() async -> Bool {
        guard !backendUrl.isEmpty else { return false }

        do {
            let token = try await AuthService.shared.getIdToken(forceRefresh: false)
            let url = URL(string: "\(backendUrl)/api/stripe/subscription-status")!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard statusCode == 200 else {
                log("SubscriptionService: status check failed (\(statusCode))")
                return false
            }

            struct StatusResponse: Decodable {
                let active: Bool
                let status: String
                let current_period_end: Int64?
            }

            let result = try JSONDecoder().decode(StatusResponse.self, from: data)
            let wasActive = isActive
            isActive = result.active
            status = result.status
            if let end = result.current_period_end {
                currentPeriodEnd = Date(timeIntervalSince1970: TimeInterval(end))
            }

            log("SubscriptionService: status=\(result.status) active=\(result.active)")
            if result.active && !wasActive {
                Task { @MainActor in AnalyticsManager.shared.subscriptionActivated(status: result.status) }
            }
            return result.active
        } catch {
            log("SubscriptionService: status check error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Errors

    enum SubscriptionError: Error, LocalizedError {
        case notConfigured
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Subscription service not configured"
            case .serverError(let msg): return "Server error: \(msg)"
            }
        }
    }

    // MARK: - Helpers

    private static func env(_ key: String) -> String {
        if let ptr = getenv(key) { return String(cString: ptr) }
        return ""
    }

    private static func getDeviceId() -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return UUID().uuidString }
        defer { IOObjectRelease(platformExpert) }

        if let uuidCF = IORegistryEntryCreateCFProperty(
            platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String {
            return uuidCF
        }
        return UUID().uuidString
    }
}
