import SwiftUI

/// Simple sRGB color value used for theme math (mixing, luminance).
struct RGB: Hashable {
    var r: Double
    var g: Double
    var b: Double

    static let fallbackBackground = RGB(r: 0.10, g: 0.10, b: 0.12)

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    /// Parses "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xFF) / 255
        g = Double((v >> 8) & 0xFF) / 255
        b = Double(v & 0xFF) / 255
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func darkened(_ amount: Double) -> RGB { mixed(with: RGB(r: 0, g: 0, b: 0), amount) }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    static func contrast(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// Visual theme derived from the album colors in the ContentState.
struct LyricsTheme {
    let top: RGB
    let middle: RGB
    let bottom: RGB
    let accent: RGB
    /// True when dark text reads better than white text on the gradient.
    let usesDarkText: Bool

    init(backgroundHex: String, accentHex: String) {
        let bg = RGB(hex: backgroundHex) ?? .fallbackBackground
        let ac = RGB(hex: accentHex) ?? bg
        top = bg.mixed(with: ac, 0.28)
        middle = bg
        bottom = bg.darkened(0.22)
        accent = ac

        // Pick the text color against the lightest part of the gradient
        // (worst case for white text) and the darkest part (worst case for dark text).
        let darkText = 0.0056 // luminance of #111111
        let lightest = max(top.luminance, middle.luminance, bottom.luminance)
        let darkest = min(top.luminance, middle.luminance, bottom.luminance)
        usesDarkText = RGB.contrast(darkest, darkText) > RGB.contrast(lightest, 1.0)
    }

    init(state: LyricsActivityAttributes.ContentState) {
        self.init(backgroundHex: state.backgroundColorHex, accentHex: state.accentColorHex)
    }

    var primaryText: Color { usesDarkText ? Color(white: 0.07) : .white }
    var secondaryText: Color { primaryText.opacity(usesDarkText ? 0.55 : 0.6) }
    var tertiaryText: Color { primaryText.opacity(usesDarkText ? 0.4 : 0.42) }
    var textShadow: Color { usesDarkText ? .white.opacity(0.25) : .black.opacity(0.35) }
    var tint: Color { middle.color }
}

/// Soft album-color gradient background.
struct LyricsBackground: View {
    let theme: LyricsTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.top.color, theme.middle.color, theme.bottom.color],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [theme.accent.color.opacity(0.28), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 280
            )
        }
    }
}
