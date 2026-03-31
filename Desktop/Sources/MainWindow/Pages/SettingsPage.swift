import SwiftUI
import Sparkle
import UniformTypeIdentifiers
import CoreImage

/// Settings page that wraps SettingsView with proper dark theme styling for the main window
struct SettingsPage: View {
    @ObservedObject var appState: AppState
    @Binding var selectedSection: SettingsContentView.SettingsSection
    @Binding var selectedAdvancedSubsection: SettingsContentView.AdvancedSubsection?
    @Binding var highlightedSettingId: String?
    var chatProvider: ChatProvider? = nil

    var body: some View {
        Group {
            if selectedSection == .chatWithFounder {
                // Chat page fills the entire content area (no header/scroll wrapper)
                FounderChatPage()
            } else {
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

    // AI Chat settings

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
    @State private var fileViewerLoading = false
    @State private var fileViewerPath = ""
    @State private var fileViewerEditable = false
    @State private var fileViewerSaving = false
    @State private var skillSearchQuery = ""
    @State private var newDictionaryTerm = ""

    // Dev Mode setting
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    // Voice Response (TTS) settings
    @AppStorage("voiceResponseEnabled") private var voiceResponseEnabled = true
    @AppStorage("voiceResponseSpeed") private var voiceResponseSpeed: Double = 1.0

    // Browser Extension settings
    @AppStorage("playwrightUseExtension") private var playwrightUseExtension = true
    @State private var playwrightExtensionToken: String = ""
    @State private var showBrowserSetup = false

    // Launch at login manager
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @State private var transcriptionAutoDetect: Bool = AssistantSettings.shared.transcriptionAutoDetect
    @State private var transcriptionLanguage: String = AssistantSettings.shared.transcriptionLanguage
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var shortcutSettings = ShortcutSettings.shared
    @ObservedObject private var authState = AuthState.shared
    @State private var showSignOutAlert = false

    enum SettingsSection: String, CaseIterable {
        case home = "Home"
        case chatWithFounder = "Chat with Founder"
        case discoveredTasks = "Discovered Tasks"
        case remoteControl = "Remote Control"
        case dictionary = "Dictionary"
        case shortcuts = "Shortcuts"
        case permissions = "Permissions"
        case general = "General"
        case advanced = "Advanced"
        case about = "Account"
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
    @State private var showChannelPicker: Bool = false

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
                case .home:
                    HomeSection(appState: appState)
                case .chatWithFounder:
                    FounderChatPage()
                case .discoveredTasks:
                    DiscoveredTasksSection()
                case .remoteControl:
                    remoteControlSection
                case .general:
                    generalSection
                case .shortcuts:
                    shortcutsSection
                case .permissions:
                    PermissionsPage(appState: appState)
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

    // MARK: - Remote Control Section

    private var remoteControlSection: some View {
        VStack(spacing: 20) {
            // QR Code + URL card
            settingsCard(settingId: "remotecontrol.connect") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect Your Phone")
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            Text("Control Fazm from your phone. Open the link below or scan the QR code on your mobile device.")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()
                    }

                    HStack(spacing: 20) {
                        // QR Code
                        if let qrImage = generateQRCode(from: "https://chat.fazm.ai") {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 120, height: 120)
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(FazmColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("chat.fazm.ai")
                                .scaledFont(size: 18, weight: .semibold)
                                .foregroundColor(FazmColors.purplePrimary)

                            Text("Sign in with the same Google account on your phone to connect automatically.")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(action: {
                                NSWorkspace.shared.open(URL(string: "https://chat.fazm.ai")!)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right")
                                        .scaledFont(size: 11, weight: .medium)
                                    Text("Open in Browser")
                                        .scaledFont(size: 13, weight: .medium)
                                }
                                .foregroundColor(FazmColors.purplePrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(FazmColors.purplePrimary.opacity(0.1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            // Connection status card
            settingsCard(settingId: "remotecontrol.status") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connection Status")
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)
                            Text("Current state of the phone relay connection.")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()
                    }

                    VStack(spacing: 8) {
                        // Relay status
                        HStack(spacing: 10) {
                            Circle()
                                .fill(chatProvider?.webRelay.tunnelUrl != nil ? Color.green : FazmColors.textTertiary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("Relay Server")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textSecondary)
                            Spacer()
                            Text(chatProvider?.webRelay.tunnelUrl != nil ? "Online" : "Offline")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundColor(chatProvider?.webRelay.tunnelUrl != nil ? Color.green : FazmColors.textTertiary)
                        }

                        Divider()
                            .background(FazmColors.backgroundQuaternary.opacity(0.3))

                        // Phone connection
                        HStack(spacing: 10) {
                            Circle()
                                .fill(chatProvider?.webRelay.isPhoneConnected == true ? Color.green : FazmColors.textTertiary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("Phone")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textSecondary)
                            Spacer()
                            Text(chatProvider?.webRelay.isPhoneConnected == true ? "Connected" : "Not Connected")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundColor(chatProvider?.webRelay.isPhoneConnected == true ? Color.green : FazmColors.textTertiary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(FazmColors.backgroundTertiary.opacity(0.5))
                    )
                }
            }

            // How it works card
            settingsCard(settingId: "remotecontrol.howitworks") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "questionmark.circle")
                            .scaledFont(size: 16, weight: .medium)
                            .foregroundColor(FazmColors.purplePrimary)
                            .frame(width: 12)

                        Text("How It Works")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        remoteControlStep(number: "1", text: "Open chat.fazm.ai on your phone")
                        remoteControlStep(number: "2", text: "Sign in with the same Google account")
                        remoteControlStep(number: "3", text: "Your phone connects to this computer automatically")
                        remoteControlStep(number: "4", text: "Send voice or text messages from your phone")
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func remoteControlStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .scaledFont(size: 12, weight: .bold)
                .foregroundColor(FazmColors.purplePrimary)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(FazmColors.purplePrimary.opacity(0.15))
                )
            Text(text)
                .scaledFont(size: 13)
                .foregroundColor(FazmColors.textSecondary)
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: scale)
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
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

                        if audioDeviceManager.noMicrophoneAvailable {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .scaledFont(size: 11)
                                Text("No microphone detected")
                                    .scaledFont(size: 12)
                            }
                            .foregroundColor(FazmColors.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            AudioLevelBarsSettingsView(level: audioDeviceManager.currentAudioLevel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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

            // Language Mode
            settingsCard(settingId: "general.languagemode") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "globe")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.purplePrimary)

                        Text("Language Mode")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()
                    }

                    // Auto-Detect option
                    Button(action: {
                        transcriptionAutoDetect = true
                        AssistantSettings.shared.transcriptionAutoDetect = true
                        restartTranscriptionIfNeeded()
                    }) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: transcriptionAutoDetect ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 20)
                                .foregroundColor(transcriptionAutoDetect ? FazmColors.purplePrimary : FazmColors.textTertiary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Auto-Detect (Multi-Language)")
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundColor(FazmColors.textPrimary)

                                Text("Automatically detects and transcribes:")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textTertiary)

                                Text("English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch")
                                    .scaledFont(size: 11)
                                    .foregroundColor(FazmColors.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(transcriptionAutoDetect ? FazmColors.purplePrimary.opacity(0.1) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(transcriptionAutoDetect ? FazmColors.purplePrimary.opacity(0.3) : FazmColors.backgroundQuaternary, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    // Single Language option
                    Button(action: {
                        transcriptionAutoDetect = false
                        AssistantSettings.shared.transcriptionAutoDetect = false
                        restartTranscriptionIfNeeded()
                    }) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: !transcriptionAutoDetect ? "checkmark.circle.fill" : "circle")
                                .scaledFont(size: 20)
                                .foregroundColor(!transcriptionAutoDetect ? FazmColors.purplePrimary : FazmColors.textTertiary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Single Language (Better Accuracy)")
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundColor(FazmColors.textPrimary)

                                Text("Best for speaking in one specific language")
                                    .scaledFont(size: 12)
                                    .foregroundColor(FazmColors.textTertiary)

                                if !transcriptionAutoDetect {
                                    HStack {
                                        Text("Language:")
                                            .scaledFont(size: 12)
                                            .foregroundColor(FazmColors.textTertiary)

                                        Picker("", selection: $transcriptionLanguage) {
                                            ForEach(languageOptions, id: \.0) { option in
                                                Text(option.1).tag(option.0)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 180)
                                        .onChange(of: transcriptionLanguage) { _, newValue in
                                            AssistantSettings.shared.transcriptionLanguage = newValue
                                            let supportsMulti = AssistantSettings.supportsAutoDetect(newValue)
                                            transcriptionAutoDetect = supportsMulti
                                            AssistantSettings.shared.transcriptionAutoDetect = supportsMulti
                                            restartTranscriptionIfNeeded()
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(!transcriptionAutoDetect ? FazmColors.purplePrimary.opacity(0.1) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(!transcriptionAutoDetect ? FazmColors.purplePrimary.opacity(0.3) : FazmColors.backgroundQuaternary, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.textTertiary)

                        Text("Single language mode supports 42 languages including Korean, Ukrainian, and more.")
                            .scaledFont(size: 11)
                            .foregroundColor(FazmColors.textTertiary)
                    }
                }
            }

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

            // Voice Response (TTS) card
            settingsCard(settingId: "general.voiceresponse") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.purplePrimary)

                        Text("Voice Response")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $voiceResponseEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .onChange(of: voiceResponseEnabled) { _, newValue in
                                AnalyticsManager.shared.settingToggled(setting: "voice_response", enabled: newValue)
                                Task { await chatProvider?.restartBridgeForVoiceResponse() }
                            }
                    }

                    Text("When enabled, the AI will speak its response aloud using text-to-speech. Takes effect on next message.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)

                    if voiceResponseEnabled {
                        Divider()
                            .background(FazmColors.border)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Speed")
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundColor(FazmColors.textSecondary)

                                Spacer()

                                Text(String(format: "%.1f×", voiceResponseSpeed))
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundColor(FazmColors.purplePrimary)
                                    .monospacedDigit()
                            }

                            HStack(spacing: 8) {
                                Text("0.5×")
                                    .scaledFont(size: 10)
                                    .foregroundColor(FazmColors.textTertiary)

                                Slider(value: $voiceResponseSpeed, in: 0.5...2.0, step: 0.1)
                                    .controlSize(.small)

                                Text("2.0×")
                                    .scaledFont(size: 10)
                                    .foregroundColor(FazmColors.textTertiary)
                            }
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

    @AppStorage("bridgeMode") private var bridgeMode: String = "builtin"

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
                    .disabled(chatProvider?.showCreditExhaustedAlert == true && bridgeMode == "personal")
                    .onChange(of: bridgeMode) { _, newValue in
                        Task { await chatProvider?.switchBridgeMode(to: newValue) }
                    }

                    Text(chatProvider?.showCreditExhaustedAlert == true
                         ? "Built-in credits have been used up. Connect your Claude account to continue."
                         : bridgeMode == "builtin"
                         ? "Using Fazm's built-in Claude account. No sign-in required."
                         : chatProvider?.isClaudeConnected == true
                            ? "Connected to your personal Claude account."
                            : "Using your personal Claude account via OAuth. Sign in to connect.")
                        .scaledFont(size: 12)
                        .foregroundColor(FazmColors.textTertiary)

                    if bridgeMode == "personal" && chatProvider?.isClaudeConnected == true {
                        Divider()

                        HStack {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("Connected to Claude")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textSecondary)

                            Spacer()

                            Button("Disconnect") {
                                Task {
                                    await chatProvider?.disconnectClaude()
                                }
                            }
                            .buttonStyle(.plain)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundColor(.red)
                        }
                    }
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
                                    fileViewerContent = ""
                                    fileViewerEditable = false
                                    fileViewerPath = ""
                                    fileViewerLoading = true
                                    showFileViewer = true
                                    DispatchQueue.main.async {
                                        fileViewerContent = aiChatClaudeMdContent ?? ""
                                        fileViewerLoading = false
                                    }
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
                                        fileViewerContent = ""
                                        fileViewerEditable = false
                                        fileViewerPath = ""
                                        fileViewerLoading = true
                                        showFileViewer = true
                                        DispatchQueue.main.async {
                                            fileViewerContent = aiChatProjectClaudeMdContent ?? ""
                                            fileViewerLoading = false
                                        }
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

                                        Button("Edit") {
                                            fileViewerTitle = "\(skill.name)/SKILL.md"
                                            fileViewerContent = ""
                                            fileViewerPath = skill.path
                                            fileViewerEditable = true
                                            fileViewerLoading = true
                                            showFileViewer = true
                                            let path = skill.path
                                            DispatchQueue.global(qos: .userInitiated).async {
                                                let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Unable to read file"
                                                DispatchQueue.main.async {
                                                    fileViewerContent = content
                                                    fileViewerLoading = false
                                                }
                                            }
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
                    },
                    source: "settings"
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

                if fileViewerEditable {
                    Button(action: {
                        fileViewerSaving = true
                        let content = fileViewerContent
                        let path = fileViewerPath
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try content.write(toFile: path, atomically: true, encoding: .utf8)
                                DispatchQueue.main.async {
                                    fileViewerSaving = false
                                    showFileViewer = false
                                    refreshAIChatConfig()
                                }
                            } catch {
                                DispatchQueue.main.async {
                                    fileViewerSaving = false
                                }
                            }
                        }
                    }) {
                        if fileViewerSaving {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(fileViewerSaving)
                }

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
            if fileViewerLoading {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Spacer()
            } else if fileViewerEditable {
                TextEditor(text: $fileViewerContent)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
            } else {
                ScrollView {
                    Text(fileViewerContent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(FazmColors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
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
            // Floating bar visibility toggle
            settingsCard(settingId: "advanced.preferences.askomi") {
                HStack(spacing: 16) {
                    Circle()
                        .fill(showAskFazmBar ? FazmColors.success : FazmColors.textTertiary.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: showAskFazmBar ? FazmColors.success.opacity(0.5) : .clear, radius: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Floating Bar Visibility")
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

            // AI Model
            settingsCard(settingId: "advanced.preferences.aimodel") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Model")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)
                        Text("Choose the AI model for Ask Fazm conversations.")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textSecondary)
                    }

                    HStack(spacing: 12) {
                        ForEach(ShortcutSettings.availableModels, id: \.id) { model in
                            preferencesModelButton(model)
                        }
                        Spacer()
                    }
                }
            }

            // Response Style
            settingsCard(settingId: "advanced.preferences.responsestyle") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Response Style")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)
                        Text(shortcutSettings.floatingBarCompactness.description)
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textSecondary)
                    }

                    HStack(spacing: 12) {
                        ForEach(ShortcutSettings.FloatingBarCompactness.allCases, id: \.self) { mode in
                            preferencesCompactnessButton(mode)
                        }
                        Spacer()
                    }
                }
            }

            // Proactiveness Level
            settingsCard(settingId: "advanced.preferences.proactiveness") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Proactiveness")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)
                        Text(shortcutSettings.proactivenessLevel.description)
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textSecondary)
                    }

                    HStack(spacing: 12) {
                        ForEach(ShortcutSettings.ProactivenessLevel.allCases, id: \.self) { level in
                            preferencesProactivenessButton(level)
                        }
                        Spacer()
                    }
                }
            }

            // Draggable Floating Bar
            settingsCard(settingId: "advanced.preferences.draggable") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Draggable Floating Bar")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(FazmColors.textPrimary)
                        Text("Allow repositioning the floating bar by dragging it.")
                            .scaledFont(size: 13)
                            .foregroundColor(FazmColors.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $shortcutSettings.draggableBarEnabled)
                        .toggleStyle(.switch)
                        .tint(FazmColors.purplePrimary)
                }
            }

