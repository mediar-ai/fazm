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

                    // Method 1: Click YouTube's "Next video" button
                    var nextBtn = document.querySelector('button[aria-label*="Next video"]') ||
                                  document.querySelector('a[aria-label*="Next video"]') ||
                                  document.querySelector('[aria-label*="Next"]');
                    if (nextBtn) {
                        console.log('[Fazm] clicking Next button: ' + nextBtn.tagName + ' ' + nextBtn.getAttribute('aria-label'));
                        nextBtn.click();
                        return;
                    }

                    // Method 2: Programmatically scroll the carousel wrapper
                    var carousel = document.querySelector('#carousel-scrollable-wrapper');
                    if (carousel) {
                        var itemHeight = carousel.clientHeight;
                        var newTop = carousel.scrollTop + itemHeight;
                        console.log('[Fazm] setting carousel scrollTop from ' + carousel.scrollTop + ' to ' + newTop);
                        carousel.scrollTop = newTop;
                        return;
                    }

                    // Method 3: Simulate a swipe via touch events
                    console.log('[Fazm] trying touch swipe simulation');
                    var target = document.querySelector('#shorts-video') || document.body;
                    var rect = target.getBoundingClientRect();
                    var startY = rect.top + rect.height * 0.7;
                    var endY = rect.top + rect.height * 0.2;
                    var centerX = rect.left + rect.width / 2;

                    function fire(type, x, y) {
                        var touch = new Touch({ identifier: 1, target: target, clientX: x, clientY: y });
                        target.dispatchEvent(new TouchEvent(type, {
                            bubbles: true, cancelable: true, touches: [touch],
                            targetTouches: [touch], changedTouches: [touch]
                        }));
                    }
                    fire('touchstart', centerX, startY);
                    setTimeout(function() { fire('touchmove', centerX, endY); }, 50);
                    setTimeout(function() { fire('touchend', centerX, endY); }, 100);
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
                        // Log diagnostics and DOM structure after a delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            SmartTVController.shared.logVideoDiagnostics()
                            // Dump each ancestor on its own log line
                            let domJS = """
                            (function() {
                                var video = document.querySelector('video');
                                if (!video) { console.log('[Fazm] no video found'); return; }
                                var el = video;
                                var depth = 0;
                                while (el && depth < 20) {
                                    console.log('[Fazm] DOM[' + depth + '] ' + el.tagName +
                                        (el.id ? '#' + el.id : '') +
                                        ' class=' + (el.className || '').toString().substring(0,50) +
                                        ' scrollH=' + el.scrollHeight + ' clientH=' + el.clientHeight +
                                        ' overflow=' + getComputedStyle(el).overflowY);
                                    el = el.parentElement;
                                    depth++;
                                }
                            })();
                            """
                            webView.evaluateJavaScript(domJS)
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
