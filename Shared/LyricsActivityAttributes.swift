import ActivityKit
import Foundation

struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var previousLine: String
        var currentLine: String
        var nextLine: String
        var isRTLPrevious: Bool
        var isRTLCurrent: Bool
        var isRTLNext: Bool
        var trackTitle: String
        var artist: String
        /// Album-derived colors as "#RRGGBB". The view builds a soft, always-dark
        /// gradient from them (light colors get darkened); text is always white.
        var backgroundColorHex: String
        var accentColorHex: String
        /// Index of the current lyric line (-1 before the first line, -100 for
        /// status messages). Used as view identity so line changes animate.
        var lineID: Int
    }

    // Static attributes (none needed yet).
}

extension LyricsActivityAttributes.ContentState {
    /// Convenience init that computes the per-line text direction.
    init(previous: String, current: String, next: String,
         trackTitle: String, artist: String,
         backgroundColorHex: String, accentColorHex: String, lineID: Int = -100) {
        self.init(
            previousLine: previous,
            currentLine: current,
            nextLine: next,
            isRTLPrevious: TextDirection.isRTL(previous),
            isRTLCurrent: TextDirection.isRTL(current),
            isRTLNext: TextDirection.isRTL(next),
            trackTitle: trackTitle,
            artist: artist,
            backgroundColorHex: backgroundColorHex,
            accentColorHex: accentColorHex,
            lineID: lineID
        )
    }
}

enum TextDirection {
    /// Direction of a line follows its first strong character:
    /// Hebrew/Arabic letter -> RTL, any other letter -> LTR.
    /// Digits, punctuation, spaces and marks are skipped. No strong char -> LTR.
    static func isRTL(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if isRTLScalar(scalar.value) { return true }
            if scalar.properties.isAlphabetic { return false }
        }
        return false
    }

    private static func isRTLScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x05D0...0x05EA, 0x05EF...0x05F4, // Hebrew letters (excl. niqqud marks)
             0xFB1D...0xFB4F,                  // Hebrew presentation forms
             0x0600...0x06FF, 0x0750...0x077F, // Arabic
             0xFB50...0xFDFF, 0xFE70...0xFEFF: // Arabic presentation forms
            return true
        default:
            return false
        }
    }
}
