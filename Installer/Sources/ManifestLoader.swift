import Foundation

struct ReleaseManifest: Decodable {
    let version: String
    let arm64: Payload
    let x86_64: Payload

    func payload(for arch: String) -> Payload? {
        switch arch {
        case "arm64": return arm64
        case "x86_64": return x86_64
        default: return nil
        }
    }
}

struct Payload: Decodable {
    let url: URL
    let size: Int64
    let sha256: String
}

enum ManifestLoader {
    /// Primary: Google Cloud Storage. Unreachable from mainland China (GFW blocks Google).
    static let primaryManifestURL = URL(string: "https://storage.googleapis.com/fazm-prod-releases/desktop/latest.json")!
    /// Mirror: Cloudflare R2. Each manifest's payload URLs are self-consistent with the
    /// host it came from, so the download phase doesn't have to retry separately.
    static let mirrorManifestURL = URL(string: "https://pub-35fbe74936d04a5eb285ae26952b0cf4.r2.dev/releases/latest/latest.json")!

    static func fetchManifest() async throws -> ReleaseManifest {
        do {
            return try await fetch(url: primaryManifestURL, timeout: 10)
        } catch {
            return try await fetch(url: mirrorManifestURL, timeout: 20)
        }
    }

    private static func fetch(url: URL, timeout: TimeInterval) async throws -> ReleaseManifest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ManifestError.fetchFailed
        }
        return try JSONDecoder().decode(ReleaseManifest.self, from: data)
    }
}

enum ManifestError: LocalizedError {
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Could not reach the Fazm download server. Please check your internet connection and try again."
        }
    }
}
