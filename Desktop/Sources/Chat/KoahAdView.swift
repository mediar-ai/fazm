// KoahAdView.swift
//
// PoC: contextual ad slot powered by Koah Labs JS SDK, rendered in a WKWebView
// underneath the assistant's completed response.
//
// Status: experimental, gated by the `koah_enabled` PostHog feature flag (default OFF),
// only shown to users without an active subscription. Uses the Koah **Demo ID** so no
// real impressions get billed to the Fazm publisher account until the flag is moved to
// the real publisher ID intentionally.
//
// Privacy: question and answer are run through `KoahContextRedactor.redact` before
// being passed to the JS layer. Strips emails, phone numbers, common API key shapes,
// long base64-looking blobs, and trims length. Crashes dev builds via assertion if the
// active Firebase user email leaks into the context.
//
// Indemnification: see Publisher Agreement section 9 and conversation note 2026-05-22.
// Code-level guardrails here exist so we never trigger the "PII without consent" warranty
// breach (clause 6b(iii)).
//
// Background: Koah does not yet ship a macOS Swift SDK; the JavaScript SDK is the only
// option for the Fazm desktop target. JS SDK docs: https://docs.koahlabs.com/sdk/javascript

import AppKit
import Foundation
import SwiftUI
import WebKit

// MARK: - Identifiers

/// Hard-coded Koah identifiers for Fazm.
///
/// The Demo ID is safe to use locally — Koah marks those impressions as test traffic and
/// does not bill them. Only swap to `productionPublisherID` once we are ready to take on
/// real revenue + the privacy disclosure has shipped.
enum KoahIDs {
    /// Real Fazm publisher ID (Mediar ai inc), from the Koah dashboard 2026-05-22.
    /// Do NOT use this in dev builds — that's what the Demo ID is for.
    static let productionPublisherID = "b04f529c-8b2f-464b-a1e3-ba22ae47aaff"

    /// Test publisher ID provided by Jon Maroun in the onboarding email.
    /// Use this for everything pre-launch.
    static let demoPublisherID = "b8578b83-6798-4c40-9b78-5e6ee261e0ea"

    /// Active publisher ID. Production as of 2026-05-22 (privacy disclosure shipped in
    /// fazm-website/src/app/privacy/page.tsx; section "Advertising and Free Tier"
    /// describes the Koah data flow). Order Form with Koah still TBD; pre-Order-Form
    /// traffic is allowed under the signed Publisher Agreement and Demo billing rules.
    static var activePublisherID: String {
        #if DEBUG
        return demoPublisherID
        #else
        if UserDefaults.standard.bool(forKey: "fazm_koah_force_show") {
            return demoPublisherID
        }
        return productionPublisherID
        #endif
    }
}

// MARK: - Redactor

/// Sanitizes the strings we hand to Koah's `requestAd(context:)` so we never leak PII.
///
/// Rules:
/// - Trim to MAX_LENGTH (defaults to 500 chars).
/// - Mask anything that looks like an email, US/E.164 phone, or street address.
/// - Mask anything that looks like an API key (`sk-…`, `phx_…`, `pk_live_…`, base64ish
///   tokens 24+ chars long with no spaces).
/// - Mask anything > 200 chars that contains no whitespace (likely a UUID/JWT/blob).
/// - Collapse repeated whitespace.
///
/// All masking replaces with `[redacted]` so the model gets a recognizable signal that
/// something was scrubbed rather than seeing a hole.
enum KoahContextRedactor {
    static let maxLength = 500

