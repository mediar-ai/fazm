import SwiftUI
import WebKit

/// WKWebView wrapper that loads YouTube Shorts with a mobile user-agent
/// for a full vertical reel experience.
struct SmartTVView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        // Capture console.log from JS
        let script = WKUserScript(source: """
            (function() {
                var origLog = console.log;
                console.log = function() {
                    var msg = Array.prototype.slice.call(arguments).join(' ');
                    window.webkit.messageHandlers.fazmLog.postMessage(msg);
                    origLog.apply(console, arguments);
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "fazmLog")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator

        // Register with controller so it can be controlled externally
        SmartTVController.shared.webView = webView

        // If there's a pending search query, go straight to search instead of /shorts
        if let pending = SmartTVController.shared.pendingQuery {
            SmartTVController.shared.searchAndPlay(query: pending)
        } else {
            if let url = URL(string: "https://m.youtube.com/shorts") {
                webView.load(URLRequest(url: url))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No dynamic updates needed
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "fazmLog", let body = message.body as? String {
                log("SmartTV JS: \(body)")
            }
        }

        /// JavaScript that disables video looping and auto-scrolls to the next Short when one ends.
        static let autoAdvanceJS = """
        (function() {
            document.querySelectorAll('video').forEach(v => v.muted = true);
            if (!window.__fazmAutoAdvance) {
                window.__fazmAutoAdvance = true;
                console.log('[Fazm] auto-advance setup starting');

                function advanceToNext() {
                    console.log('[Fazm] advancing to next Short');
                    // Try multiple scroll targets — YouTube Shorts layout varies
                    var scrolled = false;
                    var targets = [
                        document.querySelector('ytm-shorts-player'),
                        document.querySelector('#shorts-container'),
                        document.querySelector('.reel-video-in-sequence'),
                        document.scrollingElement,
                        document.body
                    ];
                    for (var i = 0; i < targets.length; i++) {
                        var t = targets[i];
                        if (t && t.scrollHeight > t.clientHeight) {
                            t.scrollBy({ top: window.innerHeight, behavior: 'smooth' });
                            console.log('[Fazm] scrolled target: ' + (t.tagName || 'scrollingElement'));
                            scrolled = true;
                            break;
                        }
                    }
                    if (!scrolled) {
                        window.scrollBy({ top: window.innerHeight, behavior: 'smooth' });
                        console.log('[Fazm] scrolled window as fallback');
                    }
                }

                function attachListener(video) {
                    if (video.__fazmSetup) return;
                    video.__fazmSetup = true;

                    // Force loop off and prevent YouTube from re-enabling it
                    video.loop = false;
                    Object.defineProperty(video, 'loop', {
                        get: function() { return false; },
                        set: function(v) { /* block YouTube from re-enabling loop */ },
                        configurable: true
                    });

                    // Use timeupdate as primary trigger — more reliable than 'ended'
                    video.addEventListener('timeupdate', function() {
                        if (video.duration > 0 && video.currentTime >= video.duration - 0.3) {
                            if (!video.__fazmAdvancing) {
                                video.__fazmAdvancing = true;
                                console.log('[Fazm] video near end: ' + video.currentTime.toFixed(1) + '/' + video.duration.toFixed(1));
                                advanceToNext();
                            }
                        }
                    });

                    // Also listen for ended as backup
                    video.addEventListener('ended', function() {
                        if (!video.__fazmAdvancing) {
                            video.__fazmAdvancing = true;
                            advanceToNext();
                        }
                    });

                    console.log('[Fazm] attached listener to video, duration=' + video.duration);
                }

                document.querySelectorAll('video').forEach(attachListener);

                new MutationObserver(function() {
                    document.querySelectorAll('video').forEach(function(v) {
                        v.muted = true;
                        attachListener(v);
                    });
                }).observe(document.body, { childList: true, subtree: true });

                console.log('[Fazm] auto-advance setup complete');
            }
        })();
        """

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? ""
            log("SmartTV: didFinish — url=\(url.prefix(80))")

            if url.contains("/results") {
                // On search results page: click the first Shorts result
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("SmartTV: clicking first Shorts result")
                    let js = """
                    (function() {
                        var links = document.querySelectorAll('a[href*="/shorts/"]');
                        if (links.length > 0) {
                            links[0].click();
                        }
                    })();
                    """
                    webView.evaluateJavaScript(js)

                    // Inject auto-advance after click (SPA navigation won't trigger didFinish)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        SmartTVController.shared.navigationFinished()
                        webView.evaluateJavaScript(Self.autoAdvanceJS)
                        log("SmartTV: injected auto-advance after search→shorts SPA nav")
                        // Log diagnostics after a delay to see video state
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            SmartTVController.shared.logVideoDiagnostics()
                        }
                    }
                }
            } else if url.contains("/shorts/") {
                // On Shorts player page: navigation done, let YouTube autoplay
                SmartTVController.shared.navigationFinished()
                webView.evaluateJavaScript(Self.autoAdvanceJS)
                log("SmartTV: on Shorts player, navigation finished (muted, auto-advance enabled)")
            } else {
                SmartTVController.shared.navigationFinished()
            }
        }
    }
}
