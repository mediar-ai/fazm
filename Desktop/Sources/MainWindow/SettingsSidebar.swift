import SwiftUI

// MARK: - Search Data Model

struct SettingsSearchItem: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let keywords: [String]
    let section: SettingsContentView.SettingsSection
    let advancedSubsection: SettingsContentView.AdvancedSubsection?
    let icon: String
    let settingId: String

    var breadcrumb: String {
        if let sub = advancedSubsection {
            return "Advanced \u{2192} \(sub.rawValue)"
        }
        return section.rawValue
    }

    static let allSearchableItems: [SettingsSearchItem] = [
        // Conversations
        SettingsSearchItem(name: "Conversation History", subtitle: "View and reopen past AI conversations", keywords: ["conversations", "history", "chat history", "past chats", "sessions", "previous"], section: .conversationHistory, advancedSubsection: nil, icon: "clock.arrow.circlepath", settingId: "conversationhistory.list"),

        // Routines
        SettingsSearchItem(name: "Routines", subtitle: "Recurring AI tasks that run on a schedule", keywords: ["routines", "schedule", "scheduled", "cron", "recurring", "automation", "every day", "every week", "morning", "agent", "background"], section: .routines, advancedSubsection: nil, icon: "repeat.circle", settingId: "routines.list"),

        // General
        SettingsSearchItem(name: "Microphone", subtitle: "Select which microphone to use for Push to Talk", keywords: ["microphone", "mic", "audio input", "recording device"], section: .general, advancedSubsection: nil, icon: "mic.fill", settingId: "general.microphone"),
        SettingsSearchItem(name: "Language Mode", subtitle: "Choose auto-detect or single language for transcription", keywords: ["language", "transcription", "auto-detect", "multi-language", "single language"], section: .general, advancedSubsection: nil, icon: "globe", settingId: "general.languagemode"),
        SettingsSearchItem(name: "Font Size", subtitle: "Adjust text size across the app", keywords: ["text size", "zoom", "scale", "reset"], section: .general, advancedSubsection: nil, icon: "gearshape", settingId: "general.fontsize"),
        SettingsSearchItem(name: "Appearance", subtitle: "Switch between light, dark, or system theme", keywords: ["appearance", "theme", "dark mode", "light mode", "color scheme"], section: .general, advancedSubsection: nil, icon: "circle.lefthalf.filled", settingId: "general.appearance"),
        SettingsSearchItem(name: "Voice Response", subtitle: "AI speaks responses aloud using text-to-speech", keywords: ["voice", "tts", "text to speech", "speak", "audio", "sound", "speed", "voice language", "auto-detect", "manual", "language"], section: .general, advancedSubsection: nil, icon: "speaker.wave.2.fill", settingId: "general.voiceresponse"),

        // Remote Control
        SettingsSearchItem(name: "Connect Your Phone", subtitle: "Control Fazm from your phone via chat.fazm.ai", keywords: ["phone", "remote", "mobile", "qr code", "relay", "websocket", "remote control"], section: .remoteControl, advancedSubsection: nil, icon: "iphone", settingId: "remotecontrol.connect"),
        SettingsSearchItem(name: "Connection Status", subtitle: "Phone relay and connection status", keywords: ["status", "connected", "online", "relay", "phone"], section: .remoteControl, advancedSubsection: nil, icon: "antenna.radiowaves.left.and.right", settingId: "remotecontrol.status"),
        SettingsSearchItem(name: "How It Works", subtitle: "Steps to connect your phone to Fazm", keywords: ["how it works", "instructions", "setup steps", "connect phone"], section: .remoteControl, advancedSubsection: nil, icon: "questionmark.circle", settingId: "remotecontrol.howitworks"),

        // Permissions
        SettingsSearchItem(name: "Permissions", subtitle: "Manage screen recording, microphone, and accessibility permissions", keywords: ["permissions", "screen recording", "microphone", "accessibility", "privacy", "security"], section: .permissions, advancedSubsection: nil, icon: "lock.shield", settingId: "permissions.permissions"),

        // Memory
        SettingsSearchItem(name: "Memory Graph", subtitle: "Visual 3D graph of AI memory and knowledge", keywords: ["memory", "graph", "knowledge", "brain", "3d", "visualization"], section: .memoryGraph, advancedSubsection: nil, icon: "brain.head.profile", settingId: "memorygraph.view"),

        // Dictionary
        SettingsSearchItem(name: "Dictionary", subtitle: "Custom words to improve transcription accuracy", keywords: ["dictionary", "vocabulary", "transcription", "words", "phrases", "keyterm"], section: .dictionary, advancedSubsection: nil, icon: "character.book.closed", settingId: "dictionary.dictionary"),

        // Shortcuts
        SettingsSearchItem(name: "Ask Fazm Shortcut", subtitle: "Global shortcut to open Ask Fazm from anywhere", keywords: ["shortcut", "hotkey", "keyboard", "global shortcut"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.shortcut"),
        SettingsSearchItem(name: "New Pop-Out Chat", subtitle: "Global shortcut to open a new chat in its own window", keywords: ["shortcut", "pop out", "new chat", "window", "detach"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.newpopoutchat"),
        SettingsSearchItem(name: "Push to Talk", subtitle: "Hold a key to speak, release to send your question to AI", keywords: ["push to talk", "ptt", "hold to talk", "microphone key"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.ptt"),
        SettingsSearchItem(name: "Transcription Mode", subtitle: "Choose how voice input is processed", keywords: ["transcription", "mode", "voice", "dictation"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.transcriptionmode"),
        SettingsSearchItem(name: "Double-tap for Locked Mode", subtitle: "Double-tap the push-to-talk key to keep listening hands-free", keywords: ["double tap", "locked mode", "hands free", "listening"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.doubletap"),
        SettingsSearchItem(name: "Push-to-Talk Sounds", subtitle: "Play audio feedback when starting and ending voice input", keywords: ["sounds", "audio feedback", "ptt sounds"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.pttsounds"),

        // Advanced > AI Chat
        SettingsSearchItem(name: "Claude Account", subtitle: "Switch between built-in and personal Claude account", keywords: ["account", "vertex", "built-in", "oauth", "sign in"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.account"),
        SettingsSearchItem(name: "Custom API Endpoint", subtitle: "Route API calls through a custom proxy or gateway", keywords: ["endpoint", "proxy", "base url", "anthropic", "copilot", "gateway", "corporate"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.endpoint"),
        SettingsSearchItem(name: "Workspace", subtitle: "Set a project directory for AI chat context", keywords: ["workspace", "project", "directory", "folder", "working directory", "claude.md"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.workspace"),
        SettingsSearchItem(name: "CLAUDE.md", subtitle: "Personal instructions loaded into AI chat", keywords: ["claude md", "claude config", "instructions", "view"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.claudemd"),
        SettingsSearchItem(name: "Skills", subtitle: "Enable or disable discovered AI skills", keywords: ["skills", "plugins", "abilities", "view"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.skills"),
        SettingsSearchItem(name: "Browser Extension", subtitle: "Lets the AI use your Chrome browser with all your logged-in sessions", keywords: ["playwright", "chrome", "browser extension", "browser", "set up", "reconfigure", "token"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.browserextension"),
        SettingsSearchItem(name: "Dev Mode", subtitle: "Developer tools and debugging options", keywords: ["developer", "debug", "dev mode", "development"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.devmode"),

        // Advanced > Preferences
        SettingsSearchItem(name: "Floating Bar Visibility", subtitle: "Show or hide the floating chat bar", keywords: ["floating bar", "chat bar", "ask fazm"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.askomi"),
        SettingsSearchItem(name: "AI Model", subtitle: "Choose the AI model for Ask Fazm conversations", keywords: ["model", "ai", "sonnet", "opus", "claude"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.aimodel"),
        SettingsSearchItem(name: "Response Style", subtitle: "Control response compactness", keywords: ["response", "style", "compact", "concise", "strict", "soft"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.responsestyle"),
        SettingsSearchItem(name: "Proactiveness", subtitle: "How proactive the AI assistant should be", keywords: ["proactive", "passive", "balanced", "autonomous", "agent"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.proactiveness"),
        SettingsSearchItem(name: "Screen Observer", subtitle: "Watches your screen and suggests tasks AI can help with", keywords: ["screen observer", "discovered tasks", "watch screen", "suggestions"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.screenObserver"),
        SettingsSearchItem(name: "Draggable Floating Bar", subtitle: "Allow repositioning the floating bar by dragging it", keywords: ["drag", "move", "reposition", "draggable"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.draggable"),
        SettingsSearchItem(name: "Launch at Login", subtitle: "Start Fazm automatically when you log in", keywords: ["startup", "login", "boot"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.launchatlogin"),
        SettingsSearchItem(name: "Tool Timeout", subtitle: "Max time a tool can run before being stopped", keywords: ["tool", "timeout", "stuck", "hang", "freeze", "unresponsive"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.tooltimeout"),

        // Advanced > Troubleshooting
        SettingsSearchItem(name: "Report Issue", subtitle: "Send app logs and report a problem", keywords: ["bug", "feedback", "logs", "report"], section: .advanced, advancedSubsection: .troubleshooting, icon: "wrench.and.screwdriver", settingId: "advanced.troubleshooting.reportissue"),
        SettingsSearchItem(name: "Rescan Files", subtitle: "Re-index your files and update your AI profile", keywords: ["rescan", "re-index", "files", "profile", "scan"], section: .advanced, advancedSubsection: .troubleshooting, icon: "wrench.and.screwdriver", settingId: "advanced.troubleshooting.rescanfiles"),
        SettingsSearchItem(name: "Reset Onboarding", subtitle: "Restart setup wizard and reset permissions", keywords: ["setup", "wizard", "permissions", "reset"], section: .advanced, advancedSubsection: .troubleshooting, icon: "wrench.and.screwdriver", settingId: "advanced.troubleshooting.resetonboarding"),

        // Advanced > MCP Servers
        SettingsSearchItem(name: "MCP Servers", subtitle: "Connect external tools via the Model Context Protocol", keywords: ["mcp", "server", "tools", "protocol", "integration", "external", "plugin"], section: .advanced, advancedSubsection: .mcpServers, icon: "server.rack", settingId: "advanced.mcpservers.info"),

        // Advanced > AI Chat > Codex Backend (lives in the AI Chat subsection)
        SettingsSearchItem(name: "Codex Backend", subtitle: "Route GPT-5 family models through OpenAI's Codex CLI", keywords: ["codex", "openai", "chatgpt", "gpt", "gpt-5", "gpt5", "openai api", "openai backend", "disconnect"], section: .advanced, advancedSubsection: .aiChat, icon: "sparkles", settingId: "advanced.codex.toggle"),

        // Account
        SettingsSearchItem(name: "Account", subtitle: "Your signed-in account and sign out", keywords: ["account", "sign out", "email", "profile", "user"], section: .about, advancedSubsection: nil, icon: "person.crop.circle", settingId: "about.account"),
        SettingsSearchItem(name: "Subscription", subtitle: "Manage your Fazm Pro subscription or free trial", keywords: ["subscription", "pro", "upgrade", "trial", "plan", "billing", "payment"], section: .about, advancedSubsection: nil, icon: "checkmark.seal.fill", settingId: "about.subscription"),
        SettingsSearchItem(name: "Referrals", subtitle: "Refer friends and earn free months of Pro", keywords: ["referral", "refer", "invite", "friend", "credit", "free month", "share"], section: .about, advancedSubsection: nil, icon: "person.2.fill", settingId: "about.referral"),
        SettingsSearchItem(name: "Version Info", subtitle: "Current app version and build number", keywords: ["version", "build", "app version", "build number"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.version"),
        SettingsSearchItem(name: "Software Updates", subtitle: "Check for and manage app updates", keywords: ["update", "auto update", "sparkle", "version", "check for updates", "check now"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.updates"),
        SettingsSearchItem(name: "Automatic Updates", subtitle: "Check for updates automatically in the background", keywords: ["auto check", "background updates", "check automatically"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.autoupdates"),
        SettingsSearchItem(name: "Auto-Install Updates", subtitle: "Automatically download and install updates when available", keywords: ["auto install", "automatic install", "download updates", "install updates"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.autoinstall"),
        SettingsSearchItem(name: "Update Channel", subtitle: "Choose between beta and staging update channels", keywords: ["channel", "beta", "staging", "release channel"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.channel"),
        SettingsSearchItem(name: "Report an Issue", subtitle: "Help us improve Fazm", keywords: ["bug", "feedback", "report", "issue"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.reportissue"),
    ]
}

/// Settings sidebar for navigating settings sections
struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsContentView.SettingsSection
    @Binding var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection?
    @Binding var highlightedSettingId: String?
    @ObservedObject var appState: AppState

    @ObservedObject private var updaterViewModel = UpdaterViewModel.shared
    @ObservedObject private var founderChatService = FounderChatService.shared
    @State private var searchQuery = ""
    @State private var updateGlowAnimating = false
    @State private var discoveredTasksUnread = 0
    @FocusState private var isSearchFocused: Bool

    // Surfaces the Sparkle 4005 install error state so users can recover after
    // dismissing the setup guide. Set in UpdaterViewModel when 4005 fires; cleared
    // (via `hasSuccessfullyInstalledSparkleUpdate`) once an update installs cleanly.
    @AppStorage("hasSeenAppManagementError") private var hasSeenAppManagementError: Bool = false
    @AppStorage("hasSuccessfullyInstalledSparkleUpdate") private var hasInstalledSparkleUpdate: Bool = false
    // Dismissed = user clicked the X. We still render the widget but grayed out,
    // so the issue stays visible (still tappable) without nagging them in red.
    // Cleared when a fresh 4005 error fires (UpdaterViewModel) and when an
    // update installs successfully.
    @AppStorage("appManagementWarningDismissed") private var appManagementWarningDismissed: Bool = false

    private var showAppManagementWarning: Bool {
        hasSeenAppManagementError && !hasInstalledSparkleUpdate
    }

    private let unreadRefreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private let expandedWidth: CGFloat = 260
    private let iconWidth: CGFloat = 20

    private var filteredSearchItems: [SettingsSearchItem] {
        guard !searchQuery.isEmpty else { return [] }
        let words = searchQuery.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return SettingsSearchItem.allSearchableItems.filter { item in
            let nameLower = item.name.lowercased()
            let subtitleLower = item.subtitle.lowercased()
            let keywordsLower = item.keywords.map { $0.lowercased() }
            return words.allSatisfy { word in
                nameLower.contains(word) ||
                subtitleLower.contains(word) ||
                keywordsLower.contains(where: { $0.contains(word) })
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            Text("Fazm")
                .scaledFont(size: 22, weight: .bold)
                .foregroundColor(FazmColors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // Search field
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            if searchQuery.isEmpty {
                // Normal settings sections
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsContentView.SettingsSection.allCases, id: \.self) { section in
                            SettingsSidebarItem(
                                section: section,
                                isSelected: selectedSection == section,
                                iconWidth: iconWidth,
                                showWarning: section == .permissions && appState.hasMissingPermissions,
                                badgeCount: section == .discoveredTasks ? discoveredTasksUnread : (section == .chatWithFounder ? founderChatService.unreadCount : 0),
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedSection = section
                                        if section == .advanced && selectedAdvancedSubsection == nil {
                                            selectedAdvancedSubsection = .aiChat
                                        }
                                    }
                                }
                            )

                            // Show Advanced subsections when Advanced is selected
                            if section == .advanced && selectedSection == .advanced {
                                ForEach(SettingsContentView.AdvancedSubsection.allCases, id: \.self) { subsection in
                                    SettingsSubsectionItem(
                                        subsection: subsection,
                                        isSelected: selectedAdvancedSubsection == subsection,
                                        iconWidth: iconWidth,
                                        onTap: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                selectedAdvancedSubsection = subsection
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            } else {
                // Search results
                searchResultsList
                    .padding(.horizontal, 8)
            }

            Spacer()

            // Screen recording permission widget
            if !appState.hasScreenRecordingPermission {
                screenRecordingWidget
                    .padding(.horizontal, 8)
                    .padding(.bottom, (showAppManagementWarning || updaterViewModel.updateAvailable) ? 8 : 16)
                    .transition(.opacity)
            }

            // App Management permission warning (Sparkle 4005 recovery)
            if showAppManagementWarning {
                appManagementWarningWidget
                    .padding(.horizontal, 8)
                    .padding(.bottom, updaterViewModel.updateAvailable ? 8 : 16)
                    .transition(.opacity)
            }

            // Update available widget
            if updaterViewModel.updateAvailable {
                updateAvailableWidget
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .frame(width: expandedWidth)
        .background(FazmColors.backgroundPrimary)
        .onAppear {
            refreshUnreadCount()
            founderChatService.startPolling()
        }
        .onReceive(unreadRefreshTimer) { _ in refreshUnreadCount() }
    }

    private func refreshUnreadCount() {
        Task {
            let count = await DiscoveredTasksStore.unreadCount()
            await MainActor.run { discoveredTasksUnread = count }
        }
    }

    // MARK: - Screen Recording Permission Widget
    private var screenRecordingWidget: some View {
        Button(action: {
            SessionRecordingPermissionWindowController.shared.showFromSidebar {
                // Permission granted — SessionRecordingManager will pick it up on next poll
                SessionRecordingManager.shared.checkFlagAndUpdate()
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .scaledFont(size: 17)
                    .foregroundColor(.orange)
                    .frame(width: iconWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(FazmColors.textPrimary)

                    Text("Permission needed")
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(FazmColors.backgroundTertiary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Management Warning Widget
    // Shown when a Sparkle 4005 install error occurred. Tapping the body
    // reopens the recovery guide. The X button dismisses the warning into a
    // grayed-out state so it stays visible (still tappable) without nagging
    // in red. Auto-hides only after an update installs successfully.
    private var appManagementWarningWidget: some View {
        let dismissed = appManagementWarningDismissed
        let accent: Color = dismissed ? FazmColors.textTertiary : .red
        let titleColor: Color = dismissed ? FazmColors.textSecondary : FazmColors.textPrimary
        let subtitleColor: Color = dismissed ? FazmColors.textTertiary : FazmColors.textSecondary
        let strokeOpacity: Double = dismissed ? 0.18 : 0.35

        return HStack(spacing: 12) {
            Button(action: {
                let version = updaterViewModel.availableVersion.isEmpty
                    ? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                    : updaterViewModel.availableVersion
                AppManagementSetupWindowController.shared.show(
                    version: version,
                    onDone: {
                        UserDefaults.standard.set(true, forKey: "hasSuccessfullyInstalledSparkleUpdate")
                        UserDefaults.standard.set(false, forKey: "appManagementWarningDismissed")
                        UpdaterViewModel.shared.checkForUpdatesInBackground()
                    },
                    onDismiss: { /* keep widget visible until permission granted */ }
                )
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 17)
                        .foregroundColor(accent)
                        .frame(width: iconWidth)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-updates blocked")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundColor(titleColor)

                        Text("App Management permission needed")
                            .scaledFont(size: 11)
                            .foregroundColor(subtitleColor)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !dismissed {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appManagementWarningDismissed = true
                    }
                }) {
                    Image(systemName: "xmark")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundColor(FazmColors.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss (still accessible, will gray out)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(FazmColors.backgroundTertiary)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(accent.opacity(strokeOpacity), lineWidth: 1)
                )
        )
        .opacity(dismissed ? 0.6 : 1.0)
    }

    // MARK: - Update Available Widget
    private var updateAvailableWidget: some View {
        Button(action: {
            updaterViewModel.checkForUpdates()
        }) {
            HStack(spacing: 12) {
                if updaterViewModel.updateSessionInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                        .frame(width: iconWidth)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .scaledFont(size: 17)
                        .foregroundColor(.white)
                        .frame(width: iconWidth)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(updaterViewModel.updateSessionInProgress ? "Updating..." : "Update Available")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(.white)

                    if !updaterViewModel.availableVersion.isEmpty {
                        Text("v\(updaterViewModel.availableVersion)")
                            .scaledFont(size: 11)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }

                Spacer()

                if !updaterViewModel.updateSessionInProgress {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(FazmColors.purplePrimary)
            )
            .shadow(color: FazmColors.purplePrimary.opacity(updateGlowAnimating ? 0.7 : 0.3), radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(updaterViewModel.updateSessionInProgress)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                updateGlowAnimating = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 13)
                .foregroundColor(isSearchFocused ? FazmColors.purplePrimary : FazmColors.textTertiary)
                .animation(.easeInOut(duration: 0.15), value: isSearchFocused)

            TextField("Search...", text: $searchQuery)
                .textFieldStyle(.plain)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textPrimary)
                .focused($isSearchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(FazmColors.backgroundTertiary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSearchFocused ? FazmColors.purplePrimary.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
    }

    private var searchResultsList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                if filteredSearchItems.isEmpty {
                    Text("No results")
                        .scaledFont(size: 13)
                        .foregroundColor(FazmColors.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 20)
                } else {
                    ForEach(filteredSearchItems) { item in
                        SettingsSearchResultRow(item: item) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedSection = item.section
                                if let sub = item.advancedSubsection {
                                    selectedAdvancedSubsection = sub
                                } else if item.section == .advanced {
                                    selectedAdvancedSubsection = .aiChat
                                }
                            }
                            searchQuery = ""
                            let targetId = item.settingId
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                highlightedSettingId = targetId
                            }
                        }
                    }
                }
            }
        }
    }

}

// MARK: - Settings Sidebar Item
struct SettingsSidebarItem: View {
    let section: SettingsContentView.SettingsSection
    let isSelected: Bool
    let iconWidth: CGFloat
    var showWarning: Bool = false
    var badgeCount: Int = 0
    let onTap: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch section {
        case .conversationHistory: return "clock.arrow.circlepath"
        case .home: return "menubar.dock.rectangle"
        case .chatWithFounder: return "bubble.left.and.bubble.right"
        case .routines: return "repeat.circle"
        case .discoveredTasks: return "wand.and.stars"
        case .remoteControl: return "iphone"
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .permissions: return "lock.shield"
        case .dictionary: return "character.book.closed"
        case .memoryGraph: return "brain.head.profile"
        case .advanced: return "chart.bar"
        case .about: return "info.circle"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .scaledFont(size: 17)
                    .foregroundColor(isSelected ? FazmColors.textPrimary : FazmColors.textTertiary)
                    .frame(width: iconWidth)

                Text(section.rawValue)
                    .scaledFont(size: 14, weight: isSelected ? .medium : .regular)
                    .foregroundColor(isSelected ? FazmColors.textPrimary : FazmColors.textSecondary)

                Spacer()

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple))
                }

                if showWarning {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? FazmColors.backgroundTertiary.opacity(0.8)
                          : (isHovered ? FazmColors.backgroundTertiary.opacity(0.5) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Settings Subsection Item
struct SettingsSubsectionItem: View {
    let subsection: SettingsContentView.AdvancedSubsection
    let isSelected: Bool
    let iconWidth: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Indentation spacer
                Spacer()
                    .frame(width: iconWidth + 12)

                Image(systemName: subsection.icon)
                    .scaledFont(size: 14)
                    .foregroundColor(isSelected ? FazmColors.textPrimary : FazmColors.textTertiary)
                    .frame(width: 16)

                Text(subsection.rawValue)
                    .scaledFont(size: 13, weight: isSelected ? .medium : .regular)
                    .foregroundColor(isSelected ? FazmColors.textPrimary : FazmColors.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? FazmColors.backgroundTertiary.opacity(0.6)
                          : (isHovered ? FazmColors.backgroundTertiary.opacity(0.3) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Settings Search Result Row
struct SettingsSearchResultRow: View {
    let item: SettingsSearchItem
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .scaledFont(size: 14)
                    .foregroundColor(FazmColors.textTertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundColor(FazmColors.textPrimary)

                    Text(item.breadcrumb)
                        .scaledFont(size: 11)
                        .foregroundColor(FazmColors.textTertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? FazmColors.backgroundTertiary.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Setting Highlight Modifier

struct SettingHighlightModifier: ViewModifier {
    let settingId: String
    @Binding var highlightedSettingId: String?
    @State private var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .id(settingId)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? FazmColors.purplePrimary.opacity(0.12) : Color.clear)
                    .animation(.easeInOut(duration: 0.3), value: isHighlighted)
                    .allowsHitTesting(false)
            )
            .onChange(of: highlightedSettingId) { _, newId in
                if newId == settingId {
                    withAnimation { isHighlighted = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.5)) { isHighlighted = false }
                        if highlightedSettingId == settingId { highlightedSettingId = nil }
                    }
                }
            }
    }
}

#Preview {
    SettingsSidebar(
        selectedSection: .constant(.advanced),
        selectedAdvancedSubsection: .constant(.aiChat),
        highlightedSettingId: .constant(nil),
        appState: AppState()
    )
}
