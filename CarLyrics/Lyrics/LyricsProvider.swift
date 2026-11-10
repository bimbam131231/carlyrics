import Foundation

struct LyricsQuery {
    /// One spelling of the track metadata (e.g. Spotify's default, Hebrew, English).
    struct Names {
        /// Short tag for logs: "spotify", "he", "en".
        let label: String
        let title: String
        let artist: String
        let album: String
    }

    /// Name variants, most trusted first; duplicates already removed.
    let names: [Names]
    /// Seconds.
    let duration: TimeInterval
}

enum LyricsResult: Codable, Equatable {
    case synced([LyricLine])
    case plainOnly
    case instrumental
    case notFound
}

/// A provider's answer plus every query it tried (for the "Missing lyrics" report).
struct LyricsFetch {
    let result: LyricsResult
    let attempts: [String]
}

/// A lyrics source. Add more implementations later (and try them in order).
@MainActor
protocol LyricsProvider {
    var name: String { get }
    func fetchLyrics(for query: LyricsQuery) async throws -> LyricsFetch
}

/// Cleans Spotify metadata for fuzzy search.
enum SearchNormalizer {
    static func title(_ s: String) -> String {
        var t = s
        // "(feat. X)", "[Remastered 2011]", "(Live)" ...
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        // "Song - Remastered 2011", "Song - Live at ..."
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        // "Song feat. X"
        t = t.replacingOccurrences(of: #"(?i)\s+(feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func artist(_ s: String) -> String {
        var a = s
        a = a.replacingOccurrences(of: #"(?i)\s+(feat\.?|ft\.?|featuring|&|x|and)\s+.*$"#, with: "", options: .regularExpression)
        if let r = a.range(of: ",") { a = String(a[..<r.lowerBound]) }
        return a.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
