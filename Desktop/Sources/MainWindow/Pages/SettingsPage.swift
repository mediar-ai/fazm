import SwiftUI
import Sparkle
import UniformTypeIdentifiers

/// Settings page that wraps SettingsView with proper dark theme styling for the main window
struct SettingsPage: View {
    @ObservedObject var appState: AppState
    @Binding var selectedSection: SettingsContentView.SettingsSection
    @Binding var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection?
    @Binding var highlightedSettingId: String?
    var chatProvider: ChatProvider? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Section header
                    HStack {
                        Text(selectedSection == .advanced && selectedAdvancedSubsection != nil
                             ? selectedAdvancedSubsection!.rawValue
                             : selectedSection.rawValue)
                            .scaledFont(size: 28, weight: .bold)
                            .foregroundColor(FazmColors.textPrimary)
                            .id(selectedSection)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.15), value: selectedSection)

                        Spacer()
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                    // Settings content - embedded SettingsView with dark theme override
                    SettingsContentView(
                        appState: appState,
                        selectedSection: $selectedSection,
                        selectedAdvancedSubsection: $selectedAdvancedSubsection,
                        highlightedSettingId: $highlightedSettingId,
                        chatProvider: chatProvider
                    )
                    .padding(.horizontal, 32)

                    Spacer()
                }
            }
            .onChange(of: highlightedSettingId) { _, newId in
                guard let newId = newId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
        .background(FazmColors.backgroundSecondary.opacity(0.3))
        .onAppear {
            AnalyticsManager.shared.settingsPageOpened()
        }
        .onChange(of: selectedSection) { _, newValue in
            if newValue == .advanced && selectedAdvancedSubsection == nil {
                selectedAdvancedSubsection = .aiChat
            }
        }
    }
}

/// Dark-themed settings content matching the main window style
struct SettingsContentView: View {
    // AppState for transcription control
    @ObservedObject var appState: AppState

    // ChatProvider for browser extension setup
    var chatProvider: ChatProvider? = nil

    // Updater view model
    @ObservedObject private var updaterViewModel = UpdaterViewModel.shared

    // Ask Fazm floating bar state
    @State private var showAskFazmBar: Bool = false

    // Selected section (passed in from parent)
    @Binding var selectedSection: SettingsSection
    @Binding var selectedAdvancedSubsection: AdvancedSubsection?
    @Binding var highlightedSettingId: String?

    // Loading states
    @State private var isLoadingSettings: Bool = false

    // Multi-chat mode setting
    @AppStorage("multiChatEnabled") private var multiChatEnabled = false
    @AppStorage("conversationsCompactView") private var conversationsCompactView = true

    // AI Chat settings
    @AppStorage("askModeEnabled") private var askModeEnabled = false
    @AppStorage("claudeMdEnabled") private var claudeMdEnabled = true
    @AppStorage("projectClaudeMdEnabled") private var projectClaudeMdEnabled = true
    @AppStorage("aiChatWorkingDirectory") private var aiChatWorkingDirectory: String = ""
    @State private var aiChatClaudeMdContent: String?
    @State private var aiChatClaudeMdPath: String?
    @State private var aiChatProjectClaudeMdContent: String?
    @State private var aiChatProjectClaudeMdPath: String?
    @State private var aiChatDiscoveredSkills: [(name: String, description: String, path: String)] = []
    @State private var aiChatProjectDiscoveredSkills: [(name: String, description: String, path: String)] = []
    @State private var aiChatDisabledSkills: Set<String> = []
    @State private var showFileViewer = false
    @State private var fileViewerContent = ""
    @State private var fileViewerTitle = ""
    @State private var skillSearchQuery = ""
    @State private var newDictionaryTerm = ""

    // Dev Mode setting
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    // Browser Extension settings
    @AppStorage("playwrightUseExtension") private var playwrightUseExtension = true
    @State private var playwrightExtensionToken: String = ""
    @State private var showBrowserSetup = false

    // Launch at login manager
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    enum SettingsSection: String, CaseIterable {
        case general = "General"
        case shortcuts = "Shortcuts"
        case dictionary = "Dictionary"
        case advanced = "Advanced"
        case about = "About"
    }

    enum AdvancedSubsection: String, CaseIterable {
        case aiChat = "AI Chat"
        case preferences = "Preferences"
        case troubleshooting = "Troubleshooting"

