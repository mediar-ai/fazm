import Foundation
import AppKit
import IOKit

/// Manages referral code generation, tracking, and validation.
final class ReferralService {
    static let shared = ReferralService()

    private let backendUrl: String
    private let deviceId: String

    /// The user's referral code (cached locally after first generation).
    private(set) var referralCode: String? {
        didSet { UserDefaults.standard.set(referralCode, forKey: "fazm_referral_code") }
    }

    /// The referral URL to share.
    private(set) var referralUrl: String? {
        didSet { UserDefaults.standard.set(referralUrl, forKey: "fazm_referral_url") }
    }

    /// Whether this user was referred by someone (has a stored referral code from signup).
    var wasReferred: Bool {
        UserDefaults.standard.string(forKey: "fazm_referred_by_code") != nil
    }

    private init() {
        self.backendUrl = Self.env("FAZM_BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.deviceId = Self.getDeviceId()
        self.referralCode = UserDefaults.standard.string(forKey: "fazm_referral_code")
        self.referralUrl = UserDefaults.standard.string(forKey: "fazm_referral_url")
    }

    // MARK: - Generate Referral Code

    /// Generates (or retrieves existing) referral code for the current user.
    func generateReferralCode() async throws -> (code: String, url: String) {
        if let code = referralCode, let url = referralUrl, !code.isEmpty {
            return (code, url)
        }

        guard !backendUrl.isEmpty else {
            throw ReferralError.notConfigured
        }

        let token = try await AuthService.shared.getIdToken(forceRefresh: false)
        let url = URL(string: "\(backendUrl)/api/referral/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            log("ReferralService: generate failed (\(statusCode)): \(msg)")
            throw ReferralError.serverError(msg)
        }

        struct GenerateResponse: Decodable {
            let code: String
            let referral_url: String
        }

        let result = try JSONDecoder().decode(GenerateResponse.self, from: data)
        referralCode = result.code
        referralUrl = result.referral_url
        log("ReferralService: generated code \(result.code)")
        Task { @MainActor in AnalyticsManager.shared.referralCodeGenerated(code: result.code) }
        return (result.code, result.referral_url)
    }

    // MARK: - Track Signup (for referred users)

    /// Called when the app receives a referral code (via URL scheme or manual entry).
    /// Validates with backend first, only stores locally on success.
    func trackReferralSignup(code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }

        // Don't re-track if already referred
        if UserDefaults.standard.string(forKey: "fazm_referred_by_code") != nil {
            log("ReferralService: already has referral code, skipping")
            return
        }

        // Client-side self-referral check
        if trimmed == referralCode {
            log("ReferralService: self-referral blocked (own code \(trimmed))")
            return
        }

        guard !backendUrl.isEmpty else { return }

        do {
            let token = try await AuthService.shared.getIdToken(forceRefresh: false)
            let url = URL(string: "\(backendUrl)/api/referral/track-signup")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 10

            let body = ["referral_code": trimmed]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            log("ReferralService: track-signup status=\(statusCode)")

            // Only store locally and fire analytics if backend accepted it
            if statusCode == 200 {
                UserDefaults.standard.set(trimmed, forKey: "fazm_referred_by_code")
                Task { @MainActor in AnalyticsManager.shared.referralSignupTracked(code: trimmed) }
            } else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                log("ReferralService: track-signup rejected (\(statusCode)): \(msg)")
            }
        } catch {
            log("ReferralService: track-signup error: \(error.localizedDescription)")
        }
    }

    // MARK: - Validate (increment floating bar messages for referred users)

    /// Called after each floating_bar_query_sent for referred users.
    /// Increments the message counter on the backend and checks if reward threshold is met.
    func validateFloatingBarMessage() async {
        guard wasReferred else { return }
        guard !backendUrl.isEmpty else { return }

        do {
            let token = try await AuthService.shared.getIdToken(forceRefresh: false)
            let url = URL(string: "\(backendUrl)/api/referral/validate")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{}".data(using: .utf8)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode == 200 {
                struct ValidateResponse: Decodable {
                    let message_count: Int
                    let completed: Bool
                    let reward_granted: Bool
                }
                if let result = try? JSONDecoder().decode(ValidateResponse.self, from: data) {
                    log("ReferralService: validate — messages=\(result.message_count) completed=\(result.completed) rewarded=\(result.reward_granted)")
                    Task { @MainActor in AnalyticsManager.shared.referralMessageValidated(count: result.message_count, completed: result.completed) }
                    if result.completed {
                        // Clear the referral tracking — no more calls needed
                        UserDefaults.standard.set(true, forKey: "fazm_referral_completed")
                    }
                }
            }
        } catch {
            log("ReferralService: validate error: \(error.localizedDescription)")
        }
    }

    /// Whether this referred user has already completed the referral (5 messages sent).
    var isReferralCompleted: Bool {
        UserDefaults.standard.bool(forKey: "fazm_referral_completed")
    }

    // MARK: - Copy & Share

    /// Generates the referral code and copies the link to clipboard.
    func copyReferralLink() async throws {
        let (_, url) = try await generateReferralCode()
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
        log("ReferralService: copied referral link to clipboard")
        if let code = referralCode {
            Task { @MainActor in AnalyticsManager.shared.referralLinkCopied(code: code) }
        }
    }

    // MARK: - Referral Status (for Settings panel)

    struct ReferralStatusResponse: Decodable {
        let code: String
        let referral_url: String
        let referred_count: Int
        let completed_count: Int
        let reward_months: Int
    }

    /// Fetches referral stats from the backend.
    func fetchReferralStatus() async throws -> ReferralStatusResponse {
        guard !backendUrl.isEmpty else { throw ReferralError.notConfigured }

        let token = try await AuthService.shared.getIdToken(forceRefresh: false)
        let url = URL(string: "\(backendUrl)/api/referral/status")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw ReferralError.serverError(msg)
        }

        return try JSONDecoder().decode(ReferralStatusResponse.self, from: data)
    }

    // MARK: - Errors

    enum ReferralError: Error, LocalizedError {
        case notConfigured
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Referral service not configured"
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
