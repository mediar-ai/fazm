import SwiftUI
import AppKit

/// Premium color system with adaptive light/dark support
enum FazmColors {
    // MARK: - Adaptive Color Helper

    /// Creates a Color that automatically adapts to the current appearance
    private static func adaptive(dark: UInt, light: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }

    // MARK: - Background Colors
    static let backgroundPrimary = adaptive(dark: 0x0F0F0F, light: 0xFFFFFF)
    static let backgroundSecondary = adaptive(dark: 0x1A1A1A, light: 0xF5F5F5)
    static let backgroundTertiary = adaptive(dark: 0x252525, light: 0xEBEBEB)
    static let backgroundQuaternary = adaptive(dark: 0x2A2A2A, light: 0xE0E0E0)

    // MARK: - Border Colors
    static let border = adaptive(dark: 0x333333, light: 0xD4D4D4)

    // MARK: - Purple Accent System
    static let purplePrimary = Color(hex: 0x8B5CF6)
    static let purpleSecondary = Color(hex: 0xA855F7)
    static let purpleAccent = Color(hex: 0x7C3AED)
    static let purpleLight = Color(hex: 0xD946EF)

    // MARK: - Text Colors
    static let textPrimary = adaptive(dark: 0xFFFFFF, light: 0x111111)
    static let textSecondary = adaptive(dark: 0xE5E5E5, light: 0x333333)
    static let textTertiary = adaptive(dark: 0xB0B0B0, light: 0x666666)
    static let textQuaternary = adaptive(dark: 0x888888, light: 0x999999)

    // MARK: - Status Colors
    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let error = Color(hex: 0xEF4444)
    static let info = Color(hex: 0x3B82F6)
    static let amber = Color(hex: 0xF59E0B)

    // MARK: - Mac Window Button Colors
    static let windowButtonClose = Color(hex: 0xFF5F57)
    static let windowButtonMinimize = Color(hex: 0xFFBD2E)
    static let windowButtonMaximize = Color(hex: 0x28CA42)

    // MARK: - Speaker Colors (for transcript bubbles)
    static var speakerColors: [Color] {
        [
            adaptive(dark: 0x2D3748, light: 0xE2E8F0),
            adaptive(dark: 0x1E3A5F, light: 0xDBEAFE),
            adaptive(dark: 0x2D4A3E, light: 0xD1FAE5),
            adaptive(dark: 0x4A3728, light: 0xFDE68A),
            adaptive(dark: 0x3D2E4A, light: 0xEDE9FE),
            adaptive(dark: 0x4A3A2D, light: 0xFED7AA),
        ]
    }

    /// User bubble color (purple tinted)
    static let userBubble = purplePrimary.opacity(0.3)

    // MARK: - Gradients
    static let purpleGradient = LinearGradient(
        colors: [purplePrimary, purpleAccent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let purpleLightGradient = LinearGradient(
        colors: [purpleSecondary, purpleLight],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Code Block Background
    static let codeBlockBackground = adaptive(dark: 0x282C34, light: 0xF6F8FA)

    // MARK: - Overlay Colors (for floating bar, translucent panels)
    /// Use instead of Color.white.opacity(...) for overlay foregrounds
    static let overlayForeground = adaptive(dark: 0xFFFFFF, light: 0x000000)
    /// Use instead of Color.black.opacity(...) for overlay strokes/borders
    static let overlayBorder = adaptive(dark: 0x000000, light: 0x888888)
}

// MARK: - Color Extension for Hex
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }

    /// Initialize from a hex string like "#6B7280" or "6B7280"
    init?(hex hexString: String) {
        var cleanedString = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedString = cleanedString.replacingOccurrences(of: "#", with: "")

        guard cleanedString.count == 6,
              let hexValue = UInt(cleanedString, radix: 16) else {
            return nil
        }

        self.init(hex: hexValue)
    }
}
