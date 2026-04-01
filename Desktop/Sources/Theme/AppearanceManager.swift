import SwiftUI
import Combine

/// User-selectable appearance mode
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The NSAppearance to apply, or nil to follow system
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// The NSAppearance for vibrant windows (floating bar, overlays)
    var vibrantAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .vibrantLight)
        case .dark: return NSAppearance(named: .vibrantDark)
        }
    }
}

/// Manages the app-wide appearance preference
@MainActor
final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    @AppStorage("appearanceMode") var mode: String = AppearanceMode.dark.rawValue {
        didSet { applyAppearance() }
    }

    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: mode) ?? .dark }
        set { mode = newValue.rawValue }
    }

    private init() {
        applyAppearance()
    }

    func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }
}
