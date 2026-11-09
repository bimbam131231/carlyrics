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

    /// Darkens in small steps until luminance <= `maxLuminance` (keeps hue).
    func cappedLuminance(_ maxLuminance: Double) -> RGB {
        var c = self
        var steps = 0
        while c.luminance > maxLuminance && steps < 40 {
            c = c.darkened(0.08)
            steps += 1
        }
        return c
    }

    var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    static func contrast(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// Visual theme derived from the album colors in the ContentState.
///
/// Design rule: the card is ALWAYS dark and moody with white text (matches the
/// dark CarPlay style). Light album colors are darkened until white text has
/// at least ~7:1 contrast against every gradient stop.
struct LyricsTheme {
    let top: RGB
    let middle: RGB
    let bottom: RGB
    /// Darkened accent used for the background glow.
    let glow: RGB
    /// Original accent, for small tinted elements (icons).
    let accent: RGB

    /// Luminance ceiling for the background (white contrast = 1.05 / (L + 0.05) >= 7).
    static let maxBackgroundLuminance = 0.10

    init(backgroundHex: String, accentHex: String) {
        let bg = RGB(hex: backgroundHex) ?? .fallbackBackground
        let ac = RGB(hex: accentHex) ?? bg
        accent = ac

        let mid = bg.cappedLuminance(Self.maxBackgroundLuminance * 0.8)
        let darkAccent = ac.cappedLuminance(Self.maxBackgroundLuminance * 1.8)
        middle = mid
        top = mid.mixed(with: darkAccent, 0.3).cappedLuminance(Self.maxBackgroundLuminance)
        bottom = mid.darkened(0.3)
        glow = darkAccent
    }

    init(state: LyricsActivityAttributes.ContentState) {
        self.init(backgroundHex: state.backgroundColorHex, accentHex: state.accentColorHex)
    }

    var primaryText: Color { .white }
    var secondaryText: Color { .white.opacity(0.6) }
    var tertiaryText: Color { .white.opacity(0.42) }
    var textShadow: Color { .black.opacity(0.35) }
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
                colors: [theme.glow.color.opacity(0.3), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 280
            )
        }
    }
}
