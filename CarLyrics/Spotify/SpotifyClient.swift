import Foundation

struct SpotifyTrack: Equatable {
    let id: String
    let title: String
    let artists: [String]
    let album: String
    let durationMs: Int
    let imageURL: URL?

    var artist: String { artists.joined(separator: ", ") }
    var primaryArtist: String { artists.first ?? "" }
    var duration: TimeInterval { TimeInterval(durationMs) / 1000 }

    /// Real Spotify catalog track IDs are 22 base62 characters (local files aren't).
    static func isCatalogID(_ id: String) -> Bool {
        id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// Track metadata localized for one language (`GET /v1/tracks/{id}` + Accept-Language).
struct TrackNames: Codable, Equatable {
    let language: String
    let title: String
    let artists: [String]
    let album: String

    var primaryArtist: String { artists.first ?? "" }
    var summary: String { "\(title) — \(artists.joined(separator: ", "))" }
}

struct PlaybackSnapshot {
    /// nil for ads / podcasts / unknown items.
    let track: SpotifyTrack?
    let isPlaying: Bool
    let progressMs: Int
    /// Moment `progressMs` was valid (midpoint of the request round trip).
    let fetchedAt: Date

    /// Locally estimated playback position in seconds.
    func position(at now: Date = Date()) -> TimeInterval {
        var pos = TimeInterval(progressMs) / 1000
        if isPlaying { pos += now.timeIntervalSince(fetchedAt) }
        if let track { pos = min(pos, track.duration) }
        return max(0, pos)
    }
}

enum PlaybackResult {
    case playing(PlaybackSnapshot)
    case nothingPlaying
    case rateLimited(retryAfter: TimeInterval)
}

private struct CurrentlyPlayingResponse: Decodable {
    let is_playing: Bool?
    let progress_ms: Int?
    let item: Item?

    struct Item: Decodable {
        let id: String?
        let uri: String?
        let name: String
        let duration_ms: Int
        let artists: [Artist]?
        let album: Album?
    }
    struct Artist: Decodable { let name: String }
    struct Album: Decodable {
        let name: String
        let images: [Image]?
    }
    struct Image: Decodable {
        let url: String
        let width: Int?
    }
}

@MainActor
struct SpotifyClient {
    let auth: SpotifyAuth

    func currentlyPlaying() async throws -> PlaybackResult {
        for _ in 0..<2 {
            let token = try await auth.validAccessToken()
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            req.timeoutInterval = 10
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let sent = Date()
            let (data, response) = try await URLSession.shared.data(for: req)
            let received = Date()
            guard let http = response as? HTTPURLResponse else { throw SpotifyError.badResponse }

            switch http.statusCode {
            case 200:
                let r = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
                return .playing(PlaybackSnapshot(
                    track: r.item.map { Self.track(from: $0) },
                    isPlaying: r.is_playing ?? false,
                    progressMs: r.progress_ms ?? 0,
                    fetchedAt: sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
                ))
            case 204:
                return .nothingPlaying
            case 401:
                auth.invalidateAccessToken()
                continue
            case 429:
                let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
                return .rateLimited(retryAfter: retry)
            default:
                throw SpotifyError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
            }
        }
        throw SpotifyError.http(401, "Unauthorized after token refresh")
    }

    /// Track names as Spotify localizes them for `language` ("he", "en").
    /// Israeli tracks often come back transliterated in one language and in
    /// Hebrew in the other, while LRCLIB may have either.
    func trackNames(id: String, language: String) async throws -> TrackNames {
        guard SpotifyTrack.isCatalogID(id) else { throw SpotifyError.badResponse }
        for _ in 0..<2 {
            let token = try await auth.validAccessToken()
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/tracks/\(id)")!)
            req.timeoutInterval = 10
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(language, forHTTPHeaderField: "Accept-Language")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw SpotifyError.badResponse }
            switch http.statusCode {
            case 200:
                let item = try JSONDecoder().decode(CurrentlyPlayingResponse.Item.self, from: data)
                return TrackNames(language: language,
                                  title: item.name,
                                  artists: item.artists?.map(\.name) ?? [],
                                  album: item.album?.name ?? "")
            case 401:
                auth.invalidateAccessToken()
                continue
            default:
                throw SpotifyError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
            }
        }
        throw SpotifyError.http(401, "Unauthorized after token refresh")
    }

    private static func track(from item: CurrentlyPlayingResponse.Item) -> SpotifyTrack {
        // Smallest image is enough for color extraction.
        let images = (item.album?.images ?? []).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return SpotifyTrack(
            id: item.id ?? item.uri ?? "local:\(item.name)",
            title: item.name,
            artists: item.artists?.map(\.name) ?? [],
            album: item.album?.name ?? "",
            durationMs: item.duration_ms,
            imageURL: images.first.flatMap { URL(string: $0.url) }
        )
    }
}
