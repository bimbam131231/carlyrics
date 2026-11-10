import Foundation

/// A track for which every LRCLIB attempt failed — shown in Developer →
/// "Missing lyrics" so misses can be reported.
struct MissingLyricsEntry: Codable, Identifiable, Equatable {
    /// Spotify track ID.
    let id: String
    let date: Date
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    /// "not found" or "plain lyrics only".
    let outcome: String
    let hebrewNames: TrackNames?
    let englishNames: TrackNames?
    let queries: [String]

    var reportText: String {
        var s = "\(title) — \(artist)\n"
        s += "Spotify ID: \(id)\n"
        s += "Album: \(album)\n"
        s += "Duration: \(durationSeconds / 60):\(String(format: "%02d", durationSeconds % 60)) (\(durationSeconds)s)\n"
        s += "Names (he): \(hebrewNames?.summary ?? "unavailable")\n"
        s += "Names (en): \(englishNames?.summary ?? "unavailable")\n"
        s += "Outcome: \(outcome)\n"
        s += "Queries tried (\(queries.count)):\n"
        s += queries.map { "  • \($0)" }.joined(separator: "\n")
        return s
    }
}

/// Persisted list (Documents/CarLyrics-missing-lyrics.json), newest first, max 100.
@MainActor
final class MissingLyricsLog {
    private(set) var entries: [MissingLyricsEntry] = []
    private let maxEntries = 100
    private let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CarLyrics-missing-lyrics.json")

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? decoder.decode([MissingLyricsEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: MissingLyricsEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
    }

    /// Lyrics were found later (e.g. LRCLIB got them): drop the entry.
    @discardableResult
    func remove(trackID: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == trackID }
        guard entries.count != before else { return false }
        save()
        return true
    }

    func clear() {
        entries.removeAll()
        save()
    }

    var reportText: String {
        guard !entries.isEmpty else { return "No missing lyrics." }
        let f = ISO8601DateFormatter()
        return "CarLyrics — missing lyrics (\(entries.count))\n\n" + entries.map {
            "[\(f.string(from: $0.date))]\n\($0.reportText)"
        }.joined(separator: "\n\n")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
