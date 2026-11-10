import Foundation

private struct LRCLIBRecord: Decodable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

/// https://lrclib.net — free, no API key.
///
/// Runs the fallback chain over every name variant (Spotify default, Hebrew,
/// English), step by step: all precise queries for all variants before the
/// fuzzier ones, so a Hebrew exact match beats a transliterated title-only guess.
/// Every query and its outcome is logged.
@MainActor
final class LRCLIBProvider: LyricsProvider {
    let name = "LRCLIB"
    var onLog: (String) -> Void = { _ in }

    private let base = "https://lrclib.net/api"
    private let durationTolerance: TimeInterval = 3

    func fetchLyrics(for q: LyricsQuery) async throws -> LyricsFetch {
        var sawPlain = false
        var sawInstrumental = false
        var hadError = false
        var triedQueries = Set<String>()
        var attempts: [String] = []

        /// One LRCLIB request; returns synced lines from the best duration match.
        func attempt(_ step: String, _ variant: String, _ path: String,
                     _ items: [(String, String)]) async -> [LyricLine]? {
            let items = items.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !items.isEmpty else { return nil }
            let key = path + "?" + items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
            guard !triedQueries.contains(key) else { return nil }
            triedQueries.insert(key)

            let shown = items.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
            let label = "\(step) [\(variant)] \(path) \(shown)"
            let records: [LRCLIBRecord]
            do {
                records = try await request(path, items)
            } catch {
                hadError = true
                let line = "\(label) → error: \(error.localizedDescription)"
                attempts.append(line)
                onLog("LRCLIB \(line)")
                return nil
            }

            let matching = records.filter { r in
                guard let d = r.duration else { return false }
                return abs(d - q.duration) <= durationTolerance
            }
            for r in matching {
                if r.instrumental == true { sawInstrumental = true }
                if !(r.plainLyrics ?? "").isEmpty { sawPlain = true }
            }
            let synced = matching
                .filter { !($0.syncedLyrics ?? "").isEmpty }
                .sorted { abs(($0.duration ?? 0) - q.duration) < abs(($1.duration ?? 0) - q.duration) }

            var found: (LRCLIBRecord, [LyricLine])?
            for r in synced {
                let lines = LRCParser.parse(r.syncedLyrics ?? "")
                if !lines.isEmpty { found = (r, lines); break }
            }

            var outcome = "\(records.count) result(s), \(matching.count) within ±\(Int(durationTolerance))s, "
                + "\(synced.count) synced"
            if let found {
                let (r, lines) = found
                outcome += " → HIT id \(r.id.map(String.init) ?? "?") "
                    + "\"\(r.trackName ?? "?")\" — \(r.artistName ?? "?") (\(lines.count) lines)"
            }
            let line = "\(label) → \(outcome)"
            attempts.append(line)
            onLog("LRCLIB \(line)")
            return found?.1
        }

        let duration = String(Int(q.duration.rounded()))

        // 1. Exact match.
        for n in q.names {
            if let lines = await attempt("1 get", n.label, "get", [
                ("track_name", n.title), ("artist_name", n.artist),
                ("album_name", n.album), ("duration", duration),
            ]) { return LyricsFetch(result: .synced(lines), attempts: attempts) }
        }
        // 2. Search with the metadata as-is.
        for n in q.names {
            if let lines = await attempt("2 search", n.label, "search", [
                ("track_name", n.title), ("artist_name", n.artist),
            ]) { return LyricsFetch(result: .synced(lines), attempts: attempts) }
        }
        // 3. Search with normalized metadata (strip feat./Remastered/parentheses).
        for n in q.names {
            if let lines = await attempt("3 normalized", n.label, "search", [
                ("track_name", SearchNormalizer.title(n.title)),
                ("artist_name", SearchNormalizer.artist(n.artist)),
            ]) { return LyricsFetch(result: .synced(lines), attempts: attempts) }
        }
        // 4. Free-text search.
        for n in q.names {
            let text = "\(SearchNormalizer.title(n.title)) \(SearchNormalizer.artist(n.artist))"
            if let lines = await attempt("4 q", n.label, "search", [("q", text)]) {
                return LyricsFetch(result: .synced(lines), attempts: attempts)
            }
        }
        // 5. Title only, trusting the duration filter.
        for n in q.names {
            if let lines = await attempt("5 title", n.label, "search", [
                ("track_name", SearchNormalizer.title(n.title)),
            ]) { return LyricsFetch(result: .synced(lines), attempts: attempts) }
        }

        if sawPlain { return LyricsFetch(result: .plainOnly, attempts: attempts) }
        if sawInstrumental { return LyricsFetch(result: .instrumental, attempts: attempts) }
        if hadError { throw URLError(.cannotLoadFromNetwork) }
        return LyricsFetch(result: .notFound, attempts: attempts)
    }

    private func request(_ path: String, _ items: [(String, String)]) async throws -> [LRCLIBRecord] {
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves "+" alone, which servers read as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        if code == 404 { return [] }
        guard code == 200 else { throw SpotifyError.http(code, "LRCLIB") }

        let decoder = JSONDecoder()
        if path == "get" {
            return [try decoder.decode(LRCLIBRecord.self, from: data)]
        }
        return try decoder.decode([LRCLIBRecord].self, from: data)
    }
}