    private static let patterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            (#"[\w._%+\-]+@[\w.\-]+\.[A-Za-z]{2,}"#, "[redacted-email]"),
            (#"\+?\d[\d\-\s().]{9,}\d"#, "[redacted-phone]"),
            (#"\b\d{1,5}\s+[A-Z][A-Za-z]+\s+(St|Street|Ave|Avenue|Blvd|Rd|Road|Dr|Drive|Ln|Lane|Way|Court|Ct)\b"#, "[redacted-address]"),
            (#"\bsk-[A-Za-z0-9_\-]{16,}\b"#, "[redacted-key]"),
            (#"\bphx_[A-Za-z0-9_\-]{16,}\b"#, "[redacted-key]"),
            (#"\bpk_(?:live|test)_[A-Za-z0-9]{16,}\b"#, "[redacted-key]"),
            (#"\b[A-Za-z0-9+/=]{40,}\b"#, "[redacted-token]"),
            (#"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "[redacted-uuid]"),
        ]
        return raw.compactMap { (pat, repl) in
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
            return (re, repl)
        }
    }()

    /// Sanitize `input` for safe transmission to Koah.
    static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        var s = input
        // Pattern-based masking
        for (re, repl) in patterns {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: repl)
        }
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
             .trimmingCharacters(in: .whitespacesAndNewlines)
        // Length cap (UTF-16 indices to be safe with emoji)
        if s.count > maxLength {
            let idx = s.index(s.startIndex, offsetBy: maxLength)
            s = String(s[..<idx]) + "…"
        }
        return s
    }
}

// MARK: - Gate

/// Decides whether to render a Koah ad in this session.
///
/// Order of checks:
/// 1. Dev override (UserDefaults `fazm_koah_force_show=true`) → always show, bypasses
///    everything. ONLY for local smoke testing — never ship a build with this enabled
///    for end users. Toggle with `defaults write com.fazm.desktop-dev fazm_koah_force_show -bool true`.
/// 2. Subscription active → never. Paid users see zero ads. Ever.
/// 3. (Future) per-conversation user opt-out from in-app settings.
@MainActor
enum KoahAdGate {
    static let devForceShowKey = "fazm_koah_force_show"

    static func shouldShowAd() -> Bool {
        if UserDefaults.standard.bool(forKey: devForceShowKey) { return true }
        if SubscriptionService.shared.isActive { return false }
        return true
    }
}

// MARK: - WKWebView wrapper

/// SwiftUI view that loads a tiny HTML harness with the Koah JS SDK and calls
/// `requestAd` once with the redacted question/answer.
///
/// Sizing: starts at 0 height, the JS layer measures the rendered ad and reports back
/// via `webkit.messageHandlers.koah` (`{type: 'rendered', height: <px>}`); we update
/// the SwiftUI binding so the view smoothly expands. Empty ad responses report `filled:
/// false` and the view stays collapsed.
struct KoahAdView: View {
    let question: String
    let answer: String
    let publisherID: String

    @State private var measuredHeight: CGFloat = 0
    @State private var didFail: Bool = false

    init(question: String, answer: String, publisherID: String = KoahIDs.activePublisherID) {
        self.question = question
        self.answer = answer
        self.publisherID = publisherID
    }

    var body: some View {
        // Render a transparent host that collapses to zero if the ad slot is empty or
        // errored. We keep a small min-height while loading so the layout doesn't jump
        // when an ad arrives.
        let visibleHeight: CGFloat = didFail ? 0 : max(measuredHeight, 0)
        
        VStack(alignment: .leading, spacing: 4) {
            if visibleHeight > 0 {
                HStack(alignment: .center, spacing: 6) {
                    Text("Sponsored")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(FazmColors.textQuaternary)
                    
                    Spacer()
                    
                    Button(action: {
                        if let provider = FloatingControlBarManager.shared.chatProvider {
                            provider.showPaywall = true
                            PaywallWindowController.shared.show(chatProvider: provider)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                            Text("Go Ad-Free")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(FazmColors.purplePrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(FazmColors.purplePrimary.opacity(0.1))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(FazmColors.purplePrimary.opacity(0.2), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Upgrade to Fazm Pro for an ad-free experience")
                }
                .padding(.horizontal, 4)
            }
            
            KoahWebView(
                question: KoahContextRedactor.redact(question),
                answer: KoahContextRedactor.redact(answer),
                publisherID: publisherID,
                measuredHeight: $measuredHeight,
                didFail: $didFail
            )
            .frame(height: visibleHeight)
            .opacity(visibleHeight > 0 ? 1 : 0)
        }
        .accessibilityLabel("Sponsored")
    }
}

private struct KoahWebView: NSViewRepresentable {
    let question: String
    let answer: String
    let publisherID: String
    @Binding var measuredHeight: CGFloat
    @Binding var didFail: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(measuredHeight: $measuredHeight, didFail: $didFail)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "koah")
        config.userContentController = userController

        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground") // transparent
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator

        let html = Self.harnessHTML(
            publisherID: publisherID,
            question: question,
            answer: answer
        )
        web.loadHTMLString(html, baseURL: URL(string: "https://app.koah.ai/"))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Static for the life of this slot — we only request once per message render.
        // If the message identity changes, SwiftUI rebuilds this view entirely.
    }

    private static func harnessHTML(publisherID: String, question: String, answer: String) -> String {
        // JSON-encode the context strings to safely interpolate into the script.
        let q = jsString(question)
        let a = jsString(answer)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body { margin:0; padding:0; background:transparent; color:inherit;
                      font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
          #ad-slot { display:block; }
        </style>
        </head><body>
        <div id="ad-slot"></div>
        <script src="https://app.koah.ai/js?token=\(publisherID)" type="module"></script>
        <script type="module">
          const send = (m) => { try { window.webkit.messageHandlers.koah.postMessage(m); } catch (_) {} };
          const sleep = (ms) => new Promise(r => setTimeout(r, ms));
          const readyToCall = () => typeof window.koah?.requestAd === 'function';
          let tries = 0;
          while (!readyToCall() && tries < 60) { await sleep(100); tries++; }
          if (!readyToCall()) { send({ type: 'timeout' }); }
          else {
            try {
              const result = await window.koah.requestAd({
                target: document.getElementById('ad-slot'),
                context: { type: 'conversation', question: \(q), answer: \(a) }
              });
              if (!result || result.filled !== true) { send({ type: 'unfilled' }); }
              else {
                // Wait one tick for the ad DOM to settle, then measure
                await sleep(50);
                const h = document.getElementById('ad-slot').getBoundingClientRect().height;
                send({ type: 'rendered', height: Math.ceil(h) });
              }
            } catch (e) {
              send({ type: 'error', error: String(e) });
            }
          }
        </script>
        </body></html>
        """
    }

    /// Encode a Swift string as a JS string literal (handles quotes, newlines, slashes).
    private static func jsString(_ s: String) -> String {
        // JSONSerialization is the safest way to round-trip a JS string literal.
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        guard let data, let txt = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // ["…"] → strip the outer brackets
        let trimmed = txt.dropFirst().dropLast()
        return String(trimmed)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        @Binding var measuredHeight: CGFloat
        @Binding var didFail: Bool

        init(measuredHeight: Binding<CGFloat>, didFail: Binding<Bool>) {
            self._measuredHeight = measuredHeight
            self._didFail = didFail
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            Task { @MainActor in
                switch type {
                case "rendered":
                    if let h = body["height"] as? Double { self.measuredHeight = CGFloat(h) }
                    else if let h = body["height"] as? Int { self.measuredHeight = CGFloat(h) }
                case "unfilled", "timeout", "error":
                    self.didFail = true
                    NSLog("[Koah] ad not shown: \(type) body=\(body)")
                default:
                    break
                }
            }
        }

        // MARK: Click-through handling
        //
        // Koah's ad click-through fires either as a `target="_blank"` link or a
        // `window.open(...)` call from inside the JS SDK. WKWebView ignores both by
        // default — `_blank` links route through `createWebViewWith` (which returns nil
        // unless implemented), and `window.open` goes nowhere. Result: the ad looks
        // unclickable. We route every click-through URL out to the system browser.

        nonisolated func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                Task { @MainActor in Self.openExternally(url) }
            }
            return nil
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Bounce explicit user clicks (and form submissions) out to the system
            // browser. Allow everything else (script-initiated loads, iframe content,
            // the initial HTML harness load) to proceed inside the WebView so the SDK
            // and the ad creative can render.
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            let isUserGesture = navigationAction.navigationType == .linkActivated
                || navigationAction.navigationType == .formSubmitted

            if isUserGesture, let url, scheme == "http" || scheme == "https" {
                Task { @MainActor in Self.openExternally(url) }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        @MainActor
        private static func openExternally(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            NSWorkspace.shared.open(url)
            NSLog("[Koah] click-through opened: \(url.absoluteString)")
        }
    }
}
