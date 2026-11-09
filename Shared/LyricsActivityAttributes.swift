import ActivityKit
import Foundation

struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentLine: String
        var nextLine: String
        var isRTLCurrent: Bool
        var isRTLNext: Bool
        var trackTitle: String
        var artist: String
    }

    // Static attributes (none needed yet).
}

enum TextDirection {
    /// True if the string contains any Hebrew character (U+0590–U+05FF).
    static func isRTL(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
    }
}
