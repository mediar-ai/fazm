import Carbon
import Cocoa

/// Persistent settings for keyboard shortcuts.
@MainActor
class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    /// Notification posted when the Ask Fazm shortcut changes so hotkeys can be re-registered.
    nonisolated static let askFazmShortcutChanged = Notification.Name("ShortcutSettings.askFazmShortcutChanged")

    /// Notification posted when the New Pop-Out Chat shortcut changes so hotkeys can be re-registered.
    nonisolated static let newPopOutChatShortcutChanged = Notification.Name("ShortcutSettings.newPopOutChatShortcutChanged")

    /// Available modifier keys for push-to-talk.
    enum PTTKey: String, CaseIterable {
        case leftControl = "Left Control (⌃)"
        case leftCommand = "Left Command (⌘)"
        case option = "Option (⌥)"
        case rightCommand = "Right Command (⌘)"
        case fn = "Fn / Globe"

        var symbol: String {
            switch self {
            case .leftControl: return "\u{2303}"
            case .leftCommand: return "\u{2318}"
            case .option: return "\u{2325}"
            case .rightCommand: return "Right \u{2318}"
            case .fn: return "\u{1F310}"
            }
        }
    }

    /// Available shortcut presets for Ask Fazm.
    enum AskFazmKey: String, CaseIterable {
        case cmdEnter = "⌘ Enter"
        case cmdShiftEnter = "⌘⇧ Enter"
        case cmdJ = "⌘J"
        case cmdO = "⌘O"

        /// Display symbols for the floating bar hint.
        var hintKeys: [String] {
            switch self {
            case .cmdEnter: return ["\u{2318}", "\u{21A9}\u{FE0E}"]
            case .cmdShiftEnter: return ["\u{2318}", "\u{21E7}", "\u{21A9}\u{FE0E}"]
            case .cmdJ: return ["\u{2318}", "J"]
            case .cmdO: return ["\u{2318}", "O"]
            }
        }

        /// macOS virtual key code for this shortcut.
        var keyCode: UInt16 {
            switch self {
            case .cmdEnter, .cmdShiftEnter: return 36  // Return
            case .cmdJ: return 38  // J
            case .cmdO: return 31  // O
            }
        }

        /// Required modifier flags for matching NSEvent.
        var modifierFlags: NSEvent.ModifierFlags {
            switch self {
            case .cmdEnter: return .command
            case .cmdShiftEnter: return [.command, .shift]
            case .cmdJ: return .command
            case .cmdO: return .command
            }
        }

        /// Carbon modifier flags for RegisterEventHotKey.
        var carbonModifiers: Int {
            switch self {
            case .cmdEnter: return Int(cmdKey)
            case .cmdShiftEnter: return Int(cmdKey) | Int(shiftKey)
            case .cmdJ: return Int(cmdKey)
            case .cmdO: return Int(cmdKey)
            }
        }

        /// Check whether an NSEvent matches this shortcut.
        func matches(_ event: NSEvent) -> Bool {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return mods == modifierFlags && event.keyCode == keyCode
        }
    }

    /// Available shortcut presets for New Pop-Out Chat.
    enum NewPopOutChatKey: String, CaseIterable {
        case cmdShiftN = "⌘⇧N"
        case cmdShiftO = "⌘⇧O"
        case cmdShiftP = "⌘⇧P"

        var keyCode: UInt16 {
            switch self {
            case .cmdShiftN: return 45  // N
            case .cmdShiftO: return 31  // O
            case .cmdShiftP: return 35  // P
            }
        }

        var carbonModifiers: Int {
            Int(cmdKey) | Int(shiftKey)
        }
    }

    @Published var pttKey: PTTKey {
        didSet { UserDefaults.standard.set(pttKey.rawValue, forKey: "shortcut_pttKey") }
    }

    @Published var askFazmKey: AskFazmKey {
        didSet {
            UserDefaults.standard.set(askFazmKey.rawValue, forKey: "shortcut_askFazmKey")
            NotificationCenter.default.post(name: Self.askFazmShortcutChanged, object: nil)
        }
    }

    @Published var newPopOutChatKey: NewPopOutChatKey {
        didSet {
            UserDefaults.standard.set(newPopOutChatKey.rawValue, forKey: "shortcut_newPopOutChatKey")
            NotificationCenter.default.post(name: Self.newPopOutChatShortcutChanged, object: nil)
        }
    }

    @Published var doubleTapForLock: Bool {
        didSet { UserDefaults.standard.set(doubleTapForLock, forKey: "shortcut_doubleTapForLock") }
    }

    /// When true, the floating bar uses a solid dark background instead of semi-transparent blur.
    @Published var solidBackground: Bool {
        didSet { UserDefaults.standard.set(solidBackground, forKey: "shortcut_solidBackground") }
    }

    /// When true, push-to-talk plays start/end sounds.
    @Published var pttSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(pttSoundsEnabled, forKey: "shortcut_pttSoundsEnabled") }
    }

    /// Selected AI model for Ask Fazm.
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "shortcut_selectedModel") }
    }

    /// Model option for Ask Fazm.
    struct ModelOption: Identifiable, Equatable {
        let id: String
        let label: String
        let shortLabel: String
    }

    /// Default models used as fallback until ACP reports the dynamic list.
    static let defaultModels: [ModelOption] = [
        ModelOption(id: "haiku", label: "Scary (Haiku, latest)", shortLabel: "Scary"),
        ModelOption(id: "sonnet", label: "Fast (Sonnet, latest)", shortLabel: "Fast"),
        ModelOption(id: "default", label: "Smart (Opus, latest)", shortLabel: "Smart"),
    ]

    /// Mapping from model family substring to user-friendly labels and ordering.
    /// Order determines display order in the UI (lowest first).
    private static let modelFamilyMap: [(substring: String, short: String, family: String, order: Int)] = [
        ("haiku", "Scary", "Haiku", 0),
        ("sonnet", "Fast", "Sonnet", 1),
        ("opus", "Smart", "Opus", 2),
        ("default", "Smart", "Opus", 2),
    ]

    /// Available models for Ask Fazm. Updated dynamically from ACP SDK; falls back to defaults.
    /// This is the MERGED list of Claude + Codex (Phase 3.4). Use the
    /// `updateModels` (Claude) and `updateCodexModels` (Codex) helpers — do not
    /// assign directly so the two backends don't overwrite each other.
    @Published var availableModels: [ModelOption] = ShortcutSettings.defaultModels

    /// Last Claude models reported by ACP. Source of truth for the Claude half
    /// of `availableModels`. Defaults to the static fallback.
    private var lastClaudeModels: [ModelOption] = ShortcutSettings.defaultModels
    /// Last Codex models reported via `codex_probe_result`. Empty until the
    /// CodexBackendManager probe succeeds.
    private var lastCodexModels: [ModelOption] = []

    /// Normalize a model ID: maps legacy full IDs to short aliases that the ACP SDK expects.
    static func normalizeModelId(_ modelId: String) -> String {
        // Map legacy full IDs to short aliases
        if modelId.contains("haiku") { return "haiku" }
        if modelId.contains("sonnet") { return "sonnet" }
        // ACP SDK v0.29+ uses "default" for Opus 4.7; migrate stored "opus" to match.
        if modelId.contains("opus") { return "default" }
        return modelId
    }

    /// Update the Claude half of the model list from the ACP SDK response.
    func updateModels(_ acpModels: [(modelId: String, name: String, description: String?)]) {
        guard !acpModels.isEmpty else { return }
        let newModels = acpModels.compactMap { model -> (ModelOption, Int)? in
            let modelId = model.modelId
            // Try to match a known model family
            if let match = Self.modelFamilyMap.first(where: { modelId.contains($0.substring) }) {
                // Surface bracket annotations (e.g. "[1m]" in "sonnet[1m]") so variants are distinguishable
                let bracketSuffix: String
                if let range = modelId.range(of: #"\[[^\]]+\]"#, options: .regularExpression) {
                    bracketSuffix = " " + String(modelId[range])
                } else {
                    bracketSuffix = ""
                }
                let label = "\(match.short) (\(match.family)\(bracketSuffix), latest)"
                return (ModelOption(id: modelId, label: label, shortLabel: match.short), match.order)
            }
            // Unknown model family: use the API name directly
            let displayName = model.name.isEmpty ? modelId : model.name
            return (ModelOption(id: modelId, label: displayName, shortLabel: displayName), 99)
        }
        .sorted(by: { $0.1 < $1.1 })
        .map { $0.0 }

        lastClaudeModels = newModels
        recomputeAvailableModels()
    }

    /// Phase 3.4 — update the Codex half of the model list. Called when the
    /// `codex_probe_result` message arrives. Pass an empty array to clear the
    /// Codex models (e.g. when the user disables the backend).
    func updateCodexModels(_ codexModels: [CodexBackendManager.CodexModel]) {
        lastCodexModels = codexModels.map { m in
            // Use the adapter's display name verbatim (e.g. "GPT-5.5 (high)").
            // shortLabel mirrors the Claude path: a single word the picker chip
            // can render. Codex names already include the variant in parens, so
            // strip the suffix for shortLabel.
            let short = m.name.split(separator: " ").first.map(String.init) ?? m.name
            return ModelOption(id: m.modelId, label: m.name, shortLabel: short)
        }
        recomputeAvailableModels()
    }

    private func recomputeAvailableModels() {
        let merged = lastClaudeModels + lastCodexModels
        guard merged != availableModels else { return }
        availableModels = merged
        let modelDesc = merged.map { "\($0.id) = \($0.label)" }.joined(separator: ", ")
        log("ShortcutSettings: updated availableModels to [\(modelDesc)]")

        // If the current selection vanished, try to migrate it within the same
        // backend (Claude alias normalization or longest-prefix match).
        guard !merged.contains(where: { $0.id == selectedModel }) else { return }
        let normalizedSelection = Self.normalizeModelId(selectedModel)
        if merged.contains(where: { $0.id == normalizedSelection }) {
            selectedModel = normalizedSelection
            log("ShortcutSettings: normalized selectedModel to \(normalizedSelection)")
        } else if selectedModel.hasPrefix("gpt-"),
                  let preferred = Self.preferredGptModel(in: merged, sameEffortAs: selectedModel) {
            // GPT model was filtered out (e.g. gpt-5.4/high after upgrading to 5.5).
            // Pick the same effort tier within the new generation, falling back
            // to the first GPT model if no effort match.
            selectedModel = preferred
            log("ShortcutSettings: upgraded GPT selectedModel \(normalizedSelection) -> \(preferred)")
        } else if let upgraded = merged.first(where: { $0.id.contains(normalizedSelection) }) {
            selectedModel = upgraded.id
            log("ShortcutSettings: upgraded selectedModel \(normalizedSelection) -> \(upgraded.id)")
        } else {
            log("ShortcutSettings: current selectedModel \(selectedModel) not in new model list")
        }
    }

    /// When a user's GPT selection (e.g. gpt-5.4/high) gets filtered out, find
    /// the best replacement among `merged`: prefer the same effort tier on the
    /// newest available generation; otherwise fall back to the first GPT model.
    private static func preferredGptModel(in merged: [ModelOption], sameEffortAs oldId: String) -> String? {
        let effort = oldId.split(separator: "/").last.map(String.init) ?? "high"
        // Match base family (no variants like -mini, -codex) at requested effort first.
        let plainSameEffort = merged.first { opt in
            guard opt.id.hasPrefix("gpt-") else { return false }
            let parts = opt.id.split(separator: "/")
            guard parts.count == 2, parts[1] == effort else { return false }
            // Plain family = "gpt-X.Y" with no extra dashes after the version.
            let family = String(parts[0])
            let dashCount = family.filter { $0 == "-" }.count
            return dashCount == 1
        }
        if let plain = plainSameEffort { return plain.id }
        // Then any GPT at the requested effort.
        if let anySameEffort = merged.first(where: { $0.id.hasPrefix("gpt-") && $0.id.hasSuffix("/\(effort)") }) {
            return anySameEffort.id
        }
        // Last resort: first GPT model in the list.
        return merged.first(where: { $0.id.hasPrefix("gpt-") })?.id
    }

    /// Human-readable short label for an arbitrary model id, falling through
    /// `availableModels` → `defaultModels` → normalized-alias → `defaultModels`.
    /// Use this everywhere instead of a local `?? "Smart"` so the label stays
    /// correct when ACP reports a partial model list (e.g. Sonnet rate-limited).
    func shortLabel(for modelId: String) -> String? {
        if let m = availableModels.first(where: { $0.id == modelId }) { return m.shortLabel }
        if let m = Self.defaultModels.first(where: { $0.id == modelId }) { return m.shortLabel }
        let normalized = Self.normalizeModelId(modelId)
        if normalized != modelId,
           let m = Self.defaultModels.first(where: { $0.id == normalized }) { return m.shortLabel }
        return nil
    }

    /// Human-readable short label for the currently selected model.
    var selectedModelShortLabel: String {
        shortLabel(for: selectedModel) ?? "Fast"
    }

    /// Proactiveness level for the AI assistant.
    enum ProactivenessLevel: String, CaseIterable {
        case passive = "Passive"
        case balanced = "Balanced"
        case proactive = "Proactive"

        var description: String {
            switch self {
            case .passive: return "No proactiveness instructions — default AI behavior"
            case .balanced: return "Take obvious actions, ask for confirmation on ambiguous ones"
            case .proactive: return "Proactively find and execute solutions without asking unless clarification is needed"
            }
        }
    }

    /// Floating bar response compactness level.
    enum FloatingBarCompactness: String, CaseIterable {
        case off = "Off"
        case soft = "Soft"
        case strict = "Strict"

        var description: String {
            switch self {
            case .off: return "No compactness enforcement"
            case .soft: return "Prefer short answers (1-3 sentences)"
            case .strict: return "Exactly 1 sentence, no lists or headers"
            }
        }
    }

    /// Push-to-talk transcription mode.
    enum PTTTranscriptionMode: String, CaseIterable {
        case live = "Live"
        case batch = "Batch"

        var description: String {
            switch self {
            case .live: return "Real-time transcription as you speak"
            case .batch: return "Transcribe after recording for better accuracy"
            }
        }
    }

    @Published var floatingBarCompactness: FloatingBarCompactness {
        didSet { UserDefaults.standard.set(floatingBarCompactness.rawValue, forKey: "shortcut_floatingBarCompactness") }
    }

    @Published var pttTranscriptionMode: PTTTranscriptionMode {
        didSet { UserDefaults.standard.set(pttTranscriptionMode.rawValue, forKey: "shortcut_pttTranscriptionMode") }
    }

    /// When true, the floating bar can be repositioned by dragging. On by default.
    @Published var draggableBarEnabled: Bool {
        didSet { UserDefaults.standard.set(draggableBarEnabled, forKey: "shortcut_draggableBarEnabled") }
    }


    /// How proactive the AI assistant should be.
    @Published var proactivenessLevel: ProactivenessLevel {
        didSet { UserDefaults.standard.set(proactivenessLevel.rawValue, forKey: "shortcut_proactivenessLevel") }
    }

    /// Whether the screen observer (discovered tasks) is enabled.
    @Published var screenObserverEnabled: Bool {
        didSet { UserDefaults.standard.set(screenObserverEnabled, forKey: "shortcut_screenObserverEnabled") }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "shortcut_pttKey"),
           let key = PTTKey(rawValue: saved) {
            self.pttKey = key
        } else {
            self.pttKey = .leftControl
        }
        if let saved = UserDefaults.standard.string(forKey: "shortcut_askFazmKey"),
           let key = AskFazmKey(rawValue: saved) {
            self.askFazmKey = key
        } else {
            self.askFazmKey = .cmdJ
        }
        if let saved = UserDefaults.standard.string(forKey: "shortcut_newPopOutChatKey"),
           let key = NewPopOutChatKey(rawValue: saved) {
            self.newPopOutChatKey = key
        } else {
            self.newPopOutChatKey = .cmdShiftN
        }
        self.doubleTapForLock = UserDefaults.standard.object(forKey: "shortcut_doubleTapForLock") as? Bool ?? true
        self.solidBackground = UserDefaults.standard.object(forKey: "shortcut_solidBackground") as? Bool ?? false
        self.pttSoundsEnabled = UserDefaults.standard.object(forKey: "shortcut_pttSoundsEnabled") as? Bool ?? true
        // Migrate saved model IDs: old full IDs -> short aliases; "opus" -> "default" (ACP SDK v0.29+).
        let savedModel = UserDefaults.standard.string(forKey: "shortcut_selectedModel")
        if let saved = savedModel {
            // Normalize legacy full IDs to short aliases
            let normalized = Self.normalizeModelId(saved)
            self.selectedModel = normalized
            if normalized != saved {
                UserDefaults.standard.set(normalized, forKey: "shortcut_selectedModel")
            }
        } else {
            self.selectedModel = "sonnet"
        }
        if let saved = UserDefaults.standard.string(forKey: "shortcut_floatingBarCompactness"),
           let mode = FloatingBarCompactness(rawValue: saved) {
            self.floatingBarCompactness = mode
        } else {
            self.floatingBarCompactness = .off
        }
        if let saved = UserDefaults.standard.string(forKey: "shortcut_pttTranscriptionMode"),
           let mode = PTTTranscriptionMode(rawValue: saved) {
            self.pttTranscriptionMode = mode
        } else {
            self.pttTranscriptionMode = .batch
        }
        self.draggableBarEnabled = UserDefaults.standard.object(forKey: "shortcut_draggableBarEnabled") as? Bool ?? true
        if let saved = UserDefaults.standard.string(forKey: "shortcut_proactivenessLevel"),
           let level = ProactivenessLevel(rawValue: saved) {
            self.proactivenessLevel = level
        } else {
            self.proactivenessLevel = .proactive
        }
        self.screenObserverEnabled = UserDefaults.standard.object(forKey: "shortcut_screenObserverEnabled") as? Bool ?? true
    }
}
