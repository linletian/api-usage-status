import SwiftUI

// MARK: - Theme Colors
//
// Semantic color tokens for the app. Each color is defined with light and dark
// variants and resolves automatically based on the current color scheme via the
// `Color.init(_ colorScheme:)` initializer below.
//
// Usage:
//     Text("Hello").foregroundStyle(.textPrimary)
//     RoundedRectangle(cornerRadius: 8).fill(.cardBg)

extension Color {
    /// Convenience initializer that returns the light or dark variant of a hex color.
    /// Marked `@MainActor`-free so it is safe to call from any context.
    init(light: UInt32, dark: UInt32) {
        #if canImport(AppKit)
        let lightNS = NSColor(srgbHex: light)
        let darkNS = NSColor(srgbHex: dark)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
                ? darkNS
                : lightNS
        })
        #else
        // Fallback for non-AppKit platforms (e.g. iOS) — pick a static color.
        self.init(white: 0.5, opacity: 1.0)
        #endif
    }
}

#if canImport(AppKit)
private extension NSColor {
    /// Builds an NSColor from a 0xRRGGBB hex value (no alpha channel).
    convenience init(srgbHex hex: UInt32) {
        let r = CGFloat((hex & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((hex & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(hex & 0x0000FF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
#endif

extension Color {
    // MARK: Surface

    /// Background of the side bar (e.g. instance list).
    static let sidebarBg = Color(light: 0xF0F0F0, dark: 0x1C1C1E)

    /// Background of the selected row in the side bar.
    static let sidebarSelectedBg = Color(light: 0xD1D1D1, dark: 0x3A3A3C)

    /// Background of an elevated card surface.
    static let cardBg = Color(light: 0xFFFFFF, dark: 0x2C2C2E)

    /// Border line of an elevated card surface.
    static let cardBorder = Color(light: 0xE0E0E0, dark: 0x3A3A3C)

    // MARK: Text

    /// Primary text — used for headings, body copy and primary content.
    static let textPrimary = Color(light: 0x1A1A1A, dark: 0xFFFFFF)

    /// Secondary text — used for descriptions, captions, supporting copy.
    static let textSecondary = Color(light: 0x666666, dark: 0xAEAEB2)

    /// Tertiary text — used for placeholders, disabled labels, hints.
    static let textTertiary = Color(light: 0x999999, dark: 0x636366)

    // MARK: Status

    /// Indication that a tracker / switch is enabled and active.
    static let trackingOn = Color(light: 0x34C759, dark: 0x30D158)

    /// Indication that a tracker / switch is disabled or inactive.
    static let trackingOff = Color(light: 0xCCCCCC, dark: 0x48484A)

    // MARK: Accent / Semantic

    /// App accent — interactive controls, links, focus rings.
    static let accentBlue = Color(light: 0x007AFF, dark: 0x0A84FF)

    /// Danger — destructive actions, error states, failed refresh.
    static let dangerRed = Color(light: 0xFF3B30, dark: 0xFF453A)

    /// Warning — approaching a limit, soft attention.
    static let warningYellow = Color(light: 0xFFC107, dark: 0xFFD60A)

    /// Critical — quota exhausted, hard stop.
    static let criticalRed = Color(light: 0xDC3545, dark: 0xFF453A)
}
