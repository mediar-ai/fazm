import Foundation
import IOKit

/// Fetches and caches API keys from the backend for authenticated users.
/// Keys are held in memory only — fetched fresh each app launch.
final class KeyService {
    static let shared = KeyService()

    private(set) var anthropicAPIKey: String?
    private(set) var deepgramAPIKey: String?
    private var hasFetched = false

    /// Task that represents the in-flight fetchKeys() call, so callers can await it.
    private var fetchTask: Task<Void, Never>?

    private let backendUrl: String
    private let deviceId: String

    private init() {
        self.backendUrl = Self.env("FAZM_BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.deviceId = Self.getDeviceId()
    }

    /// Kick off key fetching. Called fire-and-forget from AuthService; the returned Task
    /// is stored so that `ensureKeys()` can await it later.
    func fetchKeys() async {
        guard !hasFetched else { return }

        // If a fetch is already in flight, just await it
        if let existing = fetchTask {
            await existing.value
            return
        }

        let task = Task { [self] in
            await _doFetch()
        }
        fetchTask = task
        await task.value
    }

    /// Wait for keys to be available (up to `timeout` seconds).
    /// Call this before using `deepgramAPIKey` or `anthropicAPIKey`.
    func ensureKeys(timeout: TimeInterval = 10) async {
        if hasFetched { return }

        // Await the in-flight fetch, or start one if none exists
        if let task = fetchTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                // Return as soon as either completes
                await group.next()
                group.cancelAll()
            }
        } else {
            // No fetch in flight — kick one off and await it with timeout
            let task = Task { [self] in await _doFetch() }
            fetchTask = task
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                await group.next()
                group.cancelAll()
            }
        }

        if !hasFetched {
            log("KeyService: ensureKeys timed out after \(timeout)s")
        }
    }

    private func _doFetch() async {
        guard !hasFetched else { return }
        guard !backendUrl.isEmpty else {
            log("KeyService: missing FAZM_BACKEND_URL, skipping key fetch")
            return
        }
        guard await AuthService.shared.isSignedIn else {
            log("KeyService: user not signed in, skipping key fetch")
            return
        }

        do {
            let authHeader = try await AuthService.shared.getAuthHeader()
            let url = URL(string: "\(backendUrl)/v1/keys")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                log("KeyService: fetch failed with status \(status): \(body)")
                hasFetched = true
                return
            }

            struct KeysResponse: Decodable {
                let anthropic_api_key: String
                let deepgram_api_key: String
            }

            let keys = try JSONDecoder().decode(KeysResponse.self, from: data)
            if !keys.anthropic_api_key.isEmpty {
                anthropicAPIKey = keys.anthropic_api_key
            }
            if !keys.deepgram_api_key.isEmpty {
                deepgramAPIKey = keys.deepgram_api_key
            }
            hasFetched = true
            log("KeyService: fetched keys (anthropic=\(anthropicAPIKey != nil), deepgram=\(deepgramAPIKey != nil))")
        } catch {
            log("KeyService: fetch error: \(error.localizedDescription)")
            hasFetched = true
        }
    }

    // MARK: - Private Helpers

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
