import Carbon
import Cocoa

/// Persistent settings for keyboard shortcuts.
@MainActor
class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    /// Notification posted when the Ask Fazm shortcut changes so hotkeys can be re-registered.
    nonisolated static let askFazmShortcutChanged = Notification.Name("ShortcutSettings.askFazmShortcutChanged")

    /// Available modifier keys for push-to-talk.
    enum PTTKey: String, CaseIterable {
        case option = "Option (⌥)"
        case rightCommand = "Right Command (⌘)"
        case fn = "Fn / Globe"

        var symbol: String {
            switch self {
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

    @Published var pttKey: PTTKey {
        didSet { UserDefaults.standard.set(pttKey.rawValue, forKey: "shortcut_pttKey") }
    }

    @Published var askFazmKey: AskFazmKey {
        didSet {
            UserDefaults.standard.set(askFazmKey.rawValue, forKey: "shortcut_askFazmKey")
            NotificationCenter.default.post(name: Self.askFazmShortcutChanged, object: nil)
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

    /// Available models for Ask Fazm.
    static let availableModels: [(id: String, label: String)] = [
        ("claude-opus-4-6", "Opus"),
        ("claude-sonnet-4-6", "Sonnet"),
    ]

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

    /// When true, the floating bar can be repositioned by dragging. Off by default.
    @Published var draggableBarEnabled: Bool {
        didSet { UserDefaults.standard.set(draggableBarEnabled, forKey: "shortcut_draggableBarEnabled") }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "shortcut_pttKey"),
           let key = PTTKey(rawValue: saved) {
            self.pttKey = key
        } else {
            self.pttKey = .rightCommand
        }
        if let saved = UserDefaults.standard.string(forKey: "shortcut_askFazmKey"),
           let key = AskFazmKey(rawValue: saved) {
            self.askFazmKey = key
        } else {
            self.askFazmKey = .cmdJ
        }
        self.doubleTapForLock = UserDefaults.standard.object(forKey: "shortcut_doubleTapForLock") as? Bool ?? true
        self.solidBackground = UserDefaults.standard.object(forKey: "shortcut_solidBackground") as? Bool ?? false
        self.pttSoundsEnabled = UserDefaults.standard.object(forKey: "shortcut_pttSoundsEnabled") as? Bool ?? true
        self.selectedModel = UserDefaults.standard.string(forKey: "shortcut_selectedModel") ?? "claude-opus-4-6"
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
        self.draggableBarEnabled = UserDefaults.standard.object(forKey: "shortcut_draggableBarEnabled") as? Bool ?? false
    }
}
