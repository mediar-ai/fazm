import SwiftUI
import AppKit

/// Paywall overlay shown when the user exceeds their free message limit after the trial.
struct PaywallSheet: View {
    let onSubscribe: () -> Void
    let onDismiss: () -> Void
    /// Signs the user out and returns them to the sign-in screen, so someone
    /// who subscribed under a different account can re-authenticate.
    let onSwitchAccount: () -> Void

    @State private var showReferral = false
    @State private var referralCode: String = ""
    @State private var referralUrl: String = ""
    @State private var isLoadingReferral = false
    @State private var linkCopied = false
    @State private var referralCredit: Int = 0  // dollars of earned credit

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if showReferral {
                    Button(action: { showReferral = false }) {
                        Image(systemName: "chevron.left")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text(showReferral ? "Refer a Friend" : "Upgrade to Fazm Pro")
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(FazmColors.backgroundTertiary.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .foregroundColor(FazmColors.border)

            if showReferral {
                referralView
            } else {
                paywallView
            }
        }
        .frame(width: 400, height: 560)
        .background(FazmColors.backgroundPrimary)
        .onAppear {
            loadReferralCredit()
            // Refresh variant price so the CTA shows the user's actual A/B arm
            // even on the first paywall display after sign-in.
            Task { await SubscriptionService.shared.fetchVariantPrice() }
        }
    }

    // MARK: - Paywall View

    private var paywallView: some View {
        VStack(spacing: 0) {
            // Header content
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .scaledFont(size: 36)
                    .foregroundStyle(FazmColors.purpleGradient)
                    .padding(.top, 8)

                VStack(spacing: 6) {
                    Text(headerTitle)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundColor(FazmColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(headerSubtitle)
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Referral credit banner
            if referralCredit > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .scaledFont(size: 14)
                        .foregroundColor(FazmColors.success)
                    Text("You have $\(referralCredit) in referral credits!")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundColor(FazmColors.success)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(FazmColors.success.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }

            // Option cards
            VStack(spacing: 10) {
                // Option 1: Subscribe (with free trial if backend configured)
                Button(action: {
                    AnalyticsManager.shared.subscriptionUpgradeTapped(source: "paywall")
                    onSubscribe()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "creditcard.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(FazmColors.purpleGradient)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(subscribeButtonTitle)
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            if referralCredit > 0 {
                                Text("\(priceLabel)/mo ($\(referralCredit) credit applied)")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.success)
                            } else {
                                Text(subscribeButtonSubtitle)
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textTertiary)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(FazmColors.textQuaternary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(FazmColors.backgroundTertiary.opacity(0.6))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(FazmColors.border.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Option 2: Refer a friend
                Button(action: {
                    AnalyticsManager.shared.paywallReferralTapped()
                    showReferral = true
                    loadReferralCode()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(FazmColors.purpleGradient)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refer a Friend")
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            Text("Get 1 month free for every friend you refer")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(FazmColors.textQuaternary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(FazmColors.backgroundTertiary.opacity(0.6))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(FazmColors.border.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Option 3: Chat with founder
                Button(action: {
                    AnalyticsManager.shared.paywallFounderCallTapped()
                    if let url = URL(string: "https://cal.com/team/mediar/fazm") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "video.fill")
                            .scaledFont(size: 20)
                            .foregroundStyle(FazmColors.purpleGradient)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chat with Our Founder")
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            Text("Get 1 month free after a quick call")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(FazmColors.textQuaternary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(FazmColors.backgroundTertiary.opacity(0.6))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(FazmColors.border.opacity(0.5), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Features list
            VStack(alignment: .leading, spacing: 6) {
                featureRow("AI agent with full desktop control")
                featureRow("Voice and text queries")
                featureRow("Screen context awareness")
            }
            .padding(.horizontal, 44)
            .padding(.bottom, 10)

            // Wrong-account recovery. A user who already pays under a different
            // account (e.g. a second Google account) would otherwise be stuck
            // here with no way to reach the account that carries the subscription.
            VStack(spacing: 3) {
                if let email = AuthService.shared.userEmail, !email.isEmpty {
                    Text("Signed in as \(email)")
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.textQuaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(action: {
                    PostHogManager.shared.track("paywall_switch_account_tapped", properties: ["source": "paywall"])
                    onSwitchAccount()
                }) {
                    Text("Already subscribed? Sign in with a different account")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(FazmColors.purplePrimary)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            // Dismiss
            Button(action: {
                AnalyticsManager.shared.paywallDismissed()
                onDismiss()
            }) {
                Text("Maybe Later")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Referral View

    private var referralView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "gift.fill")
                    .scaledFont(size: 40)
                    .foregroundStyle(FazmColors.purpleGradient)
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    Text("Get 1 month free")
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundColor(FazmColors.textPrimary)

                    Text("Share your link with a friend. When they install Fazm and send 5 messages, you get 1 month of Pro free.")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)

                if isLoadingReferral {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.vertical, 20)
                } else if !referralCode.isEmpty {
                    // Referral code display
                    VStack(spacing: 12) {
                        Text("Your referral code")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)

                        Text(referralCode)
                            .scaledFont(size: 24, weight: .bold)
                            .foregroundColor(FazmColors.textPrimary)
                            .tracking(4)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(FazmColors.backgroundTertiary.opacity(0.5))
                            .cornerRadius(8)
                    }

                    // Copy link button
                    Button(action: copyLink) {
                        HStack(spacing: 6) {
                            Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                                .scaledFont(size: 13)
                            Text(linkCopied ? "Link copied!" : "Copy referral link")
                                .scaledFont(size: 14, weight: .medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if linkCopied {
                                FazmColors.success.opacity(0.2)
                            } else {
                                FazmColors.purpleGradient
                            }
                        }
                        .foregroundColor(linkCopied ? FazmColors.success : .white)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                }

                // Steps
                VStack(alignment: .leading, spacing: 10) {
                    stepRow(number: "1", text: "Share your link with a friend")
                    stepRow(number: "2", text: "They download and install Fazm")
                    stepRow(number: "3", text: "They send 5 messages from the floating bar")
                    stepRow(number: "4", text: "You get 1 month of Pro free")
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            Spacer()

            Button(action: { showReferral = false }) {
                Text("Back to upgrade options")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Dynamic Pricing Copy

    /// Variant-aware price as a string like "$9.99" or "$19.99".
    /// Driven by `SubscriptionService.cachedPriceCents`, which the service
    /// populates from `GET /api/stripe/variant-price` on launch.
    private var priceLabel: String {
        let cents = SubscriptionService.shared.cachedPriceCents
        let dollars = Double(cents) / 100.0
        return String(format: "$%.2f", dollars)
    }

    /// Whether a free trial is configured on the backend (Stripe-side trial,
    /// applied at checkout). Independent of the client-side pre-paywall free
    /// week.
    private var hasFreeTrial: Bool {
        SubscriptionService.shared.cachedTrialDays > 0
    }

    private var trialDays: Int { SubscriptionService.shared.cachedTrialDays }

    /// Header title. Only advertises "free" when a backend trial is configured.
    private var headerTitle: String {
        hasFreeTrial ? "Try Fazm Pro free" : "Unlock Fazm Pro"
    }

    /// Subheader under the header title.
    private var headerSubtitle: String {
        if hasFreeTrial {
            return "Start your \(trialDays)-day free trial. No charge today."
        } else {
            return "Subscribe to continue using Fazm"
        }
    }

    /// Primary CTA title.
    private var subscribeButtonTitle: String {
        hasFreeTrial ? "Start \(trialDays)-Day Free Trial" : "Subscribe Now"
    }

    /// Primary CTA subtitle.
    private var subscribeButtonSubtitle: String {
        if hasFreeTrial {
            return "Then \(priceLabel)/mo. Cancel anytime."
        } else {
            return "\(priceLabel)/mo, billed monthly"
        }
    }

    // MARK: - Helpers

    private func featureRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.success)
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)
        }
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(spacing: 10) {
            Text(number)
                .scaledFont(size: 11, weight: .bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(FazmColors.purpleGradient)
                .clipShape(Circle())
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)
        }
    }

    private func loadReferralCode() {
        guard referralCode.isEmpty else { return }
        isLoadingReferral = true
        Task {
            do {
                let (code, url) = try await ReferralService.shared.generateReferralCode()
                await MainActor.run {
                    referralCode = code
                    referralUrl = url
                    isLoadingReferral = false
                }
            } catch {
                log("PaywallSheet: referral load error: \(error.localizedDescription)")
                await MainActor.run {
                    isLoadingReferral = false
                }
            }
        }
    }

    private func copyLink() {
        guard !referralUrl.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(referralUrl, forType: .string)
        linkCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            linkCopied = false
        }
    }

    private func loadReferralCredit() {
        Task {
            if let status = try? await ReferralService.shared.fetchReferralStatus() {
                await MainActor.run {
                    referralCredit = status.reward_months * ReferralService.creditPerReferralUSD
                }
            }
        }
    }
}

// MARK: - Window Content Wrapper

private struct PaywallWindowContent: View {
    @ObservedObject var chatProvider: ChatProvider
    @ObservedObject private var authState = AuthState.shared
    let onDismiss: () -> Void

    /// Whether the embedded SignInView sheet is showing. Used for the
    /// `signin-optional` experiment's variant-B upgrade path: anonymous user
    /// taps Subscribe → SignInView appears → on success (Google linked or
    /// magic-link sign-in), we auto-continue to Stripe checkout.
    @State private var showingSignIn = false
    /// User tapped Subscribe and we're waiting for sign-in to complete so we
    /// can open checkout. Cleared if they cancel the sheet without signing in.
    @State private var checkoutPendingAfterSignIn = false

    var body: some View {
        PaywallSheet(
            onSubscribe: {
                if authState.isAnonymous {
                    // Variant B: route through SignInView first so the anon
                    // user becomes a named user before Stripe charges them.
                    // Google credential flow runs link(with:) inside
                    // signInWithGoogle and preserves the UID + trial state.
                    // Magic-link signs in fresh (anon UID is abandoned); the
                    // new Firebase user gets a fresh Stripe trial — fine for
                    // the experiment, can be improved in a follow-up.
                    log("PaywallSheet: anon user tapped Subscribe — presenting SignInView")
                    checkoutPendingAfterSignIn = true
                    showingSignIn = true
                    return
                }
                Task { @MainActor in
                    do {
                        try await SubscriptionService.shared.openCheckout()
                    } catch AuthError.notSignedIn {
                        AuthState.shared.error = "Your session expired. Please sign in again to upgrade."
                        AuthService.shared.reconcileAuthState()
                        onDismiss()
                    } catch {
                        log("PaywallSheet: Subscribe failed: \(error.localizedDescription)")
                    }
                }
            },
            onDismiss: onDismiss,
            onSwitchAccount: {
                log("PaywallSheet: switch-account tapped — signing out")
                AuthService.shared.signOut()
                // Signing out flips AuthState.isSignedIn, so DesktopHomeView
                // swaps in SignInView. Bring that window forward since it may
                // have been ordered out after the previous sign-in.
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.title.hasPrefix("Fazm") {
                    window.makeKeyAndOrderFront(nil)
                }
                onDismiss()
            }
        )
        .sheet(isPresented: $showingSignIn, onDismiss: {
            // If user dismissed without signing in (cancelled), clear the
            // pending flag so re-tapping Subscribe starts the flow fresh.
            checkoutPendingAfterSignIn = false
        }) {
            SignInView(authState: authState)
                .frame(width: 480, height: 600)
        }
        .onReceive(authState.$isAnonymous) { isAnon in
            // Sign-in succeeded (anon → named via Google link, or fresh
            // sign-in via magic link). Dismiss the sheet and continue to
            // checkout so the user lands where they intended.
            if !isAnon && checkoutPendingAfterSignIn {
                log("PaywallSheet: anon→named transition detected — continuing to checkout")
                showingSignIn = false
                checkoutPendingAfterSignIn = false
                Task { @MainActor in
                    do {
                        try await SubscriptionService.shared.openCheckout()
                    } catch {
                        log("PaywallSheet: post-link checkout failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        .onReceive(chatProvider.$showPaywall.removeDuplicates().dropFirst()) { show in
            if !show {
                onDismiss()
            }
        }
    }
}

// MARK: - Standalone Window Controller

/// Manages a standalone floating window for the paywall.
final class PaywallWindowController {
    static let shared = PaywallWindowController()
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?

    func show(chatProvider: ChatProvider, userInitiated: Bool = false) {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        Task { @MainActor in AnalyticsManager.shared.paywallShown() }
        let controller = self
        let content = PaywallWindowContent(
            chatProvider: chatProvider,
            onDismiss: { @MainActor in
                guard chatProvider.showPaywall else {
                    controller.close()
                    return
                }
                chatProvider.showPaywall = false
                controller.close()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.setFrameSize(NSSize(width: 400, height: 560))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 560)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.applyCrashWorkarounds()  // FAZM-20: disable auto touch bar / tabbing

        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = mouseScreen {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 400) / 2
            let y = sf.origin.y + (sf.height - 560) / 2
            window.setFrame(NSRect(x: x, y: y, width: 400, height: 560), display: true)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.hostingView = hostingView
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