        var icon: String {
            switch self {
            case .aiChat: return "cpu"
            case .preferences: return "slider.horizontal.3"
            case .troubleshooting: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var showResetOnboardingAlert: Bool = false
    @State private var showRescanFilesAlert: Bool = false

    init(
        appState: AppState,
        selectedSection: Binding<SettingsSection>,
        selectedAdvancedSubsection: Binding<AdvancedSubsection?>,
        highlightedSettingId: Binding<String?> = .constant(nil),
        chatProvider: ChatProvider? = nil
    ) {
        self.appState = appState
        self._selectedSection = selectedSection
        self._selectedAdvancedSubsection = selectedAdvancedSubsection
        self._highlightedSettingId = highlightedSettingId
        self.chatProvider = chatProvider
    }

    var body: some View {
        VStack(spacing: 24) {
            // Section content
            Group {
                switch selectedSection {
                case .general:
                    generalSection
                case .shortcuts:
                    shortcutsSection
                case .dictionary:
                    dictionarySection
                case .advanced:
                    advancedSection
                case .about:
                    aboutSection
                }
            }
            .id(selectedSection)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: selectedSection)
        }
        .onAppear {
            loadBackendSettings()
            // Sync floating bar state
            showAskFazmBar = FloatingControlBarManager.shared.isVisible
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToFloatingBarSettings)) { _ in
            selectedSection = .shortcuts
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(spacing: 20) {
            // Microphone
            settingsCard(settingId: "general.microphone") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Microphone")
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            Text("Select which microphone to use for Push to Talk.")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Picker("", selection: Binding(
                            get: { audioDeviceManager.selectedDeviceUID ?? "" },
                            set: { audioDeviceManager.selectedDeviceUID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("System Default")
                                .tag("")
                            ForEach(audioDeviceManager.devices) { device in
                                Text(device.name + (device.isDefault ? " (Default)" : ""))
                                    .tag(device.uid)
                            }
                        }
                        .pickerStyle(.menu)

                        AudioLevelBarsSettingsView(level: audioDeviceManager.currentAudioLevel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(FazmColors.backgroundTertiary.opacity(0.5))
                    )
                }
            }
            .onAppear { audioDeviceManager.startLevelMonitoring() }
            .onDisappear { audioDeviceManager.stopLevelMonitoring() }

            // Font Size
            settingsCard(settingId: "general.fontsize") {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Image(systemName: "textformat.size")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Font Size")
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            Text("Scale: \(Int(fontScaleSettings.scale * 100))%")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()

                        if fontScaleSettings.scale != 1.0 {
                            Button("Reset") {
                                fontScaleSettings.resetToDefault()
                            }
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("A")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(FazmColors.textTertiary)

                        Slider(value: $fontScaleSettings.scale, in: 0.5...2.0, step: 0.05)
                            .tint(FazmColors.purplePrimary)

                        Text("A")
                            .scaledFont(size: 18, weight: .medium)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Text("The quick brown fox jumps over the lazy dog")
                        .scaledFont(size: 14)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)

                    // Keyboard shortcuts for font size
                    VStack(spacing: 6) {
                        fontShortcutRow(label: "Increase font size", keys: "\u{2318}+")
                        fontShortcutRow(label: "Decrease font size", keys: "\u{2318}\u{2212}")
                        fontShortcutRow(label: "Reset font size", keys: "\u{2318}0")
                    }
                    .padding(.top, 4)

                    HStack {
                        Spacer()
                        Button(action: {
                            resetWindowToDefaultSize()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                    .scaledFont(size: 11)
                                Text("Reset Window Size")
                                    .scaledFont(size: 12, weight: .medium)
                            }
                            .foregroundColor(FazmColors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(FazmColors.backgroundTertiary)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Background Style
            settingsCard(settingId: "general.background") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Background Style")
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundColor(FazmColors.textPrimary)

                    HStack(spacing: 10) {
                        backgroundStyleOption(
                            label: "Transparent",
                            icon: "rectangle.on.rectangle",
                            isSelected: !ShortcutSettings.shared.solidBackground
                        ) {
                            ShortcutSettings.shared.solidBackground = false
                        }

                        backgroundStyleOption(
                            label: "Solid",
                            icon: "rectangle.fill",
                            isSelected: ShortcutSettings.shared.solidBackground
                        ) {
                            ShortcutSettings.shared.solidBackground = true
                        }
                    }
                }
            }

        }
    }

    @ObservedObject private var fontScaleSettings = FontScaleSettings.shared

    // MARK: - Shortcuts Section

    private var shortcutsSection: some View {
        VStack(spacing: 20) {
            ShortcutsSettingsSection(highlightedSettingId: $highlightedSettingId)
        }
    }

    // MARK: - AI Chat Section

    @AppStorage("bridgeMode") private var bridgeMode: String = "personal"

    private var aiChatSection: some View {
        VStack(spacing: 20) {
            // Claude Account selector
            settingsCard(settingId: "aichat.account") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("Claude Account")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()
                    }

                    Picker("", selection: $bridgeMode) {
                        Text("Fazm Built-in").tag("builtin")
                        Text("Your Claude Account").tag("personal")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bridgeMode) { _, newValue in
                        Task { await chatProvider?.switchBridgeMode(to: newValue) }
                    }

                    Text(bridgeMode == "builtin"
                         ? "Using Fazm's built-in Claude account via Vertex AI. No sign-in required."
                         : "Using your personal Claude account via OAuth. Sign in to connect.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
            }

            // Ask Mode card
            settingsCard(settingId: "aichat.askmode") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("Ask Mode")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $askModeEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }

                    Text("When enabled, shows an Ask/Act toggle in the chat. Ask mode restricts the AI to read-only actions. When disabled, the AI always runs in Act mode.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)
                }
            }

            // Workspace card
            settingsCard(settingId: "aichat.workspace") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "folder")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("Workspace")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()

                        Button("Browse...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.message = "Select a project directory"
                            if panel.runModal() == .OK, let url = panel.url {
                                aiChatWorkingDirectory = url.path
                                refreshAIChatConfig()
                                // Update ChatProvider
                                chatProvider?.aiChatWorkingDirectory = url.path
                                Task { await chatProvider?.discoverClaudeConfig() }
                                if chatProvider?.workingDirectory == nil {
                                    chatProvider?.workingDirectory = url.path
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !aiChatWorkingDirectory.isEmpty {
                            Button("Clear") {
                                aiChatWorkingDirectory = ""
                                refreshAIChatConfig()
                                chatProvider?.aiChatWorkingDirectory = ""
                                Task { await chatProvider?.discoverClaudeConfig() }
                                chatProvider?.workingDirectory = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if !aiChatWorkingDirectory.isEmpty {
                        Text(aiChatWorkingDirectory)
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("Project-level CLAUDE.md and skills will be discovered from this directory")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    } else {
                        Text("No workspace set. Set a project directory to discover project-level CLAUDE.md and skills.")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                }
            }

            // CLAUDE.md card
            settingsCard(settingId: "aichat.claudemd") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("CLAUDE.md")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()
                    }

                    // Global CLAUDE.md
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Global")
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundColor(FazmColors.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(FazmColors.backgroundPrimary.opacity(0.5))
                                )

                            Spacer()

                            if aiChatClaudeMdContent != nil {
                                Button("View") {
                                    fileViewerTitle = "Global CLAUDE.md"
                                    fileViewerContent = aiChatClaudeMdContent ?? ""
                                    showFileViewer = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Toggle("", isOn: $claudeMdEnabled)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .labelsHidden()
                            }
                        }

                        if let path = aiChatClaudeMdPath, let content = aiChatClaudeMdContent {
                            let sizeKB = Double(content.utf8.count) / 1024.0
                            Text("\(path) (\(String(format: "%.1f", sizeKB)) KB)")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No CLAUDE.md found at ~/.claude/CLAUDE.md")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)
                        }
                    }

                    // Project CLAUDE.md (only show if workspace is set)
                    if !aiChatWorkingDirectory.isEmpty {
                        Divider().opacity(0.3)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Project")
                                    .scaledFont(size: 11, weight: .medium)
                                    .foregroundColor(FazmColors.purplePrimary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(FazmColors.purplePrimary.opacity(0.1))
                                    )

                                Spacer()

                                if aiChatProjectClaudeMdContent != nil {
                                    Button("View") {
                                        fileViewerTitle = "Project CLAUDE.md"
                                        fileViewerContent = aiChatProjectClaudeMdContent ?? ""
                                        showFileViewer = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: $projectClaudeMdEnabled)
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .labelsHidden()
                                }
                            }

                            if let path = aiChatProjectClaudeMdPath, let content = aiChatProjectClaudeMdContent {
                                let sizeKB = Double(content.utf8.count) / 1024.0
                                Text("\(path) (\(String(format: "%.1f", sizeKB)) KB)")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("No CLAUDE.md found at \(aiChatWorkingDirectory)/CLAUDE.md")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textTertiary)
                            }
                        }
                    }
                }
            }

            // Skills card
            settingsCard(settingId: "aichat.skills") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        if aiChatProjectDiscoveredSkills.isEmpty {
                            Text("Skills (\(aiChatDiscoveredSkills.count) discovered)")
                                .scaledFont(size: 15, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                        } else {
                            Text("Skills (\(aiChatDiscoveredSkills.count) global + \(aiChatProjectDiscoveredSkills.count) project)")
                                .scaledFont(size: 15, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                        }

                        Spacer()

                        Button(action: { refreshAIChatConfig() }) {
                            Image(systemName: "arrow.clockwise")
                                .scaledFont(size: 13)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    let allSkills: [(skill: (name: String, description: String, path: String), origin: String)] =
                        aiChatDiscoveredSkills.map { ($0, "Global") } +
                        aiChatProjectDiscoveredSkills.map { ($0, "Project") }

                    if allSkills.isEmpty {
                        Text("No skills found in ~/.claude/skills/")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    } else {
                        Text("Skill descriptions are included in the AI chat system prompt")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)

                        // Search field
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)

                            TextField("Search skills...", text: $skillSearchQuery)
                                .textFieldStyle(.plain)
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textPrimary)

                            if !skillSearchQuery.isEmpty {
                                Button(action: { skillSearchQuery = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .scaledFont(size: 12)
                                        .foregroundColor(FazmColors.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.backgroundPrimary.opacity(0.5))
                        )

                        ScrollView {
                            let filteredSkills = allSkills.enumerated().filter { _, item in
                                skillSearchQuery.isEmpty ||
                                item.skill.name.localizedCaseInsensitiveContains(skillSearchQuery) ||
                                item.skill.description.localizedCaseInsensitiveContains(skillSearchQuery)
                            }

                            VStack(spacing: 0) {
                                ForEach(Array(filteredSkills.enumerated()), id: \.offset) { filteredIndex, item in
                                    let skill = item.element.skill
                                    let origin = item.element.origin
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: { !aiChatDisabledSkills.contains(skill.name) },
                                            set: { enabled in
                                                if enabled {
                                                    aiChatDisabledSkills.remove(skill.name)
                                                } else {
                                                    aiChatDisabledSkills.insert(skill.name)
                                                }
                                                saveDisabledSkills()
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(skill.name)
                                                    .scaledFont(size: 13, weight: .medium)
                                                    .foregroundColor(FazmColors.textPrimary)

                                                Text(origin)
                                                    .scaledFont(size: 9, weight: .medium)
                                                    .foregroundColor(origin == "Project" ? FazmColors.purplePrimary : FazmColors.textTertiary)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(
                                                        RoundedRectangle(cornerRadius: 3)
                                                            .fill(origin == "Project" ? FazmColors.purplePrimary.opacity(0.1) : FazmColors.backgroundPrimary.opacity(0.5))
                                                    )
                                            }

                                            if !skill.description.isEmpty {
                                                Text(skill.description)
                                                    .scaledFont(size: 11)
                                                    .foregroundColor(FazmColors.textTertiary)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }

                                        Spacer()

                                        Button("View") {
                                            fileViewerTitle = "\(skill.name)/SKILL.md"
                                            fileViewerContent = (try? String(contentsOfFile: skill.path, encoding: .utf8)) ?? "Unable to read file"
                                            showFileViewer = true
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 4)

                                    if filteredIndex < filteredSkills.count - 1 {
                                        Divider()
                                            .opacity(0.3)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }

            // Browser Extension card
            settingsCard(settingId: "aichat.browserextension") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "globe")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("Browser Extension")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()

                        if !playwrightExtensionToken.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                Text("Connected")
                                    .scaledFont(size: 11)
                                    .foregroundColor(FazmColors.textTertiary)
                            }
                        }

                        Toggle("", isOn: $playwrightUseExtension)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .onChange(of: playwrightUseExtension) { _, _ in
                            }
                    }

                    Text("Lets the AI use your Chrome browser with all your logged-in sessions.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)

                    if playwrightUseExtension {
                        if playwrightExtensionToken.isEmpty {
                            // No token — show "Set Up" button
                            Button(action: {
                                showBrowserSetup = true
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .scaledFont(size: 12)
                                    Text("Set Up")
                                        .scaledFont(size: 13, weight: .medium)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else {
                            // Token is set — show compact view
                            HStack(spacing: 8) {
                                Text("Token")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textTertiary)

                                Text(String(playwrightExtensionToken.prefix(8)) + "...")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundColor(FazmColors.textPrimary)
                                    .font(.system(.body, design: .monospaced))

                                Spacer()

                                Button(action: {
                                    showBrowserSetup = true
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                            .scaledFont(size: 11)
                                        Text("Reconfigure")
                                            .scaledFont(size: 12)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(action: {
                                    playwrightExtensionToken = ""
                                    UserDefaults.standard.set("", forKey: "playwrightExtensionToken")
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark")
                                            .scaledFont(size: 11)
                                        Text("Reset")
                                            .scaledFont(size: 12)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            // Dev Mode card
            settingsCard(settingId: "aichat.devmode") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "hammer")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("Dev Mode")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $devModeEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .onChange(of: devModeEnabled) { _, newValue in
                                AnalyticsManager.shared.settingToggled(setting: "dev_mode", enabled: newValue)
                            }
                    }

                    Text("Let the AI modify the app's source code, rebuild it, and add custom features.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)

                    if devModeEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .scaledFont(size: 12)
                                Text("AI can modify UI, add features, create custom SQLite tables")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textSecondary)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.orange)
                                    .scaledFont(size: 12)
                                Text("Backend API, auth, and sync logic are read-only")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            refreshAIChatConfig()
            playwrightExtensionToken = UserDefaults.standard.string(forKey: "playwrightExtensionToken") ?? ""
        }
        .sheet(isPresented: $showFileViewer) {
            fileViewerSheet
        }
        .onChange(of: showBrowserSetup) { _, show in
            if show {
                showBrowserSetup = false
                BrowserExtensionSetupWindowController.shared.show(
                    chatProvider: chatProvider,
                    onComplete: {
                        playwrightExtensionToken = UserDefaults.standard.string(forKey: "playwrightExtensionToken") ?? ""
                    }
                )
            }
        }
    }

    private var fileViewerSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(fileViewerTitle)
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)

                Spacer()

                Button(action: { showFileViewer = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().opacity(0.3)

            // Content
            ScrollView {
                Text(fileViewerContent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(FazmColors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 600, height: 500)
        .background(FazmColors.backgroundSecondary)
    }

    private func refreshAIChatConfig() {
        // Pull skill and CLAUDE.md data directly from ChatProvider (already discovered at startup).
        // Fall back to reading from disk only when ChatProvider is unavailable.
        if let provider = chatProvider {
            aiChatClaudeMdContent = provider.claudeMdContent
            aiChatClaudeMdPath = provider.claudeMdPath
            aiChatDiscoveredSkills = provider.discoveredSkills
            aiChatProjectClaudeMdContent = provider.projectClaudeMdContent
            aiChatProjectClaudeMdPath = provider.projectClaudeMdPath
            aiChatProjectDiscoveredSkills = provider.projectDiscoveredSkills
            loadDisabledSkills()
            return
        }

        // Fallback: read from disk (used when Settings is shown before ChatProvider initializes)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeDir = "\(home)/.claude"

        let mdPath = "\(claudeDir)/CLAUDE.md"
        if FileManager.default.fileExists(atPath: mdPath),
           let content = try? String(contentsOfFile: mdPath, encoding: .utf8) {
            aiChatClaudeMdContent = content
            aiChatClaudeMdPath = mdPath
        } else {
            aiChatClaudeMdContent = nil
            aiChatClaudeMdPath = nil
        }

        var skills: [(name: String, description: String, path: String)] = []
        let skillsDir = "\(claudeDir)/skills"
        if let skillDirs = try? FileManager.default.contentsOfDirectory(atPath: skillsDir) {
            for dir in skillDirs.sorted() {
                let skillPath = "\(skillsDir)/\(dir)/SKILL.md"
                if FileManager.default.fileExists(atPath: skillPath),
                   let content = try? String(contentsOfFile: skillPath, encoding: .utf8) {
                    let desc = ChatProvider.extractSkillDescription(from: content)
                    skills.append((name: dir, description: desc, path: skillPath))
                }
            }
        }
        aiChatDiscoveredSkills = skills

        let workspace = aiChatWorkingDirectory
        if !workspace.isEmpty, FileManager.default.fileExists(atPath: workspace) {
            let projectMdPath = "\(workspace)/CLAUDE.md"
            if FileManager.default.fileExists(atPath: projectMdPath),
               let content = try? String(contentsOfFile: projectMdPath, encoding: .utf8) {
                aiChatProjectClaudeMdContent = content
                aiChatProjectClaudeMdPath = projectMdPath
            } else {
                aiChatProjectClaudeMdContent = nil
                aiChatProjectClaudeMdPath = nil
            }

            var projectSkills: [(name: String, description: String, path: String)] = []
            let projectSkillsDir = "\(workspace)/.claude/skills"
            if let skillDirs = try? FileManager.default.contentsOfDirectory(atPath: projectSkillsDir) {
                for dir in skillDirs.sorted() {
                    let skillPath = "\(projectSkillsDir)/\(dir)/SKILL.md"
                    if FileManager.default.fileExists(atPath: skillPath),
                       let content = try? String(contentsOfFile: skillPath, encoding: .utf8) {
                        let desc = ChatProvider.extractSkillDescription(from: content)
                        projectSkills.append((name: dir, description: desc, path: skillPath))
                    }
                }
            }
            aiChatProjectDiscoveredSkills = projectSkills
        } else {
            aiChatProjectClaudeMdContent = nil
            aiChatProjectClaudeMdPath = nil
            aiChatProjectDiscoveredSkills = []
        }

        loadDisabledSkills()
    }

    private func loadDisabledSkills() {
        let json = UserDefaults.standard.string(forKey: "disabledSkillsJSON") ?? ""
        guard let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            aiChatDisabledSkills = [] // Default: nothing disabled = all enabled
            return
        }
        aiChatDisabledSkills = Set(names)
    }

    private func saveDisabledSkills() {
        if let data = try? JSONEncoder().encode(Array(aiChatDisabledSkills)),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: "disabledSkillsJSON")
        }
    }

    // MARK: - Dictionary Section

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom words and phrases to improve transcription accuracy.")
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)

            HStack(spacing: 8) {
                TextField("Add a word or phrase…", text: $newDictionaryTerm)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 14)
                    .foregroundColor(FazmColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(FazmColors.backgroundTertiary)
                    )
                    .onSubmit {
                        addDictionaryTerm()
                    }

                Button(action: addDictionaryTerm) {
                    Text("Add")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundColor(FazmColors.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.purplePrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(newDictionaryTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !AssistantSettings.shared.transcriptionVocabulary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AssistantSettings.shared.transcriptionVocabulary, id: \.self) { term in
                        HStack {
                            Text(term)
                                .scaledFont(size: 14)
                                .foregroundColor(FazmColors.textPrimary)

                            Spacer()

                            Button {
                                AssistantSettings.shared.transcriptionVocabulary.removeAll { $0 == term }
                            } label: {
                                Image(systemName: "xmark")
                                    .scaledFont(size: 11)
                                    .foregroundColor(FazmColors.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(FazmColors.backgroundTertiary)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private func addDictionaryTerm() {
        let trimmed = newDictionaryTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !AssistantSettings.shared.transcriptionVocabulary.contains(trimmed) else {
            newDictionaryTerm = ""
            return
        }
        AssistantSettings.shared.transcriptionVocabulary.append(trimmed)
        newDictionaryTerm = ""
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        Group {
            switch selectedAdvancedSubsection {
            case .aiChat, .none:
                aiChatSection
            case .preferences:
                preferencesSubsection
            case .troubleshooting:
                troubleshootingSubsection
            }
        }
    }

    // MARK: - Advanced Subsections

    private var preferencesSubsection: some View {
        VStack(spacing: 20) {
            // Ask Fazm floating bar toggle
            settingsCard(settingId: "advanced.preferences.askomi") {
                HStack(spacing: 16) {
                    Circle()
                        .fill(showAskFazmBar ? FazmColors.success : FazmColors.textTertiary.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: showAskFazmBar ? FazmColors.success.opacity(0.5) : .clear, radius: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ask Fazm")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text(showAskFazmBar ? "Floating bar is visible (\u{2318}\\)" : "Floating bar is hidden (\u{2318}\\)")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Toggle("", isOn: $showAskFazmBar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: showAskFazmBar) { _, newValue in
                            if newValue {
                                FloatingControlBarManager.shared.show()
                            } else {
                                FloatingControlBarManager.shared.hide()
                            }
                        }
                }
            }

            // Multiple Chat Sessions toggle
            settingsCard(settingId: "advanced.preferences.multichat") {
                HStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Multiple Chat Sessions")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text(multiChatEnabled
                             ? "Create separate chat threads"
                             : "Single chat synced with mobile app")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Toggle("", isOn: $multiChatEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            // Conversation View toggle
            settingsCard(settingId: "advanced.preferences.compact") {
                HStack(spacing: 16) {
                    Image(systemName: conversationsCompactView ? "list.bullet" : "list.bullet.rectangle")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compact Conversations")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text(conversationsCompactView
                             ? "Showing compact conversation list"
                             : "Showing expanded conversation list")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Toggle("", isOn: $conversationsCompactView)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            // Launch at Login toggle
            settingsCard(settingId: "advanced.preferences.launchatlogin") {
                HStack(spacing: 16) {
                    Image(systemName: "power")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch at Login")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text(launchAtLoginManager.statusDescription)
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { newValue in
                            if launchAtLoginManager.setEnabled(newValue) {
                                AnalyticsManager.shared.launchAtLoginChanged(enabled: newValue, source: "user")
                            }
                        }
                    ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    private var troubleshootingSubsection: some View {
        VStack(spacing: 20) {
            // Report Issue
            settingsCard(settingId: "advanced.troubleshooting.reportissue") {
                HStack(spacing: 16) {
                    Image(systemName: "exclamationmark.bubble")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Report Issue")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text("Send app logs and report a problem")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Button(action: {
                        FeedbackWindow.show(userEmail: AuthState.shared.userEmail)
                    }) {
                        Text("Report")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(FazmColors.purplePrimary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Rescan Files
            settingsCard(settingId: "advanced.troubleshooting.rescanfiles") {
                HStack(spacing: 16) {
                    Image(systemName: "folder.badge.gearshape")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rescan Files")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text("Re-index your files and update your AI profile")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Button(action: { showRescanFilesAlert = true }) {
                        Text("Rescan")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(FazmColors.purplePrimary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .alert("Rescan Files?", isPresented: $showRescanFilesAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Rescan") {
                    NotificationCenter.default.post(name: .triggerFileIndexing, object: nil)
                }
            } message: {
                Text("This will re-scan your files and update your AI profile with the latest information about your projects and interests.")
            }

            // Reset Onboarding
            settingsCard(settingId: "advanced.troubleshooting.resetonboarding") {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.counterclockwise")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reset Onboarding")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Text("Restart setup wizard and reset permissions")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Button(action: { showResetOnboardingAlert = true }) {
                        Text("Reset")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.white)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .alert("Reset Onboarding?", isPresented: $showResetOnboardingAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset & Restart", role: .destructive) {
                    appState.resetOnboardingAndRestart()
                }
            } message: {
                Text("This will reset all permissions and restart the app. You'll need to grant permissions again during setup.")
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 20) {
            settingsCard(settingId: "about.version") {
                VStack(spacing: 16) {
                    // App info
                    HStack(spacing: 16) {
                        if let logoImage = NSImage(contentsOf: Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png")!) {
                            Image(nsImage: logoImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Fazm")
                                    .scaledFont(size: 18, weight: .bold)
                                    .foregroundColor(FazmColors.textPrimary)

                                if !updaterViewModel.activeChannelLabel.isEmpty {
                                    Text("(\(updaterViewModel.activeChannelLabel))")
                                        .scaledFont(size: 13, weight: .medium)
                                        .foregroundColor(FazmColors.purplePrimary)
                                }
                            }

                            Text("Version \(updaterViewModel.currentVersion) (\(updaterViewModel.buildNumber))")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                                .onTapGesture {
                                    // Hidden: Option+click to enable staging channel
                                    if NSEvent.modifierFlags.contains(.option) {
                                        // Set staging directly in UserDefaults, bypassing the
                                        // updateChannel didSet which would overwrite with "beta"
                                        UserDefaults.standard.set("staging", forKey: "update_channel")
                                        updaterViewModel.activeChannelLabel = "Staging"
                                        logSync("Settings: Staging channel enabled via hidden gesture")
                                    }
                                }
                        }

                        Spacer()
                    }

                    Divider()
                        .background(FazmColors.backgroundQuaternary)

                    // Links
                    linkRow(title: "Visit Website", url: "https://fazm.ai")
                    linkRow(title: "Help Center", url: "https://help.fazm.ai")
                    linkRow(title: "Privacy Policy", url: "https://fazm.ai/privacy")
                    linkRow(title: "Terms of Service", url: "https://fazm.ai/terms")
                }
            }

            // Software Updates
            settingsCard(settingId: "about.updates") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.purplePrimary)

                        Text("Software Updates")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()

                        Button("Check Now") {
                            updaterViewModel.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updaterViewModel.canCheckForUpdates)
                    }

                    if let lastCheck = updaterViewModel.lastUpdateCheckDate {
                        Text("Last checked: \(lastCheck, style: .relative) ago")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Divider()
                        .background(FazmColors.backgroundQuaternary)

                    settingRow(title: "Automatic Updates", subtitle: "Check for updates automatically in the background", settingId: "about.autoupdates") {
                        Toggle("", isOn: $updaterViewModel.automaticallyChecksForUpdates)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if updaterViewModel.automaticallyChecksForUpdates {
                        settingRow(title: "Auto-Install Updates", subtitle: "Automatically download and install updates when available", settingId: "about.autoinstall") {
                            Toggle("", isOn: $updaterViewModel.automaticallyDownloadsUpdates)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }

                    Divider()
                        .background(FazmColors.backgroundQuaternary)

                    settingRow(title: "Update Channel", subtitle: updaterViewModel.updateChannel.description, settingId: "about.channel") {
                        Picker("", selection: $updaterViewModel.updateChannel) {
                            ForEach(UpdateChannel.allCases, id: \.self) { channel in
                                Text(channel.displayName).tag(channel)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }
            }

            settingsCard(settingId: "about.reportissue") {
                HStack(spacing: 16) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .scaledFont(size: 16)
                        .foregroundColor(FazmColors.purplePrimary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Report an Issue")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)

                        Text("Help us improve Fazm")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textTertiary)
                    }

                    Spacer()

                    Button("Report") {
                        FeedbackWindow.show(userEmail: AuthState.shared.userEmail)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Helper Views

    private func backgroundStyleOption(label: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .scaledFont(size: 14)
                Text(label)
                    .scaledFont(size: 13, weight: .medium)
            }
            .foregroundColor(FazmColors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? FazmColors.purplePrimary.opacity(0.3)
                          : FazmColors.backgroundTertiary.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? FazmColors.purplePrimary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func fontShortcutRow(label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textTertiary)
            Spacer()
            Text(keys)
                .scaledMonospacedFont(size: 13, weight: .medium)
                .foregroundColor(FazmColors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(FazmColors.backgroundTertiary.opacity(0.8))
                .cornerRadius(5)
        }
    }

    private func settingsCard<Content: View>(settingId: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        let card = content()
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(FazmColors.backgroundTertiary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                    )
            )
        return Group {
            if let settingId = settingId {
                card.modifier(SettingHighlightModifier(settingId: settingId, highlightedSettingId: $highlightedSettingId))
            } else {
                card
            }
        }
    }

    private func settingRow<Content: View>(title: String, subtitle: String, settingId: String? = nil, @ViewBuilder control: () -> Content) -> some View {
        let row = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(size: 14)
                    .foregroundColor(FazmColors.textSecondary)
                Text(subtitle)
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }

            Spacer()

            control()
        }
        return Group {
            if let settingId = settingId {
                row.modifier(SettingHighlightModifier(settingId: settingId, highlightedSettingId: $highlightedSettingId))
            } else {
                row
            }
        }
    }

    private func linkRow(title: String, url: String) -> some View {
        Button(action: {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack {
                Text(title)
                    .scaledFont(size: 14)
                    .foregroundColor(FazmColors.textSecondary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 12)
                    .foregroundColor(FazmColors.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Backend Settings

    private func loadBackendSettings() {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true

        Task {
            do {
                // Sync assistant settings from server
                try await SettingsSyncManager.shared.syncFromServer()

                await MainActor.run {
                    isLoadingSettings = false
                }
            } catch {
                logError("Failed to load backend settings", error: error)
                await MainActor.run {
                    isLoadingSettings = false
                }
            }
        }
    }

}

#Preview {
    SettingsPage(
        appState: AppState(),
        selectedSection: .constant(.advanced),
        selectedAdvancedSubsection: .constant(.aiChat),
        highlightedSettingId: .constant(nil)
    )
}
