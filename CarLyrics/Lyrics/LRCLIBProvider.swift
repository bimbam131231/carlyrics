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
@MainActor
final class LRCLIBProvider: LyricsProvider {
    let name = "LRCLIB"
    var onLog: (String) -> Void = { _ in }

    private let base = "https://lrclib.net/api"
    private let durationTolerance: TimeInterval = 3

    func fetchLyrics(for q: LyricsQuery) async throws -> LyricsResult {
        var sawPlain = false
        var sawInstrumental = false
        var hadError = false
        var triedQueries = Set<String>()

        /// Returns parsed synced lines from the best duration match, if any.
        func consider(_ records: [LRCLIBRecord]) -> [LyricLine]? {
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
            for r in synced {
                let lines = LRCParser.parse(r.syncedLyrics ?? "")
                if !lines.isEmpty { return lines }
            }
            return nil
        }

        func run(_ label: String, _ path: String, _ items: [String: String]) async -> [LRCLIBRecord] {
            let key = path + items.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            guard !triedQueries.contains(key) else { return [] }
            triedQueries.insert(key)
            do {
                let records = try await request(path, items)
                onLog("LRCLIB \(label): \(records.count) result(s)")
                return records
            } catch {
                hadError = true
                onLog("LRCLIB \(label) error: \(error.localizedDescription)")
                return []
            }
        }

        // 1. Exact match.
        let exact = await run("get", "get", [
            "track_name": q.title,
            "artist_name": q.artist,
            "album_name": q.album,
            "duration": String(Int(q.duration.rounded())),
        ])
        if let lines = consider(exact) { return .synced(lines) }

        // 2. Search with original metadata.
        let search = await run("search", "search", [
            "track_name": q.title, "artist_name": q.artist,
        ])
        if let lines = consider(search) { return .synced(lines) }

        // 3. Search with normalized metadata (strip feat./Remastered/parentheses).
        let nt = SearchNormalizer.title(q.title)
        let na = SearchNormalizer.artist(q.artist)
        let normalized = await run("search (normalized)", "search", [
            "track_name": nt, "artist_name": na,
        ])
        if let lines = consider(normalized) { return .synced(lines) }

        // 4. Free-text search (helps with Hebrew vs transliterated metadata).
        let freeText = await run("search (q)", "search", [
            "q": "\(nt) \(na)",
        ])
        if let lines = consider(freeText) { return .synced(lines) }

        // 5. Title only, trusting the duration filter.
        let titleOnly = await run("search (title)", "search", [
            "track_name": nt,
        ])
        if let lines = consider(titleOnly) { return .synced(lines) }

        if sawPlain { return .plainOnly }
        if sawInstrumental { return .instrumental }
        if hadError { throw URLError(.cannotLoadFromNetwork) }
        return .notFound
    }

    private func request(_ path: String, _ items: [String: String]) async throws -> [LRCLIBRecord] {
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
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
