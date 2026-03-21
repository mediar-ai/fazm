import WebKit

/// Controls the Smart TV WKWebView — search, play, pause.
@MainActor
class SmartTVController {
    static let shared = SmartTVController()
    weak var webView: WKWebView?

    /// Navigate to YouTube Shorts search results for the given query.
    func searchAndPlay(query: String) {
        guard let webView,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://m.youtube.com/results?search_query=\(encoded)&sp=EgIYAQ%253D%253D")
        else { return }
        webView.load(URLRequest(url: url))
    }

    func pauseVideo() {
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
    }

    func playVideo() {
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.play())")
    }
}
