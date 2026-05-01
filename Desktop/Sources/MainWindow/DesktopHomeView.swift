import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @StateObject private var viewModelContainer = ViewModelContainer()
    @ObservedObject private var authState = AuthState.shared

    // Settings sidebar state
    @State private var selectedSettingsSection: SettingsContentView.SettingsSection = .conversationHistory
    @State private var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection? = nil
    @State private var highlightedSettingId: String? = nil

    var body: some View {
        Group {
            if !authState.isSignedIn {
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

                        // Restore detached chat windows from the previous session
                        DetachedChatWindowController.shared.restoreWindows(chatProvider: viewModelContainer.chatProvider)

                        // Set up push-to-talk voice input
                        if let barState = FloatingControlBarManager.shared.barState {
                            PushToTalkManager.shared.setup(barState: barState)

                            // Wire session recording pause/resume to user interaction signals
                            SessionRecordingManager.shared.observeActivity(
                                barState: barState,
                                chatProvider: viewModelContainer.chatProvider
                            )
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

                        // Hard paywall on every launch: refresh subscription status, and if not
                        // active, fire the paywall window before the user can do anything.
                        // No free trial, no free daily messages.
                        Task { @MainActor in
                            await SubscriptionService.shared.refreshStatus()
                            if SubscriptionService.shared.shouldShowPaywall() {
                                log("DesktopHomeView: launch-gate — no active subscription, showing paywall")
                                viewModelContainer.chatProvider.showPaywall = true
                                PaywallWindowController.shared.show(chatProvider: viewModelContainer.chatProvider)
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
                        FloatingControlBarManager.shared.retryPendingQuery()
                    },
                    source: "chat_interception"
                )
            }
        }
        .onReceive(viewModelContainer.chatProvider.$isClaudeAuthRequired) { needs in
            if needs {
                ClaudeAuthWindowController.shared.show(chatProvider: viewModelContainer.chatProvider)
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
