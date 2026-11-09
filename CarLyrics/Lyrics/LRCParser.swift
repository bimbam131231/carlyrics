import Foundation

struct LyricLine: Codable, Hashable {
    /// Start time in seconds.
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    private static let timeTag = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    /// Enhanced-LRC word timestamps like <00:12.34>.
    private static let wordTag = try! NSRegularExpression(
        pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    /// Parses `[mm:ss.xx] text` lines, supports multiple timestamps per line
    /// and `[offset:±ms]`; other metadata tags (`[ar:…]`, `[ti:…]`) are ignored.
    static func parse(_ lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        var offset: TimeInterval = 0

        for raw in lrc.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("[offset:") {
                let digits = line.dropFirst(8).prefix { $0 != "]" }
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "+", with: "")
                offset = (Double(digits) ?? 0) / 1000
                continue
            }

            let ns = line as NSString
            var times: [TimeInterval] = []
            var cursor = 0
            while cursor < ns.length,
                  let m = timeTag.firstMatch(in: line, range: NSRange(location: cursor, length: ns.length - cursor)),
                  m.range.location == cursor {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    fraction = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                cursor = m.range.location + m.range.length
            }
            guard !times.isEmpty else { continue } // metadata tag or junk

            var text = ns.substring(from: cursor)
            text = wordTag.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            text = text.trimmingCharacters(in: .whitespaces)

            for t in times {
                // Positive offset = lyrics come earlier.
                result.append(LyricLine(time: max(0, t - offset), text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Index of the line active at `position`, nil before the first line.
    static func index(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard let first = lines.first, position >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
