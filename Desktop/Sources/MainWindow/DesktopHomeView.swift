import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @StateObject private var viewModelContainer = ViewModelContainer()

    // Settings sidebar state
    @State private var selectedSettingsSection: SettingsContentView.SettingsSection = .aiChat
    @State private var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection? = nil
    @State private var highlightedSettingId: String? = nil

    // Sheet triggers (driven by ChatProvider @Published flags)
    @State private var showBrowserExtensionSetup = false
    @State private var showClaudeAuth = false

    var body: some View {
        Group {
            if !appState.hasCompletedOnboarding {
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

                        // Set up push-to-talk voice input
                        if let barState = FloatingControlBarManager.shared.barState {
                            PushToTalkManager.shared.setup(barState: barState)
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
        .preferredColorScheme(.dark)
        .tint(FazmColors.purplePrimary)
        // Browser extension setup (triggered when browser tool called without token)
        .sheet(isPresented: $showBrowserExtensionSetup) {
            BrowserExtensionSetup(
                onComplete: {
                    showBrowserExtensionSetup = false
                    viewModelContainer.chatProvider.retryPendingMessage()
                },
                onDismiss: { showBrowserExtensionSetup = false },
                chatProvider: viewModelContainer.chatProvider
            )
            .fixedSize()
        }
        // Claude auth (triggered when ACP bridge needs OAuth)
        .sheet(isPresented: $showClaudeAuth) {
            ClaudeAuthSheet(
                onConnect: {
                    viewModelContainer.chatProvider.startClaudeAuth()
                },
                onCancel: {
                    showClaudeAuth = false
                }
            )
        }
        // Observe ChatProvider flags
        .onReceive(viewModelContainer.chatProvider.$needsBrowserExtensionSetup) { needs in
            if needs {
                showBrowserExtensionSetup = true
                viewModelContainer.chatProvider.needsBrowserExtensionSetup = false
            }
        }
        .onReceive(viewModelContainer.chatProvider.$isClaudeAuthRequired) { needs in
            if needs {
                showClaudeAuth = true
            }
        }
        .onAppear {
            log("DesktopHomeView: View appeared - hasCompletedOnboarding=\(appState.hasCompletedOnboarding)")
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    if window.title.hasPrefix("Fazm") {
                        window.appearance = NSAppearance(named: .darkAqua)
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
                highlightedSettingId: $highlightedSettingId
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
            selectedSettingsSection = .advanced
            selectedAdvancedSubsection = .askFazmFloatingBar
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAIChatSettings)) { _ in
            selectedSettingsSection = .aiChat
        }
    }
}

#Preview {
    DesktopHomeView()
}