            // Launch at Login toggle
            settingsCard(settingId: "advanced.preferences.launchatlogin") {
                VStack(spacing: 12) {
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

                    if launchAtLoginManager.lastError != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .scaledFont(size: 12)
                                .foregroundColor(.orange)

                            Text("Could not toggle automatically.")
                                .scaledFont(size: 12)
                                .foregroundColor(.orange)

                            Spacer()

                            Button("Open Login Items") {
                                launchAtLoginManager.openLoginItemsSettings()
                            }
                            .scaledFont(size: 12)
                            .foregroundColor(FazmColors.purplePrimary)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 4)
                    }
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
                Text("This will sign out, reset all permissions, disconnect browser extension, Claude account, and Google Workspace, then restart the app. You'll need to set everything up again.")
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 20) {
            // Account card
            if authState.isSignedIn {
                settingsCard(settingId: "about.account") {
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle")
                            .scaledFont(size: 16)
                            .foregroundColor(FazmColors.textSecondary)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account")
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            Text(authState.userEmail ?? "Signed in")
                                .scaledFont(size: 13)
                                .foregroundColor(FazmColors.textTertiary)
                        }

                        Spacer()

                        Button(action: { showSignOutAlert = true }) {
                            Text("Sign Out")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundColor(.red)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.red.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .alert("Sign Out?", isPresented: $showSignOutAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Sign Out", role: .destructive) {
                        AuthService.shared.signOut()
                    }
                } message: {
                    Text("You will be signed out of Fazm.")
                }
            }

            // Subscription card
            settingsCard(settingId: "about.subscription") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: SubscriptionService.shared.isActive ? "checkmark.seal.fill" : "clock.fill")
                            .scaledFont(size: 16)
                            .foregroundColor(SubscriptionService.shared.isActive ? FazmColors.success : FazmColors.purplePrimary)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(SubscriptionService.shared.isActive ? "Fazm Pro" : (SubscriptionService.shared.isTrialExpired ? "Free Plan" : "Free Trial"))
                                .scaledFont(size: 16, weight: .semibold)
                                .foregroundColor(FazmColors.textPrimary)

                            if SubscriptionService.shared.isActive {
                                if let end = SubscriptionService.shared.currentPeriodEnd {
                                    Text("Renews \(end.formatted(date: .abbreviated, time: .omitted))")
                                        .scaledFont(size: 13)
                                        .foregroundColor(FazmColors.textTertiary)
                                }
                            } else if !SubscriptionService.shared.isTrialExpired {
                                let daysLeft = max(0, SubscriptionService.shared.trialDays - (Calendar.current.dateComponents([.day], from: SubscriptionService.shared.trialStartDate, to: Date()).day ?? 0))
                                Text("\(daysLeft) days remaining in free trial")
                                    .scaledFont(size: 13)
                                    .foregroundColor(FazmColors.textTertiary)
                            } else {
                                Text("\(SubscriptionService.shared.freeMessagesPerDay) free messages per day")
                                    .scaledFont(size: 13)
                                    .foregroundColor(FazmColors.textTertiary)
                            }
                        }

                        Spacer()

                        if !SubscriptionService.shared.isActive {
                            Button(action: {
                                AnalyticsManager.shared.subscriptionUpgradeTapped(source: "settings")
                                Task { try? await SubscriptionService.shared.openCheckout() }
                            }) {
                                Text("Upgrade")
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(FazmColors.purplePrimary)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            settingsCard(settingId: "about.version") {
                VStack(spacing: 16) {
                    // App info
                    HStack(spacing: 16) {
                        if let logoImage = NSImage(contentsOf: Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png")!) {
                            Image(nsImage: logoImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 32, height: 32)
                                .padding(8)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                                .onTapGesture(count: 3) {
                                    // Triple-click to show channel picker popover
                                    showChannelPicker = true
                                    logSync("Settings: Channel picker opened via triple-click")
                                }
                                .popover(isPresented: $showChannelPicker, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Update Channel")
                                            .font(.headline)
                                            .padding(.bottom, 4)
                                        ForEach(UpdateChannel.allCases, id: \.self) { channel in
                                            Button(action: {
                                                updaterViewModel.updateChannel = channel
                                                showChannelPicker = false
                                                logSync("Settings: Channel set to \(channel.rawValue) via popover")
                                            }) {
                                                HStack {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(channel.displayName)
                                                            .font(.system(size: 13, weight: .medium))
                                                        Text(channel.description)
                                                            .font(.system(size: 11))
                                                            .foregroundColor(.secondary)
                                                    }
                                                    Spacer()
                                                    if updaterViewModel.updateChannel == channel {
                                                        Image(systemName: "checkmark")
                                                            .foregroundColor(FazmColors.purplePrimary)
                                                    }
                                                }
                                                .padding(.vertical, 4)
                                                .padding(.horizontal, 8)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(12)
                                    .frame(width: 220)
                                }
                        }

                        Spacer()
                    }

                    Divider()
                        .background(FazmColors.backgroundQuaternary)

                    // Links
                    linkRow(title: "Visit Website", url: "https://fazm.ai")
                    linkRow(title: "Watch Tutorials", url: "https://fazm.ai#use-cases")
                    linkRow(title: "Safety & Trust", url: "https://fazm.ai/safety")
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

                    if UserDefaults.standard.bool(forKey: "hasSeenAppManagementError") {
                        Divider()
                            .background(FazmColors.backgroundQuaternary)

                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 12))

                            Text("Auto-updates require App Management permission.")
                                .scaledFont(size: 12)
                                .foregroundColor(FazmColors.textTertiary)

                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                        }
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

    // MARK: - Preferences Button Helpers

    private func preferencesModelButton(_ model: (id: String, label: String)) -> some View {
        let isSelected = shortcutSettings.selectedModel == model.id
        return Button {
            shortcutSettings.selectedModel = model.id
        } label: {
            Text(model.label)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(FazmColors.textPrimary)
                .padding(.horizontal, 14)
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

    private func preferencesCompactnessButton(_ mode: ShortcutSettings.FloatingBarCompactness) -> some View {
        let isSelected = shortcutSettings.floatingBarCompactness == mode
        return Button {
            shortcutSettings.floatingBarCompactness = mode
        } label: {
            Text(mode.rawValue)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(FazmColors.textPrimary)
                .padding(.horizontal, 14)
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

    private func preferencesProactivenessButton(_ level: ShortcutSettings.ProactivenessLevel) -> some View {
        let isSelected = shortcutSettings.proactivenessLevel == level
        return Button {
            shortcutSettings.proactivenessLevel = level
        } label: {
            Text(level.rawValue)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(FazmColors.textPrimary)
                .padding(.horizontal, 14)
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
            let eventName = title.lowercased().replacingOccurrences(of: " ", with: "_") + "_clicked"
            PostHogManager.shared.track(eventName, properties: ["source": "settings", "url": url])
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
            await SettingsSyncManager.shared.syncFromServer()

            await MainActor.run {
                isLoadingSettings = false
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
