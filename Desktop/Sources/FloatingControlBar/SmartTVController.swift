import Foundation
import WebKit

/// Controls the Smart TV WKWebView — search, play, pause.
@MainActor
class SmartTVController {
    static let shared = SmartTVController()
    weak var webView: WKWebView?

    /// True while a search navigation is in progress — suppresses play/pause
    /// from Combine observers to avoid fighting with page load.
    var isNavigating = false

    /// Pending search query — set when searchAndPlay is called before the webView exists.
    /// Consumed by the SmartTVView coordinator after initial page load.
    var pendingQuery: String?

    private let geminiModel = "gemini-flash-latest"

    /// Navigate to YouTube Shorts search results for the given query.
    func searchAndPlay(query: String) {
        guard let webView else {
            log("SmartTV: searchAndPlay deferred (webView nil) — query: \(query.prefix(50))")
            pendingQuery = query
            return
        }
        pendingQuery = nil
        isNavigating = true

        Task {
            let optimized = await optimizeQuery(query)
            let searchQuery = optimized ?? query
            log("SmartTV: searchAndPlay — query: \(query.prefix(50)) → optimized: \(searchQuery.prefix(50))")
            guard let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://m.youtube.com/results?search_query=\(encoded)&sp=EgIYAQ%3D%3D")
            else {
                isNavigating = false
                return
            }
            webView.load(URLRequest(url: url))
        }
    }

    /// Ask Gemini Flash to rewrite the user's query into an optimal YouTube search query.
    private func optimizeQuery(_ query: String) async -> String? {
        await KeyService.shared.ensureKeys(timeout: 3)
        guard let apiKey = KeyService.shared.geminiAPIKey else {
            log("SmartTV: no Gemini API key, skipping query optimization")
            return nil
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(geminiModel):generateContent?key=\(apiKey)") else { return nil }

        let body: [String: Any] = [
            "contents": [["parts": [["text": """
                Convert this user request into a YouTube search query (2-5 words) that will find the best matching Shorts videos. Output ONLY the search query, nothing else.

                Examples:
                - "I want to learn about space exploration" → "space exploration facts shorts"
                - "show me something relaxing" → "satisfying relaxing videos"
                - "hi" → "trending viral shorts"
                - "funny animals" → "funny animals compilation"

                User request: \(query)
                """]]]],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 32,
                "thinkingConfig": ["thinkingBudget": 0]
            ]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = httpBody

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                log("SmartTV: Gemini query optimization failed (status=\(status)): \(body.prefix(500))")
                return nil
            }
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        } catch {
            log("SmartTV: Gemini query optimization error: \(error.localizedDescription)")
            return nil
        }
    }

    func pauseVideo(source: String = "") {
        guard !isNavigating else {
            log("SmartTV: pauseVideo SKIPPED (navigating) source=\(source)")
            return
        }
        log("SmartTV: pauseVideo source=\(source)")
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
    }

    func playVideo(source: String = "") {
        log("SmartTV: playVideo source=\(source)")
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.play())")
    }

    func setMuted(_ muted: Bool) {
        log("SmartTV: setMuted=\(muted)")
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.muted = \(muted))")
    }

    /// Called when navigation completes and the Shorts player is ready.
    func navigationFinished() {
        isNavigating = false
    }
}
