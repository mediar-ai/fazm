import Foundation

/// Manages Vertex AI OAuth token lifecycle for the built-in Claude account.
/// Fetches subject tokens from the Fazm backend and writes ADC files for Google SDK.
actor VertexTokenManager {

    struct VertexConfig {
        let adcFilePath: String
        let projectId: String
        let region: String
    }

    // MARK: - Configuration

    private let backendUrl: String
    private let backendSecret: String
    private let deviceId: String
    private let projectId: String
    private let region: String
    private let gcpProjectNumber: String
    private let gcpWorkloadPool: String
    private let gcpOidcProvider: String
    private let gcpServiceAccount: String

    private let subjectTokenPath: String
    private let adcPath: String

    private var refreshTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        let env = ProcessInfo.processInfo.environment
        self.backendUrl = (env["FAZM_BACKEND_URL"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.backendSecret = env["FAZM_BACKEND_SECRET"] ?? ""
        self.deviceId = Self.getDeviceId()
        self.projectId = env["VERTEX_PROJECT_ID"] ?? "fazm-prod"
        self.region = env["VERTEX_REGION"] ?? "us-east5"
        self.gcpProjectNumber = env["GCP_PROJECT_NUMBER"] ?? ""
        self.gcpWorkloadPool = env["GCP_WORKLOAD_POOL"] ?? "fazm-desktop-pool"
        self.gcpOidcProvider = env["GCP_OIDC_PROVIDER"] ?? "fazm-backend-provider"
        self.gcpServiceAccount = env["GCP_SERVICE_ACCOUNT"] ?? ""

        let tmpDir = NSTemporaryDirectory()
        self.subjectTokenPath = (tmpDir as NSString).appendingPathComponent("fazm-vertex-subject-token.txt")
        self.adcPath = (tmpDir as NSString).appendingPathComponent("fazm-vertex-adc.json")
    }

    // MARK: - Public API

    /// Fetch token, write files, return config for ACPBridge
    func setup() async throws -> VertexConfig {
        let token = try await fetchSubjectToken()
        try writeTokenFiles(subjectToken: token)
        return VertexConfig(adcFilePath: adcPath, projectId: projectId, region: region)
    }

    /// Start background refresh loop (every 50 min)
    func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            // Skip first tick — we already have a fresh token
            try? await Task.sleep(nanoseconds: 50 * 60 * 1_000_000_000)
            while !Task.isCancelled {
                log("VertexTokenManager: refreshing subject token...")
                do {
                    let token = try await fetchSubjectToken()
                    try writeTokenFiles(subjectToken: token)
                    log("VertexTokenManager: token refreshed successfully")
                } catch {
                    log("VertexTokenManager: refresh failed (non-fatal): \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 50 * 60 * 1_000_000_000)
            }
        }
    }

    /// Stop refresh and clean up temp files
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        try? FileManager.default.removeItem(atPath: subjectTokenPath)
        // Keep ADC file for token caching (same pattern as Mediar)
        log("VertexTokenManager: stopped")
    }

    /// Whether the backend is configured (env vars present)
    var isConfigured: Bool {
        !backendUrl.isEmpty && !backendSecret.isEmpty
    }

    // MARK: - Private

    private func fetchSubjectToken() async throws -> String {
        guard !backendUrl.isEmpty else {
            throw VertexError.notConfigured("FAZM_BACKEND_URL not set")
        }

        let url = URL(string: "\(backendUrl)/v1/vertex/subject-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(backendSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VertexError.networkError("Subject token request failed: \(httpResponse.statusCode) - \(body)")
        }

        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw VertexError.networkError("Empty subject token response")
        }

        log("VertexTokenManager: subject token fetched (len=\(token.count))")
        return token
    }

    private func writeTokenFiles(subjectToken: String) throws {
        // Write subject token to plain text file
        try subjectToken.write(toFile: subjectTokenPath, atomically: true, encoding: .utf8)

        // Write external_account ADC JSON
        let audience = "//iam.googleapis.com/projects/\(gcpProjectNumber)/locations/global/workloadIdentityPools/\(gcpWorkloadPool)/providers/\(gcpOidcProvider)"

        let adcJson: [String: Any] = [
            "type": "external_account",
            "audience": audience,
            "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
            "token_url": "https://sts.googleapis.com/v1/token",
            "credential_source": [
                "file": subjectTokenPath,
                "format": ["type": "text"]
            ] as [String: Any],
            "service_account_impersonation_url":
                "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/\(gcpServiceAccount):generateAccessToken"
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: adcJson, options: .prettyPrinted)
        try jsonData.write(to: URL(fileURLWithPath: adcPath), options: .atomic)

        log("VertexTokenManager: ADC file written to \(adcPath)")
    }

    private static func getDeviceId() -> String {
        // Use hardware UUID as stable device identifier
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return UUID().uuidString }

        defer { IOObjectRelease(platformExpert) }

        if let serialNumber = IORegistryEntryCreateCFProperty(
            platformExpert,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String {
            return serialNumber
        }
        return UUID().uuidString
    }

    enum VertexError: LocalizedError {
        case notConfigured(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured(let msg): return "Vertex not configured: \(msg)"
            case .networkError(let msg): return "Vertex network error: \(msg)"
            }
        }
    }
}
