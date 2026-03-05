import SwiftUI

/// Settings section for keyboard shortcuts and push-to-talk configuration.
struct ShortcutsSettingsSection: View {
    @ObservedObject private var settings = ShortcutSettings.shared
    @Binding var highlightedSettingId: String?

    init(highlightedSettingId: Binding<String?> = .constant(nil)) {
        self._highlightedSettingId = highlightedSettingId
    }

    var body: some View {
        VStack(spacing: 20) {
            askFazmKeyCard
            pttKeyCard
            pttTranscriptionModeCard
            doubleTapCard
            pttSoundsCard
            referenceCard
        }
    }

    private var askFazmKeyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Fazm Shortcut")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Global shortcut to open Ask Fazm from anywhere.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.AskFazmKey.allCases, id: \.self) { key in
                    askFazmKeyButton(key)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.shortcut", highlightedSettingId: $highlightedSettingId))
    }

    private func askFazmKeyButton(_ key: ShortcutSettings.AskFazmKey) -> some View {
        let isSelected = settings.askFazmKey == key
        return Button {
            settings.askFazmKey = key
        } label: {
            Text(key.rawValue)
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

    private var pttKeyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Push to Talk")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Hold the key to speak, release to send your question to AI.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.PTTKey.allCases, id: \.self) { key in
                    pttKeyButton(key)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.ptt", highlightedSettingId: $highlightedSettingId))
    }

    private func pttKeyButton(_ key: ShortcutSettings.PTTKey) -> some View {
        let isSelected = settings.pttKey == key
        return Button {
            settings.pttKey = key
        } label: {
            HStack(spacing: 8) {
                Text(key.symbol)
                    .scaledFont(size: 16)
                Text(key.rawValue)
                    .scaledFont(size: 13, weight: .medium)
            }
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

    private var pttTranscriptionModeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Mode")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text(settings.pttTranscriptionMode.description)
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textSecondary)
            }

            HStack(spacing: 12) {
                ForEach(ShortcutSettings.PTTTranscriptionMode.allCases, id: \.self) { mode in
                    pttTranscriptionModeButton(mode)
                }
                Spacer()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.transcriptionmode", highlightedSettingId: $highlightedSettingId))
    }

    private func pttTranscriptionModeButton(_ mode: ShortcutSettings.PTTTranscriptionMode) -> some View {
        let isSelected = settings.pttTranscriptionMode == mode
        return Button {
            settings.pttTranscriptionMode = mode
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

    private var doubleTapCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Double-tap for Locked Mode")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Double-tap the push-to-talk key to keep listening hands-free. Tap again to send.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $settings.doubleTapForLock)
                .toggleStyle(.switch)
                .tint(FazmColors.purplePrimary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.doubletap", highlightedSettingId: $highlightedSettingId))
    }

    private var pttSoundsCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Push-to-Talk Sounds")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Text("Play audio feedback when starting and ending voice input.")
                    .scaledFont(size: 13)
                    .foregroundColor(FazmColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $settings.pttSoundsEnabled)
                .toggleStyle(.switch)
                .tint(FazmColors.purplePrimary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
        )
        .modifier(SettingHighlightModifier(settingId: "advanced.askomi.pttsounds", highlightedSettingId: $highlightedSettingId))
    }

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(FazmColors.textPrimary)

            shortcutRow(label: "Ask Fazm", keys: settings.askFazmKey.rawValue)
            shortcutRow(label: "Toggle floating bar", keys: "\u{2318}\\")
            shortcutRow(label: "Push to talk", keys: settings.pttKey.symbol + " hold")
            if settings.doubleTapForLock {
                shortcutRow(label: "Locked listening", keys: settings.pttKey.symbol + " \u{00D7}2")
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FazmColors.backgroundTertiary.opacity(0.5))
        )
    }

    private func shortcutRow(label: String, keys: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundColor(FazmColors.textSecondary)
            Spacer()
            Text(keys)
                .scaledMonospacedFont(size: 14, weight: .medium)
                .foregroundColor(FazmColors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(FazmColors.backgroundTertiary.opacity(0.8))
                .cornerRadius(6)
        }
    }
}
