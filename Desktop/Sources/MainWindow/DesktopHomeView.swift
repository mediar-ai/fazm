import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @StateObject private var viewModelContainer = ViewModelContainer()
    @ObservedObject private var authState = AuthState.shared

    // Settings sidebar state
    @State private var selectedSettingsSection: SettingsContentView.SettingsSection = .conversationHistory
    @State private var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection? = nil
    @State private var highlightedSettingId: String? = nil

    // `signin-optional` experiment gate. While false, suppresses rendering of
    // SignInView so we have a chance to evaluate the PostHog feature flag and
    // (for variant B) sign the user in anonymously without ever showing the
    // wall. Flips to true once the gate has been decided — either anonymous
    // sign-in succeeded, failed, or the user is in the control cohort.
    @State private var signInGateDecided = false

    var body: some View {
        Group {
            if !signInGateDecided && !authState.isSignedIn {
                signInGateLoadingView
                    .task { await evaluateSignInGate() }
            } else if !authState.isSignedIn {
                SignInView(authState: authState)
            } else if !appState.hasCompletedOnboarding {
                if shouldSkipOnboarding() {
                    Color.clear.onAppear {
                        log("DesktopHomeView: --skip-onboarding flag detected, skipping onboarding")
                        appState.hasCompletedOnboarding = true
                    }
                } else {
                    OnboardingView(appState: appState, chatProvider: viewModelContainer.chatProvider, onComplete: nil)
                        .onAppear {
                            log("DesktopHomeView: Showing OnboardingView")
                        }
                }
            } else {
                settingsContent
                    .onAppear {
                        log("DesktopHomeView: Showing settings (onboarded)")
                        appState.checkAllPermissions()

                        // Set up floating control bar
                        FloatingControlBarManager.shared.setup(appState: appState, chatProvider: viewModelContainer.chatProvider)
                        if FloatingControlBarManager.shared.isEnabled {
                            FloatingControlBarManager.shared.show()
                        }

                        // EXPERIMENT 2026-05-28: skip window restoration to test
                        // whether restored detached windows are what drives the
                        // shared-main-thread relayout storm. Sample shows 7
                        // NSHostingView.layout calls 60Hz, matching the count of
                        // restored windows + bar + main. If with NO restored
                        // windows the storm is gone, the trigger is somewhere
                        // in the restoration path (likely a shared @Published
                        // mutated when a restored window observes it).
                        if UserDefaults.standard.bool(forKey: "fazm_restore_detached_windows_2028") {
                            DetachedChatWindowController.shared.restoreWindows(chatProvider: viewModelContainer.chatProvider)
                        } else {
                            log("DetachedChatWindowController: restoration DISABLED (experiment)")
                        }

                        // Set up push-to-talk voice input
                        if let barState = FloatingControlBarManager.shared.barState {
                            PushToTalkManager.shared.setup(barState: barState)

                            // EXPERIMENT 2026-05-28: gate this too. Even with
                            // recording itself disabled, observeActivity wires
                            // Combine subscriptions to barState.$voice etc.
                            // and NSApplication active/resign observers. Those
                            // alone fire frequently and ResourceMonitor shows
                            // a HOT THREAD with high sys time when active.
                            if UserDefaults.standard.bool(forKey: "fazm_enable_session_recording_2028") {
                                SessionRecordingManager.shared.observeActivity(
                                    barState: barState,
                                    chatProvider: viewModelContainer.chatProvider
                                )
                            }
                        }

                        // After onboarding or sign-in, close the main window — just show floating bar
                        let justOnboarded = UserDefaults.standard.bool(forKey: "onboardingJustCompleted")
                        let justSignedIn = UserDefaults.standard.bool(forKey: "signInJustCompleted")
                        if justOnboarded || justSignedIn {
                            if justOnboarded {
                                UserDefaults.standard.set(false, forKey: "onboardingJustCompleted")
                                log("DesktopHomeView: Post-onboarding — closing main window, showing floating bar only")
                            }
                            if justSignedIn {
                                UserDefaults.standard.set(false, forKey: "signInJustCompleted")
                                log("DesktopHomeView: Post-sign-in — closing main window, showing floating bar only")
                            }
                            // Ensure floating bar is visible
                            if !FloatingControlBarManager.shared.isEnabled {
                                FloatingControlBarManager.shared.show()
                            }
                            DispatchQueue.main.async {
                                for window in NSApp.windows {
                                    if window.title.hasPrefix("Fazm") {
                                        window.orderOut(nil)
                                    }
                                }
                            }
                        }
                    }
                    .task {
                        await viewModelContainer.loadAllData()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .userDidSignOut)) { _ in
                        log("DesktopHomeView: userDidSignOut — resetting hasCompletedOnboarding")
                        appState.hasCompletedOnboarding = false
                    }
            }
        }
        .background(FazmColors.backgroundPrimary)
        .frame(minWidth: 900, minHeight: 600)
        .tint(FazmColors.purplePrimary)
        // Hard paywall at sign-in: the moment auth flips to signed-in, refresh
        // subscription status and gate the user before onboarding can start.
        // Re-runs on every sign-in (also fires once at launch when cached auth
        // restores isSignedIn = true).
        .task(id: authState.isSignedIn) {
            guard authState.isSignedIn else { return }
            log("DesktopHomeView: sign-in detected — checking subscription")
            await SubscriptionService.shared.refreshStatus()
            if SubscriptionService.shared.shouldShowPaywall() {
                log("DesktopHomeView: sign-in gate — no active subscription, showing paywall")
                viewModelContainer.chatProvider.showPaywall = true
                PaywallWindowController.shared.show(chatProvider: viewModelContainer.chatProvider)
            }
        }
        // Observe ChatProvider flags
        .onReceive(viewModelContainer.chatProvider.$needsBrowserExtensionSetup) { needs in
            if needs {
                viewModelContainer.chatProvider.needsBrowserExtensionSetup = false
                BrowserExtensionSetupWindowController.shared.show(
                    chatProvider: viewModelContainer.chatProvider,
                    onComplete: {
                        // Route the continuation back to the chat surface the
                        // user was actually using (floating bar, pop-out, main
                        // chat, or onboarding) instead of always dumping it in
                        // the floating bar. Fix for the "AI loses context after
                        // extension install" bug reported by amabdig@gmail.com
                        // 2026-05-13.
                        viewModelContainer.chatProvider.retryAfterBrowserSetup()
                    },
                    source: "chat_interception"
                )
            }
        }
        // Paywall window is now triggered directly in ChatProvider.sendMessage()
        // so it works from all surfaces (floating bar, detached window, main window)
        .onAppear {
            log("DesktopHomeView: View appeared - hasCompletedOnboarding=\(appState.hasCompletedOnboarding)")
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    if window.title.hasPrefix("Fazm") {
                        window.minSize = NSSize(width: 900, height: 600)
                    }
                }
            }
        }
    }

    // MARK: - Sign-In Gate (signin-optional experiment)

    /// Brief placeholder shown while the `signin-optional` PostHog flag is
    /// evaluated and (for variant B) anonymous sign-in completes. Avoids a
    /// flash of SignInView before we know which cohort the user is in.
    private var signInGateLoadingView: some View {
        ZStack {
            FazmColors.backgroundPrimary
            ProgressView()
                .controlSize(.large)
                .tint(FazmColors.purplePrimary)
        }
    }

    /// Read the `signin-optional` PostHog flag, emit an exposure event, and
    /// for the treatment cohort sign the user in anonymously so the rest of
    /// the app sees an authenticated UID without a wall. Sets
    /// `signInGateDecided = true` exactly once per launch so the body falls
    /// through to either onboarding (sign-in succeeded) or SignInView (control
    /// cohort, or anonymous sign-in failed).
    @MainActor
    private func evaluateSignInGate() async {
        guard !signInGateDecided else { return }

        let flag = await PostHogManager.shared.evaluateFeatureFlagAfterReload("signin-optional")
        let flagEnabled = flag.enabled
        let variant = flagEnabled ? "treatment" : "control"
        let deviceId = UserDefaults.standard.string(forKey: "analytics_device_id") ?? ""
        PostHogManager.shared.track("signin_optional_exposed", properties: [
            "variant": variant,
            "device_id": deviceId,
            "flag_resolved": flag.resolved,
            "flag_value": flag.valueDescription
        ])
        log("DesktopHomeView: signin-optional gate evaluated — variant=\(variant), flag_resolved=\(flag.resolved), flag_value=\(flag.valueDescription)")

        if flagEnabled {
            do {
                try await AuthService.shared.signInAnonymously()
                // AuthState.isSignedIn flips to true via the post-auth cascade;
                // the next render passes through to onboarding/settings.
                UserDefaults.standard.set(true, forKey: "signInJustCompleted")
            } catch {
                log("DesktopHomeView: anonymous sign-in failed (\(error.localizedDescription)) — falling back to SignInView")
            }
        }

        signInGateDecided = true
    }

    private var settingsContent: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selectedSection: $selectedSettingsSection,
                selectedAdvancedSubsection: $selectedAdvancedSubsection,
                highlightedSettingId: $highlightedSettingId,
                appState: appState
            )
            .fixedSize(horizontal: true, vertical: false)
            .clipped()

            // Main content area with rounded container
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(FazmColors.backgroundSecondary.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(FazmColors.backgroundTertiary.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 4)

                SettingsPage(
                    appState: appState,
                    selectedSection: $selectedSettingsSection,
                    selectedAdvancedSubsection: $selectedAdvancedSubsection,
                    highlightedSettingId: $highlightedSettingId,
                    chatProvider: viewModelContainer.chatProvider
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
        // Handle navigation from floating bar gear icon
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFloatingBarSettings)) { _ in
            selectedSettingsSection = .shortcuts
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAIChatSettings)) { _ in
            selectedSettingsSection = .advanced
            selectedAdvancedSubsection = .aiChat
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("navigateToSetting"))) { notification in
            guard let settingId = notification.userInfo?["settingId"] as? String,
                  let item = SettingsSearchItem.allSearchableItems.first(where: { $0.settingId == settingId }) else { return }
            selectedSettingsSection = item.section
            if let sub = item.advancedSubsection {
                selectedAdvancedSubsection = sub
            }
        }
    }
}

#Preview {
    DesktopHomeView()
}
