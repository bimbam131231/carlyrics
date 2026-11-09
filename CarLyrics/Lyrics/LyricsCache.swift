import Foundation

/// Lyrics per Spotify track ID: memory + small disk cache (Caches/lyrics).
/// `.notFound` is kept in memory only so it is retried on the next launch.
@MainActor
final class LyricsCache {
    private var memory: [String: LyricsResult] = [:]
    private let directory: URL
    private let maxDiskEntries = 300

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func get(_ trackID: String) -> LyricsResult? {
        if let hit = memory[trackID] { return hit }
        guard let data = try? Data(contentsOf: fileURL(trackID)),
              let result = try? JSONDecoder().decode(LyricsResult.self, from: data) else { return nil }
        memory[trackID] = result
        return result
    }

    func set(_ result: LyricsResult, for trackID: String) {
        memory[trackID] = result
        if case .notFound = result { return }
        guard let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: fileURL(trackID), options: .atomic)
        prune()
    }

    private func fileURL(_ trackID: String) -> URL {
        let safe = String(trackID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return directory.appendingPathComponent("\(safe).json")
    }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxDiskEntries else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted.prefix(files.count - maxDiskEntries) {
            try? fm.removeItem(at: url)
        }
    }
}
