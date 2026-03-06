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
        // General
        SettingsSearchItem(name: "Ask Fazm", subtitle: "Show or hide the floating chat bar", keywords: ["floating bar", "chat bar"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.askomi"),
        SettingsSearchItem(name: "Font Size", subtitle: "Adjust text size across the app", keywords: ["text size", "zoom", "scale", "reset"], section: .general, advancedSubsection: nil, icon: "gearshape", settingId: "general.fontsize"),
        SettingsSearchItem(name: "Reset Window Size", subtitle: "Restore the default window dimensions", keywords: ["resize", "window", "default size"], section: .general, advancedSubsection: nil, icon: "gearshape", settingId: "general.resetwindow"),

        // AI Chat (under Advanced)
        SettingsSearchItem(name: "AI Chat", subtitle: "Configure AI assistant settings", keywords: ["claude", "chat settings"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.aichat"),
        SettingsSearchItem(name: "Claude Account", subtitle: "Switch between built-in and personal Claude account", keywords: ["account", "vertex", "built-in", "oauth", "sign in"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.account"),
        SettingsSearchItem(name: "Ask Mode", subtitle: "Show an Ask/Act toggle in the chat to control tool use", keywords: ["ask", "act", "read only", "mode toggle"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.askmode"),
        SettingsSearchItem(name: "CLAUDE.md", subtitle: "Personal instructions loaded into AI chat", keywords: ["claude md", "claude config", "instructions", "view"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.claudemd"),
        SettingsSearchItem(name: "Skills", subtitle: "Enable or disable discovered AI skills", keywords: ["skills", "plugins", "abilities", "view"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.skills"),
        SettingsSearchItem(name: "Browser Extension", subtitle: "Lets the AI use your Chrome browser with all your logged-in sessions", keywords: ["playwright", "chrome", "browser extension", "browser", "set up", "reconfigure", "token"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.browserextension"),
        SettingsSearchItem(name: "Workspace", subtitle: "Set a project directory for AI chat context", keywords: ["workspace", "project", "directory", "folder", "working directory", "claude.md"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.workspace"),
        SettingsSearchItem(name: "AI Provider", subtitle: "Choose between Agent SDK and Claude Code for AI chat", keywords: ["provider", "agent sdk", "claude code", "acp", "bridge mode"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.provider"),
        SettingsSearchItem(name: "Dev Mode", subtitle: "Developer tools and debugging options", keywords: ["developer", "debug", "dev mode", "development"], section: .advanced, advancedSubsection: .aiChat, icon: "cpu", settingId: "aichat.devmode"),

        // Dictionary
        SettingsSearchItem(name: "Dictionary", subtitle: "Custom words to improve transcription accuracy", keywords: ["dictionary", "vocabulary", "transcription", "words", "phrases", "keyterm"], section: .dictionary, advancedSubsection: nil, icon: "character.book.closed", settingId: "dictionary.dictionary"),

        // About
        SettingsSearchItem(name: "Software Updates", subtitle: "Check for and manage app updates", keywords: ["update", "auto update", "sparkle", "version", "check for updates", "check now"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.updates"),
        SettingsSearchItem(name: "Automatic Updates", subtitle: "Check for updates automatically in the background", keywords: ["auto check", "background updates", "check automatically"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.autoupdates"),
        SettingsSearchItem(name: "Auto-Install Updates", subtitle: "Automatically download and install updates when available", keywords: ["auto install", "automatic install", "download updates", "install updates"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.autoinstall"),
        SettingsSearchItem(name: "Update Channel", subtitle: "Choose between beta and staging update channels", keywords: ["channel", "beta", "staging", "release channel"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.channel"),
        SettingsSearchItem(name: "Version Info", subtitle: "Current app version and build number", keywords: ["version", "build", "app version", "build number"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.version"),
        SettingsSearchItem(name: "Report an Issue", subtitle: "Help us improve Fazm", keywords: ["bug", "feedback", "report", "issue"], section: .about, advancedSubsection: nil, icon: "info.circle", settingId: "about.reportissue"),

        // Shortcuts section
        SettingsSearchItem(name: "AI Model", subtitle: "Choose the AI model for Ask Fazm conversations", keywords: ["model", "ai", "sonnet", "opus", "claude"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.aimodel"),
        SettingsSearchItem(name: "Response Style", subtitle: "Control response compactness", keywords: ["response", "style", "compact", "concise", "strict", "soft"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.responsestyle"),
        SettingsSearchItem(name: "Proactiveness", subtitle: "How proactive the AI assistant should be", keywords: ["proactive", "passive", "balanced", "autonomous", "agent"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.proactiveness"),
        SettingsSearchItem(name: "Background Style", subtitle: "Toggle between solid and transparent background", keywords: ["background", "solid", "transparent", "blur"], section: .general, advancedSubsection: nil, icon: "gearshape", settingId: "general.background"),
        SettingsSearchItem(name: "Draggable Floating Bar", subtitle: "Allow repositioning the floating bar by dragging it", keywords: ["drag", "move", "reposition", "draggable"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.draggable"),
        SettingsSearchItem(name: "Ask Fazm Shortcut", subtitle: "Global shortcut to open Ask Fazm from anywhere", keywords: ["shortcut", "hotkey", "keyboard", "global shortcut"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.shortcut"),
        SettingsSearchItem(name: "Push to Talk", subtitle: "Hold a key to speak, release to send your question to AI", keywords: ["push to talk", "ptt", "hold to talk", "microphone key"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.ptt"),
        SettingsSearchItem(name: "Transcription Mode", subtitle: "Choose how voice input is processed", keywords: ["transcription", "mode", "voice", "dictation"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.transcriptionmode"),
        SettingsSearchItem(name: "Double-tap for Locked Mode", subtitle: "Double-tap the push-to-talk key to keep listening hands-free", keywords: ["double tap", "locked mode", "hands free", "listening"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.doubletap"),
        SettingsSearchItem(name: "Push-to-Talk Sounds", subtitle: "Play audio feedback when starting and ending voice input", keywords: ["sounds", "audio feedback", "ptt sounds"], section: .shortcuts, advancedSubsection: nil, icon: "keyboard", settingId: "advanced.askfazm.pttsounds"),
        SettingsSearchItem(name: "Multiple Chat Sessions", subtitle: "Create separate chat threads", keywords: ["multi chat", "threads"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.multichat"),
        SettingsSearchItem(name: "Launch at Login", subtitle: "Start Fazm automatically when you log in", keywords: ["startup", "login", "boot"], section: .advanced, advancedSubsection: .preferences, icon: "slider.horizontal.3", settingId: "advanced.preferences.launchatlogin"),
        SettingsSearchItem(name: "Report Issue", subtitle: "Send app logs and report a problem", keywords: ["bug", "feedback", "logs", "report"], section: .advanced, advancedSubsection: .troubleshooting, icon: "wrench.and.screwdriver", settingId: "advanced.troubleshooting.reportissue"),
        SettingsSearchItem(name: "Reset Onboarding", subtitle: "Restart setup wizard and reset permissions", keywords: ["setup", "wizard", "permissions", "reset"], section: .advanced, advancedSubsection: .troubleshooting, icon: "wrench.and.screwdriver", settingId: "advanced.troubleshooting.resetonboarding"),
    ]
}

/// Settings sidebar for navigating settings sections
struct SettingsSidebar: View {
    @Binding var selectedSection: SettingsContentView.SettingsSection
    @Binding var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection?
    @Binding var highlightedSettingId: String?

    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

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
            // Settings title
            Text("Settings")
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
        }
        .frame(width: expandedWidth)
        .background(FazmColors.backgroundPrimary)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 13)
                .foregroundColor(isSearchFocused ? FazmColors.purplePrimary : FazmColors.textTertiary)
                .animation(.easeInOut(duration: 0.15), value: isSearchFocused)

            TextField("Search settings...", text: $searchQuery)
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
    let onTap: () -> Void

    @State private var isHovered = false

    private var icon: String {
        switch section {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .dictionary: return "character.book.closed"
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
        highlightedSettingId: .constant(nil)
    )
    .preferredColorScheme(.dark)
}
