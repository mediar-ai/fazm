import Foundation
import IOKit

/// Fetches and caches API keys from the backend for authenticated users.
/// Keys are held in memory only — fetched fresh each app launch.
final class KeyService {
    static let shared = KeyService()

    private(set) var anthropicAPIKey: String?
    private(set) var deepgramAPIKey: String?
    /// Credential for Gemini calls. When `geminiUsesProxy` is true this is a
    /// per-user Fazm proxy token, not a Google API key, and is only valid
    /// against `geminiBaseURL`. Use the two together, never one alone.
    private(set) var geminiAPIKey: String?
    /// True when the backend issued a proxy token. The real Gemini key then
    /// never reaches this machine (it was stolen from /v1/keys twice in
    /// November 2026, which is why the proxy exists).
    private(set) var geminiUsesProxy = false
    /// Base URL (no trailing slash) for Gemini REST calls made with
    /// `geminiAPIKey`: the backend proxy when a proxy token was issued,
    /// Google directly for the legacy raw key.
    var geminiBaseURL: String {
        geminiUsesProxy ? "\(backendUrl)/v1/gemini" : "https://generativelanguage.googleapis.com"
    }
    private(set) var elevenlabsAPIKey: String?
    private var hasFetched = false

    /// Resolve the ElevenLabs API key, waiting for KeyService if needed.
    /// Mirrors `TranscriptionService.resolveDeepgramKey` so callers have the
    /// same env-var-then-backend lookup order.
    static func resolveElevenLabsKey() async throws -> String {
        if let envKey = getenv("ELEVENLABS_API_KEY").flatMap({ String(validatingUTF8: $0) }), !envKey.isEmpty {
            return envKey
        }
        await KeyService.shared.ensureKeys()
        if let k = KeyService.shared.elevenlabsAPIKey, !k.isEmpty { return k }
        throw NSError(
            domain: "KeyService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ELEVENLABS_API_KEY not set"]
        )
    }

    /// Task that represents the in-flight fetchKeys() call, so callers can await it.
    private var fetchTask: Task<Void, Never>?

    /// Read dynamically so that KeyService.shared can be initialized before loadEnvironment()
    /// sets FAZM_BACKEND_URL via setenv(). If we cached this in init(), returning users would
    /// get an empty URL because AuthService.configure() triggers the singleton before AppState.init().
    private var backendUrl: String {
        Self.env("FAZM_BACKEND_URL").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private let deviceId: String

    private init() {
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

    /// Force a re-fetch of keys from the backend, ignoring the `hasFetched` cache.
    /// Use this when the bundled Anthropic key fails authentication mid-session
    /// (e.g. backend rotated or revoked it). Returns true if the new
    /// anthropic_api_key differs from the previous value, indicating the
    /// caller should restart the bridge to pick up the new key.
    @discardableResult
    func refetchAnthropicKey() async -> Bool {
        let oldKey = anthropicAPIKey
        let oldSuffix = oldKey.map { String($0.suffix(8)) } ?? "nil"
        log("KeyService: refetchAnthropicKey() — clearing cache (oldKey ending=\(oldSuffix))")
        // Clear the cache flag and any in-flight task so _doFetch runs fresh.
        hasFetched = false
        fetchTask = nil
        let task = Task { [self] in await _doFetch() }
        fetchTask = task
        await task.value
        let newKey = anthropicAPIKey
        let changed = (newKey ?? "") != (oldKey ?? "")
        let newSuffix = newKey.map { String($0.suffix(8)) } ?? "nil"
        log("KeyService: refetchAnthropicKey() done (newKey ending=\(newSuffix), changed=\(changed))")
        return changed
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
            // Clear fetchTask so the next ensureKeys() retries (env may be loaded by then)
            fetchTask = nil
            return
        }
        guard await AuthService.shared.isSignedIn else {
            log("KeyService: user not signed in, skipping key fetch")
            fetchTask = nil
            return
        }

        // Try up to 2 times: first with current token, then with a force-refreshed token
        for attempt in 1...2 {
            do {
                let forceRefresh = attempt > 1
                if forceRefresh {
                    log("KeyService: retrying with force-refreshed token")
                }
                let token = try await AuthService.shared.getIdToken(forceRefresh: forceRefresh)
                let authHeader = "Bearer \(token)"
                let url = URL(string: "\(backendUrl)/v1/keys")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
                request.timeoutInterval = 15

                let (data, response) = try await URLSession.shared.data(for: request)

                let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                if (status == 401 || status == 403) && attempt < 2 {
                    log("KeyService: fetch got \(status), will retry with refreshed token")
                    continue
                }

                guard status == 200 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    log("KeyService: fetch failed with status \(status): \(body)")
                    // Don't set hasFetched — allow future retries for transient failures
                    // (cold start timeouts, expired tokens, server errors)
                    fetchTask = nil
                    return
                }

                struct KeysResponse: Decodable {
                    let anthropic_api_key: String
                    let deepgram_api_key: String
                    let gemini_api_key: String?
                    let elevenlabs_api_key: String?
                    let gemini_proxy_token: String?
                }

                let keys = try JSONDecoder().decode(KeysResponse.self, from: data)
                if !keys.anthropic_api_key.isEmpty {
                    anthropicAPIKey = keys.anthropic_api_key
                }
                if !keys.deepgram_api_key.isEmpty {
                    deepgramAPIKey = keys.deepgram_api_key
                }
                if let proxyToken = keys.gemini_proxy_token, !proxyToken.isEmpty {
                    // Prefer the proxy: the raw key (still sent for older app
                    // versions) is ignored so it is never used from here.
                    geminiAPIKey = proxyToken
                    geminiUsesProxy = true
                } else if let gemini = keys.gemini_api_key, !gemini.isEmpty {
                    geminiAPIKey = gemini
                    geminiUsesProxy = false
                }
                if let elevenlabs = keys.elevenlabs_api_key, !elevenlabs.isEmpty {
                    elevenlabsAPIKey = elevenlabs
                }
                hasFetched = true
                log("KeyService: fetched keys (anthropic=\(anthropicAPIKey != nil), deepgram=\(deepgramAPIKey != nil), gemini=\(geminiAPIKey != nil), geminiProxy=\(geminiUsesProxy), elevenlabs=\(elevenlabsAPIKey != nil))")
                return
            } catch {
                if attempt < 2 {
                    log("KeyService: fetch error (attempt \(attempt)): \(error.localizedDescription), retrying...")
                    continue
                }
                log("KeyService: fetch error: \(error.localizedDescription)")
                // Don't set hasFetched — allow future retries
                fetchTask = nil
            }
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
